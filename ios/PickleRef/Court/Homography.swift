import Foundation
import CoreGraphics

/// Planar homography (image pixel → court plane in feet) estimated from ≥4
/// point correspondences via normalized Direct Linear Transform (DLT).
///
/// Court calibration maps image points onto the physical court plane. Since a
/// court IS planar, a single homography is exact for points *on the ground*;
/// errors come from the ball's bounce point not being exactly the ball's image
/// centroid (parallax) — handled in `BounceDetector`.
struct Homography {
    /// Row-major 3x3: [h11 h12 h13; h21 h22 h23; h31 h32 h33]
    private var m: [Double]

    init(identity: Bool = true) {
        m = identity ? [1, 0, 0, 0, 1, 0, 0, 0, 1] : [Double](repeating: 0, count: 9)
    }

    var isCalibrated: Bool {
        m.contains { abs($0) > 1e-12 }
    }

    // MARK: - Estimation

    /// Estimate from image↔court correspondences (needs ≥ 4).
    /// - Parameters:
    ///   - imagePoints: tapped corner positions in image pixels.
    ///   - courtPoints: corresponding court coordinates in feet.
    static func estimate(imagePoints: [CGPoint], courtPoints: [CourtGeometry.Point]) -> Homography? {
        guard imagePoints.count >= 4, imagePoints.count == courtPoints.count else { return nil }

        // Normalization (Hartley): translate centroid to origin, scale so mean
        // distance = sqrt(2). Improves conditioning dramatically for taps that
        // cluster in one part of the image.
        let nImg = Normalizer(points: imagePoints.map { ($0.x, $0.y) })
        let nCrt = Normalizer(points: courtPoints.map { ($0.x, $0.y) })

        var rows: [[Double]] = []
        for i in 0..<imagePoints.count {
            let (x, y) = nImg.apply(imagePoints[i].x, imagePoints[i].y)
            let (u, v) = nCrt.apply(courtPoints[i].x, courtPoints[i].y)
            rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y, -u])
            rows.append([0, 0, 0, x, y, 1, -v * x, -v * y, -v])
        }

        guard let h = solveNullVector(rows) else { return nil }

        // Denormalize: H = T_crt⁻¹ · H_norm · T_img
        var H = Homography(identity: false)
        H.m = h
        let denorm = H.compose(leftInverse: nCrt.inverseMatrix(), right: nImg.matrix())
        return denorm
    }

    // MARK: - Application

    /// Map an image point to court-plane feet coordinates.
    func apply(_ p: CGPoint) -> CourtGeometry.Point {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        guard abs(w) > 1e-12 else { return .init(x: 0, y: 0) }
        return CourtGeometry.Point(x: (m[0] * x + m[1] * y + m[2]) / w,
                                   y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    /// Map court feet coords back to image (useful for drawing overlays).
    func applyInverse(_ p: CourtGeometry.Point) -> CGPoint {
        let inv = inverse()
        let x = p.x, y = p.y
        let w = inv[6] * x + inv[7] * y + inv[8]
        guard abs(w) > 1e-12 else { return .zero }
        return CGPoint(x: (inv[0] * x + inv[1] * y + inv[2]) / w,
                       y: (inv[3] * x + inv[4] * y + inv[5]) / w)
    }

    private func inverse() -> [Double] {
        let a = m
        let c0 = a[4]*a[8] - a[5]*a[7], c1 = a[5]*a[6] - a[3]*a[8], c2 = a[3]*a[7] - a[4]*a[6]
        let det = a[0]*c0 + a[1]*c1 + a[2]*c2
        guard abs(det) > 1e-12 else { return a }
        let invDet = 1.0 / det
        return [
            c0*invDet, (a[2]*a[7]-a[1]*a[8])*invDet, (a[1]*a[5]-a[2]*a[4])*invDet,
            c1*invDet, (a[0]*a[8]-a[2]*a[6])*invDet, (a[2]*a[3]-a[0]*a[5])*invDet,
            c2*invDet, (a[1]*a[6]-a[0]*a[7])*invDet, (a[0]*a[4]-a[1]*a[3])*invDet,
        ]
    }

    private func compose(leftInverse: [Double], right: [Double]) -> Homography {
        // (leftInverse) · m · (right)
        var tmp = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                var sum = 0.0
                for k in 0..<3 { sum += m[r*3+k] * right[k*3+c] }
                tmp[r*3+c] = sum
            }
        }
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                var sum = 0.0
                for k in 0..<3 { sum += leftInverse[r*3+k] * tmp[k*3+c] }
                out[r*3+c] = sum
            }
        }
        var result = Homography(identity: false)
        result.m = out
        // Normalize so m[8] = 1 for stability.
        if abs(out[8]) > 1e-12 {
            result.m = out.map { $0 / out[8] }
        }
        return result
    }

    // MARK: - Linear algebra

    private struct Normalizer {
        var tx = 0.0, ty = 0.0, scale = 1.0

        init(points: [(Double, Double)]) {
            let n = Double(points.count)
            guard n > 0 else { return }
            let cx = points.map(\.0).reduce(0, +) / n
            let cy = points.map(\.1).reduce(0, +) / n
            let meanDist = points.map { hypot($0.0 - cx, $0.1 - cy) }.reduce(0, +) / n
            tx = cx; ty = cy
            scale = meanDist > 1e-9 ? sqrt(2) / meanDist : 1
        }

        func apply(_ x: Double, _ y: Double) -> (Double, Double) {
            ((x - tx) * scale, (y - ty) * scale)
        }

        func matrix() -> [Double] {
            [scale, 0, -scale*tx, 0, scale, -scale*ty, 0, 0, 1]
        }

        func inverseMatrix() -> [Double] {
            [1/scale, 0, tx, 0, 1/scale, ty, 0, 0, 1]
        }
    }

    /// Extracts the 1D null vector of the row matrix via Gaussian elimination
    /// with partial pivoting (9 unknowns; for 4 points the system is 8x9 —
    /// rank-deficient by construction, so we solve for the least-squares null
    /// space via the last free variable).
    private static func solveNullVector(_ rows: [[Double]]) -> [Double]? {
        // Build A^T A (9x9) and find its null vector: the eigenvector for the
        // smallest eigenvalue. For a POC, use fixed-point iteration:
        // v ← (AᵀA + εI)⁻¹ v, converges to smallest-eigenvalue eigenvector.
        var ata = [Double](repeating: 0, count: 81)
        for r in rows {
            for i in 0..<9 {
                for j in 0..<9 {
                    ata[i*9+j] += r[i] * r[j]
                }
            }
        }
        // Add small ridge for invertibility.
        for i in 0..<9 { ata[i*9+i] += 1e-8 }

        guard let inv = invert9(ata) else { return nil }

        var v = [Double](repeating: 1, count: 9)
        for _ in 0..<64 {
            var nv = [Double](repeating: 0, count: 9)
            for i in 0..<9 {
                var sum = 0.0
                for j in 0..<9 { sum += inv[i*9+j] * v[j] }
                nv[i] = sum
            }
            let norm = sqrt(nv.map { $0 * $0 }.reduce(0, +))
            guard norm > 1e-15 else { return nil }
            v = nv.map { $0 / norm }
        }
        return v
    }

    private static func invert9(_ m: [Double]) -> [Double]? {
        // Gauss-Jordan on [M | I].
        var a = m
        var inv = [Double](repeating: 0, count: 81)
        for i in 0..<9 { inv[i*9+i] = 1 }
        for col in 0..<9 {
            // Pivot
            var pivotRow = col
            var best = abs(a[col*9+col])
            for r in (col+1)..<9 where abs(a[r*9+col]) > best {
                best = abs(a[r*9+col]); pivotRow = r
            }
            guard best > 1e-12 else { return nil }
            if pivotRow != col {
                for c in 0..<9 {
                    swap(&a[pivotRow*9+c], &a[col*9+c])
                    swap(&inv[pivotRow*9+c], &inv[col*9+c])
                }
            }
            let pivot = a[col*9+col]
            for c in 0..<9 { a[col*9+c] /= pivot; inv[col*9+c] /= pivot }
            for r in 0..<9 where r != col {
                let factor = a[r*9+col]
                guard factor != 0 else { continue }
                for c in 0..<9 {
                    a[r*9+c] -= factor * a[col*9+c]
                    inv[r*9+c] -= factor * inv[col*9+c]
                }
            }
        }
        return inv
    }
}
