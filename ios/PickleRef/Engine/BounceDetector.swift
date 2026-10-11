import Foundation
import CoreGraphics

/// Detects bounce events from a sequence of ball observations in *court*
/// coordinates (after homography), using a physics-aware parabola fit.
///
/// Method:
/// 1. Convert the recent image-space track to court-plane points.
/// 2. A bounce is a sharp reversal of the vertical court velocity (y toward
///    net vs away) combined with a height minimum — in a pure 2D top-down
///    homography, the bounce appears as the point where the trajectory's
///    lateral velocity changes character and the *image-space* vertical
///    velocity flips sign (ball descends then rises).
/// 3. Because image-space y-flip is contaminated by perspective, we fit the
///    image-space vertical coordinate around the candidate with a parabola in
///    time and take the vertex as the bounce time/point — robust to 1–3
///    missing (occluded) frames.
struct BounceEvent {
    let time: Double
    let imagePoint: CGPoint
    let courtPoint: CourtGeometry.Point
    let confidence: Float
}

final class BounceDetector {

    struct Config {
        /// Window (seconds) of track used for fitting.
        var fitWindow: Double = 0.45
        /// Minimum downward speed before bounce (court ft/s) to consider real.
        var minApproachSpeed: Double = 8
        /// Parabola fit needs at least this many observations.
        var minObservations = 7
        /// Reject fits whose residual RMS exceeds this (pixels).
        var maxResidual: Double = 6
    }

    var config = Config()

    private var lastBounceTime: Double = 0

    /// - Parameters:
    ///   - track: recent observations, oldest first (from BallTracker).
    ///   - homography: calibrated image→court mapping.
    /// - Returns: a new bounce event if one is detected at the head of the track.
    func detect(track: [BallObservation], homography: Homography) -> BounceEvent? {
        guard track.count >= config.minObservations else { return nil }

        // Only examine the newest portion so each bounce fires once.
        guard let newest = track.last else { return nil }
        let window = track.filter { $0.time >= newest.time - config.fitWindow }
        guard window.count >= config.minObservations else { return nil }
        guard newest.time - lastBounceTime > 0.25 else { return nil } // debounce

        // Fit image-space y(t) with a parabola over the window; a bounce is a
        // local minimum of the ball's *height*, which in a behind-baseline
        // view correlates with image-space y extremum + court-plane velocity
        // direction check. Fit y = a t² + b t + c.
        guard let (a, b, c, rms) = fitParabola(window.map { ($0.time, Double($0.imagePoint.y)) }) else { return nil }
        guard rms <= config.maxResidual, a > 0 else { return nil } // a>0 → minimum

        let tVertex = -b / (2 * a)
        guard abs(tVertex - newest.time) < 0.12 else { return nil } // bounce must be ~now
        guard tVertex >= window.first!.time else { return nil }

        // Court-plane approach speed check (reject noise jitter).
        let courtPts = window.map { (t: $0.time, p: homography.apply($0.imagePoint)) }
        guard courtPts.count >= 3 else { return nil }
        let mid = courtPts.count / 2
        let before = courtPts[..<mid]
        let after = courtPts[mid...]
        guard let p1 = before.first, let p2 = before.last,
              let p3 = after.first, let p4 = after.last else { return nil }
        let dt1 = p2.t - p1.t, dt2 = p4.t - p3.t
        guard dt1 > 0, dt2 > 0 else { return nil }
        let speedBefore = hypot(p2.p.x - p1.p.x, p2.p.y - p1.p.y) / dt1
        guard speedBefore >= config.minApproachSpeed else { return nil }

        // Confidence: low residual + high observation confidence + small gap.
        let avgObsConf = window.map(\.confidence).reduce(0, +) / Float(window.count)
        let residualScore = Float(1 - min(1, rms / config.maxResidual))
        let confidence = avgObsConf * 0.5 + residualScore * 0.5

        // Bounce image point: parabola vertex position, x interpolated at tVertex.
        let xPts = window.map { ($0.time, Double($0.imagePoint.x)) }
        let xAtBounce = linearInterp(xPts, at: tVertex) ?? Double(newest.imagePoint.x)
        let imagePoint = CGPoint(x: xAtBounce, y: c - b * b / (4 * a))
        let courtPoint = homography.apply(imagePoint)

        lastBounceTime = newest.time
        return BounceEvent(time: tVertex,
                           imagePoint: imagePoint,
                           courtPoint: courtPoint,
                           confidence: confidence)
    }

    func reset() {
        lastBounceTime = 0
    }

    // MARK: - Fitting

    private func fitParabola(_ pts: [(Double, Double)]) -> (a: Double, b: Double, c: Double, rms: Double)? {
        guard pts.count >= 3 else { return nil }
        // Least squares via normal equations for y = a t² + b t + c.
        var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
        var sy0 = 0.0, sy1 = 0.0, sy2 = 0.0
        let t0 = pts[pts.count / 2].0 // center time for conditioning
        for (t, y) in pts {
            let tt = t - t0
            s0 += 1; s1 += tt; s2 += tt*tt; s3 += tt*tt*tt; s4 += tt*tt*tt*tt
            sy0 += y; sy1 += y*tt; sy2 += y*tt*tt
        }
        // Solve 3x3 symmetric system:
        // [s4 s3 s2][a]   [sy2]
        // [s3 s2 s1][b] = [sy1]
        // [s2 s1 s0][c]   [sy0]
        var m = [[s4, s3, s2], [s3, s2, s1], [s2, s1, s0]]
        let rhs = [sy2, sy1, sy0]
        // Gaussian elimination.
        for col in 0..<3 {
            var piv = col
            for r in (col+1)..<3 where abs(m[r][col]) > abs(m[piv][col]) { piv = r }
            guard abs(m[piv][col]) > 1e-12 else { return nil }
            if piv != col { m.swapAt(piv, col) }
            let p = m[col][col]
            for r in 0..<3 where r != col {
                let f = m[r][col] / p
                for c in col..<3 { m[r][c] -= f * m[col][c] }
            }
        }
        // Back substitution.
        var sol = [Double](repeating: 0, count: 3)
        for r in stride(from: 2, through: 0, by: -1) {
            var sum = rhs[r]
            for c in (r+1)..<3 { sum -= m[r][c] * sol[c] }
            sol[r] = sum / m[r][r]
        }
        let (a, b, c) = (sol[0], sol[1], sol[2])
        // RMS residual.
        var sse = 0.0
        for (t, y) in pts {
            let tt = t - t0
            let pred = a*tt*tt + b*tt + c
            sse += (y - pred) * (y - pred)
        }
        let rms = sqrt(sse / Double(pts.count))
        return (a, b, c, rms)
    }

    private func linearInterp(_ pts: [(Double, Double)], at t: Double) -> Double? {
        guard let i = pts.firstIndex(where: { $0.0 > t }), i > 0 else { return nil }
        let (t0, v0) = pts[i-1]
        let (t1, v1) = pts[i]
        guard t1 > t0 else { return nil }
        let f = (t - t0) / (t1 - t0)
        return v0 + f * (v1 - v0)
    }
}
