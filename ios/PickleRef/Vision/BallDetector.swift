import CoreVideo
import Foundation

/// A single ball detection in image coordinates (pixels, origin top-left).
struct BallDetection {
    let center: CGPoint
    let radius: Float
    let confidence: Float
}

/// Detects the pickleball in a YUV frame via HSV-style color segmentation
/// plus circularity/size gating. Detector-agnostic by design: the tracker and
/// downstream engine consume `BallDetection` values, so this can later be
/// replaced by an ML detector (YOLO-nano / TrackNet) without touching them.
///
/// POC approach (fast, ~few ms per 1080p frame on A-series phones):
/// 1. Convert to YCbCr, compute a chroma mask for the configured ball color.
/// 2. Morphological-ish cleanup via box counting on a downscaled mask.
/// 3. Connected components (two-pass union-find on downscaled mask).
/// 4. Score components by area, circularity, and proximity to last known
///    position (when the tracker provides one).
final class BallDetector {

    struct Config {
        /// HSV hue range [min,max] in degrees for the ball color.
        var hueRange: (Float, Float) = (35, 75)   // yellow-green pickleball
        /// Saturation floor 0...1.
        var satMin: Float = 0.35
        /// Value floor 0...1.
        var valMin: Float = 0.35
        /// Detection mask is computed at this downscale factor.
        var downscale: Int = 4
        /// Ball apparent radius range in pixels at capture resolution.
        var radiusRange: (Float, Float) = (2, 40)
        var maxComponents = 8
    }

    var config = Config()

    /// Optional prior: where the ball was last seen (image coords). Detections
    /// near this point get a confidence bonus; used by the tracker.
    var searchPrior: CGPoint?

    // MARK: - Public API

    /// - Returns: best detection or nil.
    func detect(in pixelBuffer: CVPixelBuffer) -> BallDetection? {
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let ds = max(1, config.downscale)

        let maskW = width / ds
        let maskH = height / ds
        guard maskW > 0, maskH > 0 else { return nil }

        var mask = [UInt8](repeating: 0, count: maskW * maskH)
        buildMask(luma: luma.assumingMemoryBound(to: UInt8.self), lumaStride: lumaStride,
                  chroma: chroma.assumingMemoryBound(to: UInt8.self), chromaStride: chromaStride,
                  width: width, height: height, ds: ds,
                  maskW: maskW, maskH: maskH, mask: &mask)

        let components = connectedComponents(mask: mask, width: maskW, height: maskH)
        let detections = components.compactMap { component -> BallDetection? in
            guard let det = score(component, maskW: maskW, maskH: maskH, ds: ds) else { return nil }
            return det
        }
        .sorted { $0.confidence > $1.confidence }

        return detections.first
    }

    // MARK: - Mask building (BT.601 full-range YUV → approximate HSV gates)

    private func buildMask(luma: UnsafePointer<UInt8>, lumaStride: Int,
                           chroma: UnsafePointer<UInt8>, chromaStride: Int,
                           width: Int, height: Int, ds: Int,
                           maskW: Int, maskH: Int, mask: inout [UInt8]) {
        let (hueMin, hueMax) = config.hueRange
        let wrap = hueMin > hueMax // e.g. red wraps around 360
        for my in 0..<maskH {
            let y0 = my * ds
            for mx in 0..<maskW {
                let x0 = mx * ds
                // Sample the center pixel of each ds×ds block (cheap; blur
                // robustness comes from the tracker, not the mask).
                let yy = Float(luma[y0 * lumaStride + x0])
                let cb = Float(chroma[(y0 / 2) * chromaStride + (x0 & ~1)]) - 128
                let cr = Float(chroma[(y0 / 2) * chromaStride + (x0 & ~1) + 1]) - 128

                let value = yy / 255
                let sat = max(0, 1 - abs(cb) / 128 * 0.5 - abs(cr) / 128 * 0.5)
                // Hue from Cb/Cr (approximation good enough for gating).
                var hue = atan2(cr, cb) * 180 / .pi // -180...180, 0 = blue-ish axis offset
                hue = hue < 0 ? hue + 360 : hue
                // BT.601: hue measured from blue axis; shift to standard HSV scale.
                let hsvHue = (hue + 90).truncatingRemainder(dividingBy: 360)

                let hueOK = wrap ? (hsvHue >= hueMin || hsvHue <= hueMax)
                                 : (hsvHue >= hueMin && hsvHue <= hueMax)
                let valueOK = value >= config.valMin
                let satOK = sat >= config.satMin
                mask[my * maskW + mx] = (hueOK && valueOK && satOK) ? 1 : 0
            }
        }
    }

    // MARK: - Connected components (iterative flood fill, 4-connectivity)

    private struct Component {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        var area = 0
        var sumX = 0, sumY = 0
    }

    private func connectedComponents(mask: [UInt8], width: Int, height: Int) -> [Component] {
        var visited = [UInt8](repeating: 0, count: mask.count)
        var components: [Component] = []
        var stack: [Int] = []

        for start in 0..<mask.count where mask[start] == 1 && visited[start] == 0 {
            var comp = Component()
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = 1

            while let idx = stack.popLast() {
                let x = idx % width, y = idx / width
                comp.minX = min(comp.minX, x); comp.maxX = max(comp.maxX, x)
                comp.minY = min(comp.minY, y); comp.maxY = max(comp.maxY, y)
                comp.area += 1
                comp.sumX += x; comp.sumY += y

                if x > 0, mask[idx - 1] == 1, visited[idx - 1] == 0 { visited[idx - 1] = 1; stack.append(idx - 1) }
                if x < width - 1, mask[idx + 1] == 1, visited[idx + 1] == 0 { visited[idx + 1] = 1; stack.append(idx + 1) }
                if y > 0, mask[idx - width] == 1, visited[idx - width] == 0 { visited[idx - width] = 1; stack.append(idx - width) }
                if y < height - 1, mask[idx + width] == 1, visited[idx + width] == 0 { visited[idx + width] = 1; stack.append(idx + width) }
            }
            components.append(comp)
            if components.count > config.maxComponents * 4 { break }
        }
        return components
    }

    // MARK: - Scoring

    private func score(_ comp: Component, maskW: Int, maskH: Int, ds: Int) -> BallDetection? {
        let w = comp.maxX - comp.minX + 1
        let h = comp.maxY - comp.minY + 1
        let radiusPx = Float(max(w, h)) * Float(ds) / 2
        guard radiusPx >= config.radiusRange.0, radiusPx <= config.radiusRange.1 else { return nil }

        // Circularity: fill ratio of bounding box vs circle.
        let fill = Float(comp.area) / Float(w * h)
        let aspect = Float(min(w, h)) / Float(max(w, h))
        var confidence = fill * 0.5 + aspect * 0.5

        // Elongated blobs = motion-blur streaks; still allow them (a streak
        // through the bounce frame is exactly what we want) but lower score.
        if aspect < 0.35 { confidence *= 0.6 }

        // Prior proximity bonus.
        if let prior = searchPrior {
            let cx = CGFloat(comp.sumX) / CGFloat(comp.area) * CGFloat(ds)
            let cy = CGFloat(comp.sumY) / CGFloat(comp.area) * CGFloat(ds)
            let dist = hypot(cx - prior.x, cy - prior.y)
            let bonus = max(Float(0), Float(1 - dist / 400))
            confidence = min(Float(1), confidence * 0.7 + bonus * 0.3)
        }

        let cx = Double(comp.sumX) / Double(comp.area) * Double(ds)
        let cy = Double(comp.sumY) / Double(comp.area) * Double(ds)
        return BallDetection(center: CGPoint(x: cx, y: cy), radius: radiusPx, confidence: confidence)
    }
}
