import Foundation
import CoreGraphics

/// Small math helpers shared across the pipeline.
enum MathUtils {
    /// Clamp a value into a closed range.
    static func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
        min(max(v, lo), hi)
    }

    /// 1D two-point linear interpolation.
    static func lerp(_ pts: [(Double, Double)], at t: Double) -> Double? {
        guard let i = pts.firstIndex(where: { $0.0 > t }), i > 0 else { return nil }
        let (t0, v0) = pts[i - 1]
        let (t1, v1) = pts[i]
        guard t1 > t0 else { return nil }
        let f = (t - t0) / (t1 - t0)
        return v0 + f * (v1 - v0)
    }
}
