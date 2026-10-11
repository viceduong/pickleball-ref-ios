import AVFoundation
import CoreVideo
import Foundation

/// One processed frame from the camera pipeline.
struct VideoFrame {
    let pixelBuffer: CVPixelBuffer
    let time: CMTime
    var timeSeconds: Double { CMTimeGetSeconds(time) }
}

/// Captures high-frame-rate video and forwards frames + timestamps.
///
/// Design notes:
/// - Requests the highest supported frame rate in the 30...240 fps range with
///   the best resolution available at that rate (POC: prefer 120 fps at 1080p).
/// - Uses `videoDataOutput` with a dedicated serial queue; frames are dropped
///   if the consumer is slower than capture (alwaysDropStale mode) so latency
///   stays bounded.
/// - Exposure is locked to a short duration where possible: motion blur is the
///   enemy of ball localization. A fast shutter (1/1000 s or faster) trades
///   noise for sharpness, which is the right trade in daylight.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    enum CaptureError: LocalizedError {
        case noCamera
        case configurationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noCamera: return "No back camera found on this device."
            case .configurationFailed(let msg): return "Camera configuration failed: \(msg)"
            }
        }
    }

    struct Configuration {
        var targetFrameRate: Int32 = 120
        var preferredSize = CGSize(width: 1920, height: 1080)
        /// Lock exposure to a fast shutter if the device supports it.
        var lockFastShutter = true
    }

    private let session = AVCaptureSession()

    /// Exposed read-only for the preview layer.
    var captureSession: AVCaptureSession { session }
    private let sessionQueue = DispatchQueue(label: "pickleref.camera.session")
    private let videoOutput = AVCaptureVideoDataOutput()

    /// Called on the capture queue for every delivered frame.
    /// Set once before `start()`; the handler must be safe to invoke from the
    /// capture queue (i.e. not touch MainActor state directly).
    var onFrame: ((VideoFrame) -> Void)?

    private(set) var activeFrameRate: Double = 0
    private(set) var dimensions: CMVideoDimensions = .init(width: 0, height: 0)
    private(set) var isRunning = false

    /// Thread-safe snapshot of running state for callers outside the queue.
    var running: Bool { sessionQueue.sync { isRunning } }

    private let config: Configuration

    init(config: Configuration = Configuration()) {
        self.config = config
        super.init()
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }
        try configureSession()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.startRunning()
            self.isRunning = self.session.isRunning
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            self.isRunning = false
        }
    }

    // MARK: - Configuration

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video) else {
            throw CaptureError.noCamera
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CaptureError.configurationFailed("cannot add camera input")
        }
        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(videoOutput) else {
            throw CaptureError.configurationFailed("cannot add video output")
        }
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            // POC officiates the near half; portrait gives the most vertical
            // court coverage when the phone is mounted upright.
        }

        try applyFrameRate(to: device)
    }

    /// Selects the best (fps, resolution) format and locks a fast shutter.
    private func applyFrameRate(to device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // Find format + frame-rate range closest to target.
        var best: (format: AVCaptureDevice.Format, fps: Double, score: Double)?
        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                let fps = Double(range.maxFrameRate)
                guard fps >= 60 else { continue }
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                // Score: prefer fps >= target, then highest resolution.
                let fpsScore = min(fps, Double(config.targetFrameRate))
                let pxScore = Double(dims.width * dims.height) / 4_000_000
                let score = fpsScore + pxScore
                if best == nil || score > best!.score {
                    best = (format, fps, score)
                }
            }
        }

        guard let chosen = best else {
            throw CaptureError.configurationFailed("no format with fps >= 60")
        }

        let fps = min(chosen.fps, Double(config.targetFrameRate))
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        if device.activeFormat.supportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= fps && $0.maxFrameRate >= fps
        }) {
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            activeFrameRate = fps
        }

        dimensions = CMVideoFormatDescriptionGetDimensions(chosen.format.formatDescription)

        if config.lockFastShutter {
            // Clamp exposure to <= 1/1000 s to cut motion blur. On failure we
            // simply keep auto exposure; the POC still functions.
            let maxDuration = CMTime(value: 1, timescale: 1000)
            if device.activeFormat.maxExposureDuration > maxDuration {
                device.activeVideoMaxExposureDuration = maxDuration
            }
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = sampleBuffer.imageBuffer,
              CMSampleBufferGetIsValid(sampleBuffer) else { return }
        let frame = VideoFrame(pixelBuffer: buffer, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        onFrame?(frame)
    }
}
