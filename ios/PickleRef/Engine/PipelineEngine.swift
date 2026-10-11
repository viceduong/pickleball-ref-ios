import Foundation
import CoreGraphics

/// The real-time CV pipeline, intentionally NOT MainActor-isolated: it runs
/// on the camera capture queue where frames arrive. Publishes results back to
/// the UI via callbacks that hop to the main actor.
///
/// owns: detector → tracker → bounce detector → call engine → replay buffer.
final class PipelineEngine {

    struct Handlers {
        /// Called on the capture queue for lightweight per-frame telemetry.
        var telemetry: ((_ fps: Double, _ trackConfidence: Float) -> Void)?
        /// Called when a line call is made (already hopped to main).
        var onCall: ((LineCall) -> Void)?
        var onStatus: ((String) -> Void)?
    }

    var handlers = Handlers()

    private let ringBuffer = FrameRingBuffer()
    private let detector = BallDetector()
    private let tracker = BallTracker()
    private let bounceDetector = BounceDetector()
    private let callEngine = LineCallEngine()
    private let replay = ReplayBuffer()

    private(set) var homography = Homography()

    private var frameCount = 0
    private var fpsWindowStart: Double = 0
    private var measuredFPS: Double = 0

    // MARK: - Calibration

    /// Calibrate from normalized preview coords (0...1).
    func calibrate(normalizedPoints: [CGPoint], captureSize: CGSize) -> Bool {
        guard normalizedPoints.count == 4, captureSize.width > 0 else { return false }
        let imagePts = normalizedPoints.map {
            CGPoint(x: $0.x * captureSize.width, y: $0.y * captureSize.height)
        }
        guard let H = Homography.estimate(imagePoints: imagePts,
                                          courtPoints: RefereeModel.calibrationCourtPoints) else {
            return false
        }
        homography = H
        return true
    }

    func resetCalibration() {
        homography = Homography()
    }

    var isCalibrated: Bool { homography.isCalibrated }

    // MARK: - Frame processing (capture queue)

    func processFrame(_ frame: VideoFrame, captureFrameRate: Double) {
        let effectiveFPS = measuredFPS > 30 ? measuredFPS : max(30, captureFrameRate)

        let detection = detector.detect(in: frame.pixelBuffer)
        let obs = tracker.update(time: frame.timeSeconds,
                                 detection: detection,
                                 frameRate: effectiveFPS)
        ringBuffer.append(frame)
        tracker.trimHistory(to: 1.0, now: frame.timeSeconds)

        // FPS meter.
        frameCount += 1
        if fpsWindowStart == 0 { fpsWindowStart = frame.timeSeconds }
        let elapsed = frame.timeSeconds - fpsWindowStart
        if elapsed > 1 {
            measuredFPS = Double(frameCount) / elapsed
            frameCount = 0
            fpsWindowStart = frame.timeSeconds
        }

        // Telemetry (cheap; capture queue is fine for a label update).
        handlers.telemetry?(Double(measuredFPS), obs?.confidence ?? 0)

        guard isCalibrated, let obs else { return }

        if let bounce = bounceDetector.detect(track: tracker.track, homography: homography) {
            let clip = ringBuffer.clip(around: bounce.time, seconds: 1.0)
            if let call = callEngine.call(for: bounce) {
                replay.save(call: call, frames: clip)
                handlers.onCall?(call)
            }
        }
    }

    func resetTracking() {
        tracker.reset()
        bounceDetector.reset()
        ringBuffer.removeAll()
    }
}

/// Static model data shared between the engine and the view model.
enum RefereeModel {
    /// Court corners to tap, in order. Origin = near-baseline center,
    /// +y toward the net (feet).
    static let calibrationCourtPoints: [CourtGeometry.Point] = [
        .init(x: -10, y: 0),   // near-left baseline corner
        .init(x: 10, y: 0),    // near-right baseline corner
        .init(x: 10, y: 15),   // near-right kitchen-line corner
        .init(x: -10, y: 15),  // near-left kitchen-line corner
    ]
}
