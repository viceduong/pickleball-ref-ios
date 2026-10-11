import SwiftUI

/// Calibration screen: tap the four court corners in order (near-left
/// baseline → near-right baseline → near-right kitchen → near-left kitchen).
/// Taps are recorded in normalized preview coordinates (0...1) so they map
/// cleanly onto the capture buffer regardless of preview scaling.
struct CalibrationView: View {
    @ObservedObject var vm: RefereeViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Tap surface over the live preview. iOS 15-compatible:
                // DragGesture(minimumDistance: 0) reports location in local
                // coordinates (onTapGesture(coordinateSpace:) is iOS 17+).
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        let local = value.location
                        let frame = value.startLocation
                        _ = frame
                        vm.addCalibrationPoint(CGPoint(x: local.x / geo.size.width,
                                                       y: local.y / geo.size.height))
                    })

                // Tap markers + connecting quad outline.
                ForEach(Array(vm.calibrationPoints.enumerated()), id: \.offset) { idx, p in
                    VStack(spacing: 2) {
                        Circle()
                            .stroke(Color.yellow, lineWidth: 2)
                            .background(Circle().fill(Color.yellow.opacity(0.6)))
                            .frame(width: 18, height: 18)
                        Text("\(idx + 1)")
                            .font(.caption2.bold())
                            .foregroundColor(.yellow)
                    }
                    .position(x: p.x * geo.size.width, y: p.y * geo.size.height)
                }
            }
        }
        .overlay(alignment: .top) { instructions }
        .overlay(alignment: .bottom) { controls }
    }

    private var instructions: some View {
        VStack(spacing: 6) {
            Text("Tap the 4 court corners in order")
                .font(.headline)
            Text("① near-left baseline   ② near-right baseline\n③ near-right kitchen   ④ near-left kitchen")
                .font(.footnote)
                .multilineTextAlignment(.center)
            if !vm.statusMessage.isEmpty {
                Text(vm.statusMessage)
                    .font(.caption)
                    .foregroundColor(.yellow)
            }
        }
        .padding(12)
        .background(.thinMaterial)
        .cornerRadius(12)
        .padding()
    }

    private var controls: some View {
        HStack {
            Button("Reset") { vm.resetCalibration() }
            Spacer()
            Button("Done") { dismiss() }
        }
        .buttonStyle(.borderedProminent)
        .padding()
        .background(.thinMaterial)
    }
}
