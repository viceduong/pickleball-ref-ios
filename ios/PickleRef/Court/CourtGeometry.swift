import Foundation

/// Official pickleball court dimensions (USAPA), in feet.
enum CourtGeometry {
    static let courtWidth: Double = 20.0            // sidelines (doubles court)
    static let courtLength: Double = 44.0           // baseline to baseline
    static let kitchenLength: Double = 7.0          // NVZ depth from net
    static let kitchenLineWidth: Double = 0.041_667 // 0.5 in lines are part of NVZ

    /// All lines bounding the NVZ are part of the NVZ (rule 2.B.3): a ball
    /// touching any part of the line is IN.
    static let lineWidth: Double = 0.041_667

    /// Court coordinate system (feet), origin at center of the near baseline,
    /// +x to the right (viewed from behind the near baseline), +y toward the
    /// net. The officiated half is y ∈ [0, 22].
    //
    //            net (y = 22)
    //    ┌───────────┬───────────┐
    //    │  kitchen  │  kitchen  │
    //    ├───────────┴───────────┤  kitchen line (y = 15)
    //    │                       │
    //    │      service area     │
    //    │                       │
    //    └───────────────────────┘  near baseline (y = 0)
    //   x=-10                  x=+10

    /// Lines of the officiated half, as segments in court coordinates.
    /// Ball call zones: sidelines, baseline, kitchen line.
    static var lines: [LineSegment] {
        [
            // Near baseline
            LineSegment(a: Point(x: -10, y: 0), b: Point(x: 10, y: 0)),
            // Left sideline (near half)
            LineSegment(a: Point(x: -10, y: 0), b: Point(x: -10, y: 22)),
            // Right sideline (near half)
            LineSegment(a: Point(x: 10, y: 0), b: Point(x: 10, y: 22)),
            // Kitchen line
            LineSegment(a: Point(x: -10, y: 15), b: Point(x: 10, y: 15)),
        ]
    }

    struct Point { var x: Double; var y: Double }

    struct LineSegment {
        var a: Point
        var b: Point
    }
}
