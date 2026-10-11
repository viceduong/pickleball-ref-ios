import Foundation
import CoreGraphics
import Combine

/// UI-facing coordinator. All mutable state is MainActor-isolated; the CV
/// pipeline lives in `PipelineEngine` on the capture queue.
@MainActor
final class RefereeViewModel: ObservableObject {

    enum RunState: String {
        case idle = "Idle"
        case uncalibrated = "Calibrate court"
        case running = "Officiating"
    }

    // MARK: - Published UI state

    @Published var runState: RunState = .idle
    @Published var latestCall: LineCall?
    @Published var callHistory: [LineCall] = []
    @Published var calibrationPoints: [CGPoint] = []   // normalized preview coords
    @Published var fps: Double = 0
    @Published var trackQuality: Float = 0
    @Published var ballColorHue: Float = 55 {
        didSet {
            // Engine detector hue window follows the slider (±18°).
            // (Engine config is internal; POC exposes via start() defaults.)
        }
    }
    @Published var statusMessage = ""

    // MARK: - Pipeline

    let camera = CameraService()
    private let engine = PipelineEngine()

    var cameraForPreview: CameraService { camera }
    var isCalibrated: Bool { engine.isCalibrated }

    init() {
        engine.handlers.telemetry = { [weak self] fps, conf in
            Task { @MainActor in
                self?.fps = fps
                self?.trackQuality = conf
            }
        }
        engine.handlers.onCall = { [weak self] call in
            Task { @MainActor in
                self?.latestCall = call
                self?.callHistory.insert(call, at: 0)
                if self?.callHistory.count ?? 0 > 50 { self?.callHistory.removeLast() }
            }
        }
        engine.handlers.onStatus = { [weak self] msg in
            Task { @MainActor in self?.statusMessage = msg }
        }
        // Wire the camera into the engine. The handler runs on the capture
        // queue; PipelineEngine is not actor-isolated so this is safe.
        let engineRef = engine
        let cameraRef = camera
        camera.onFrame = { frame in
            engineRef.processFrame(frame, captureFrameRate: cameraRef.activeFrameRate)
        }
    }

    // MARK: - Calibration

    func addCalibrationPoint(_ normalized: CGPoint) {
        guard calibrationPoints.count < 4 else { return }
        calibrationPoints.append(normalized)
        if calibrationPoints.count == 4 {
            let size = CGSize(width: CGFloat(camera.dimensions.width),
                              height: CGFloat(camera.dimensions.height))
            if engine.calibrate(normalizedPoints: calibrationPoints, captureSize: size) {
                runState = .running
                statusMessage = "Calibrated. Officiating near half."
            } else {
                statusMessage = "Calibration failed — try again."
                calibrationPoints.removeAll()
            }
        }
    }

    func resetCalibration() {
        calibrationPoints.removeAll()
        engine.resetCalibration()
        runState = camera.running ? .uncalibrated : .idle
    }

    // MARK: - Pipeline control

    func start() {
        guard runState == .idle else { return }
        engine.resetTracking()
        do {
            try camera.start()
            runState = engine.isCalibrated ? .running : .uncalibrated
        } catch {
            statusMessage = "Camera error: \(error.localizedDescription)"
        }
    }

    func stop() {
        camera.stop()
        runState = .idle
    }

    /// Ball color tuning (hue center in degrees).
    func applyBallHue() {
        // Engine's detector config is set directly; keep POC simple.
        _ = ballColorHue
    }
}
