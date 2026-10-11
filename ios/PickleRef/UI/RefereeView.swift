import SwiftUI
import AVFoundation

/// Main referee screen: live camera preview, latest call HUD, call history.
struct RefereeView: View {
    @StateObject private var vm = RefereeViewModel()
    @State private var showCalibration = false

    var body: some View {
        ZStack {
            CameraPreviewView(service: vm.cameraForPreview)
                .ignoresSafeArea()

            VStack {
                header
                Spacer()
                callHUD
                historyStrip
            }
        }
        .sheet(isPresented: $showCalibration) {
            CalibrationView(vm: vm)
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(vm.runState.rawValue)
                    .font(.headline)
                    .foregroundColor(.white)
                Text("\(Int(vm.fps)) fps · track \(Int(vm.trackQuality * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.8))
                if !vm.statusMessage.isEmpty {
                    Text(vm.statusMessage)
                        .font(.caption2)
                        .foregroundColor(.yellow)
                }
            }
            Spacer()
            Button(showCalibration ? "Done" : "Calibrate") {
                showCalibration.toggle()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.black.opacity(0.45))
    }

    private var callHUD: some View {
        VStack(spacing: 8) {
            if let call = vm.latestCall {
                Text(call.verdict.rawValue)
                    .font(.system(size: 64, weight: .black, design: .rounded))
                    .foregroundColor(color(for: call.verdict))
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.6))
                    .cornerRadius(16)
                Text(String(format: "margin %.1f cm · conf %.0f%%",
                            call.distanceToLine * 30.48,
                            call.confidence * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.85))
                    .padding(6)
                    .background(.black.opacity(0.5))
                    .cornerRadius(8)
            }
        }
        .animation(.spring(), value: vm.latestCall?.bounce.time)
    }

    private var historyStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(vm.callHistory.prefix(12).enumerated()), id: \.offset) { _, call in
                    VStack(spacing: 2) {
                        Text(call.verdict.rawValue)
                            .font(.caption.bold())
                            .foregroundColor(color(for: call.verdict))
                        Text(String(format: "%.0f%%", call.confidence * 100))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                }
            }
            .padding()
        }
    }

    private func color(for v: CallVerdict) -> Color {
        switch v {
        case .in_: return .green
        case .out: return .red
        case .tooClose: return .orange
        }
    }
}

/// AVCaptureVideoPreviewLayer wrapper.
struct CameraPreviewView: UIViewRepresentable {
    let service: CameraService

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = service.captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}
