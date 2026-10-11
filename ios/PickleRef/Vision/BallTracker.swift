import Foundation
import CoreGraphics

/// A ball observation with image-space position and confidence.
struct BallObservation {
    let time: Double          // seconds (monotonic capture clock)
    let imagePoint: CGPoint
    let radius: Float
    let confidence: Float
}

/// Temporal ball tracker.
///
/// Responsibilities:
/// - Gate detections against a constant-velocity motion model (alpha-beta filter).
/// - Bridge short occlusion gaps by coasting on the motion model, marking
///   coasted observations with low confidence.
/// - Feed the bounce detector a clean sequence of observations.
///
/// Deliberately simple: gating quality comes from the physics-aware trajectory
/// fit in `BounceDetector`; this filter only maintains association.
final class BallTracker {

    struct Config {
        /// Max distance (px) between predicted and detected position to accept.
        var gatePixels: CGFloat = 260
        /// Frames to coast (predict without detection) before dropping track.
        var maxCoastFrames = 12
        var processNoise: CGFloat = 40      // px/s²
        var measurementNoise: CGFloat = 2.5
    }

    var config = Config()

    private var pos: CGPoint?
    private var vel: CGPoint = .zero
    private var covariance: CGFloat = 20
    private var lastTime: Double = 0
    private var coastCount = 0

    private(set) var track: [BallObservation] = []

    // MARK: - Public API

    /// Feed one frame's detection result. Returns the observation used
    /// (measured or coasted) or nil if the track was lost.
    @discardableResult
    func update(time: Double, detection: BallDetection?, frameRate: Double) -> BallObservation? {
        defer { lastTime = time }
        let dt = lastTime > 0 ? max(1e-3, time - lastTime) : 1.0 / max(1, frameRate)

        guard let det = detection else {
            return coast(time: time, dt: dt)
        }

        if let p = pos {
            let predicted = CGPoint(x: p.x + vel.x * CGFloat(dt), y: p.y + vel.y * CGFloat(dt))
            let dist = hypot(det.center.x - predicted.x, det.center.y - predicted.y)
            guard dist <= config.gatePixels else {
                return coast(time: time, dt: dt)
            }
            // Alpha-beta update.
            let alpha = covariance / (covariance + config.measurementNoise)
            let residual = CGPoint(x: det.center.x - predicted.x, y: det.center.y - predicted.y)
            pos = CGPoint(x: predicted.x + alpha * residual.x,
                          y: predicted.y + alpha * residual.y)
            vel = CGPoint(x: vel.x + alpha * alpha * 0.25 * residual.x / CGFloat(dt),
                          y: vel.y + alpha * alpha * 0.25 * residual.y / CGFloat(dt))
            covariance = (1 - alpha) * covariance + config.processNoise * CGFloat(dt * dt)
            coastCount = 0
        } else {
            pos = det.center
            vel = .zero
        }

        let obs = BallObservation(time: time, imagePoint: det.center,
                                  radius: det.radius, confidence: det.confidence)
        track.append(obs)
        return obs
    }

    /// Trim history to the last `seconds`.
    func trimHistory(to seconds: Double, now: Double) {
        track.removeAll { $0.time < now - seconds }
    }

    func reset() {
        pos = nil
        vel = .zero
        covariance = 20
        track.removeAll()
        coastCount = 0
        lastTime = 0
    }

    // MARK: - Coasting (occlusion bridging)

    private func coast(time: Double, dt: Double) -> BallObservation? {
        guard let p = pos else { return nil }
        coastCount += 1
        guard coastCount <= config.maxCoastFrames else {
            reset()
            return nil
        }
        let predicted = CGPoint(x: p.x + vel.x * CGFloat(dt), y: p.y + vel.y * CGFloat(dt))
        pos = predicted
        let obs = BallObservation(time: time, imagePoint: predicted,
                                  radius: track.last?.radius ?? 4,
                                  confidence: 0.15) // interpolated, low confidence
        track.append(obs)
        return obs
    }
}
