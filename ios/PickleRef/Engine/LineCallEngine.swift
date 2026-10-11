import Foundation

/// Decides IN / OUT / TOO CLOSE for a bounce against the officiated half's
/// lines, with confidence tiers (see feasibility report: never overclaim on
/// borderline calls).
enum CallVerdict: String {
    case in_ = "IN"
    case out = "OUT"
    case tooClose = "TOO CLOSE"
}

struct LineCall {
    let verdict: CallVerdict
    let bounce: BounceEvent
    /// Distance from bounce point to nearest line (feet, signed: negative = inside court).
    let distanceToLine: Double
    /// Confidence 0...1.
    let confidence: Float
}

final class LineCallEngine {

    struct Config {
        /// Ball radius in feet (pickleball ≈ 3.7 cm diameter → r ≈ 0.06 ft).
        /// A ball touching any part of the line is IN.
        var ballRadiusFeet: Double = 0.06
        /// Below this distance (feet) the call is TOO CLOSE (≈ error band).
        var tooCloseBand: Double = 0.12   // ~3.7 cm
        /// Below this confidence, emit TOO CLOSE regardless of distance.
        var minConfidence: Float = 0.45
    }

    var config = Config()

    /// - Returns: the call for the bounce, considering only lines that bound
    /// the officiated half (baseline, both sidelines, kitchen line).
    func call(for bounce: BounceEvent) -> LineCall? {
        let p = bounce.courtPoint

        // Find nearest line and distance to it.
        var bestDist = Double.infinity
        var bestInside = false
        for line in CourtGeometry.lines {
            let d = distanceToSegment(point: p, line: line)
            if d < bestDist {
                bestDist = d
                bestInside = isInsideCourt(p, near: line)
            }
        }
        guard bestDist.isFinite else { return nil }

        // Effective distance: subtract ball radius (ball edge touching line = IN).
        let margin = bestDist - config.ballRadiusFeet
        let signedMargin = bestInside ? -margin : margin

        let confidence = bounce.confidence
        var verdict = CallVerdict.tooClose
        if abs(signedMargin) > config.tooCloseBand && confidence >= config.minConfidence {
            verdict = signedMargin < 0 ? .in_ : .out
        }

        return LineCall(verdict: verdict,
                        bounce: bounce,
                        distanceToLine: signedMargin,
                        confidence: confidence)
    }

    // MARK: - Geometry

    private func distanceToSegment(point: CourtGeometry.Point, line: CourtGeometry.LineSegment) -> Double {
        let ax = line.a.x, ay = line.a.y
        let bx = line.b.x, by = line.b.y
        let dx = bx - ax, dy = by - ay
        let len2 = dx*dx + dy*dy
        guard len2 > 0 else { return hypot(point.x - ax, point.y - ay) }
        var t = ((point.x - ax) * dx + (point.y - ay) * dy) / len2
        t = max(0, min(1, t))
        let cx = ax + t * dx, cy = ay + t * dy
        return hypot(point.x - cx, point.y - cy)
    }

    /// Inside = within the officiated half's playable region for the line
    /// being considered. For the near half (y ∈ [0, 22], x ∈ [-10, 10]):
    /// - baseline: inside = y > 0
    /// - sidelines: inside = |x| < 10
    /// - kitchen line: inside (for the NVZ boundary) = y < 15 side is NVZ;
    ///   for ball calls the kitchen line behaves like any line: touching = in.
    private func isInsideCourt(_ p: CourtGeometry.Point, near line: CourtGeometry.LineSegment) -> Bool {
        // Distance comparison to court interior center (0, 11) is a robust
        // POC proxy: "inside" = closer to court center than to outside.
        // For each line, the interior is the side containing the court center.
        let center = CourtGeometry.Point(x: 0, y: 11)
        let ax = line.a.x, ay = line.a.y
        let bx = line.b.x, by = line.b.y
        // Cross product sign tells which side p and center are on.
        let crossP = (bx - ax) * (p.y - ay) - (by - ay) * (p.x - ax)
        let crossC = (bx - ax) * (center.y - ay) - (by - ay) * (center.x - ax)
        return sign(crossP) == sign(crossC)
    }

    private func sign(_ v: Double) -> Double { v >= 0 ? 1 : -1 }
}
