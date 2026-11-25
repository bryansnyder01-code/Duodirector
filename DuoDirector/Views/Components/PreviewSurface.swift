import AVFoundation
import SwiftUI
import UIKit

/// The camera picture (live or mock) + the peaking/zebra overlay + tap-to-focus.
/// Used by the inner viewfinder and, mirrored, by the outer cover monitor.
///
/// The analysis overlay is drawn INSIDE this view, before the mirror transform, so it
/// gets the same aspect-fill crop and the same mirroring as the picture underneath.
struct PreviewSurface: View {
    let state: StudioSessionState
    let engine: CameraEngine
    var role: CaptureSessionController.CameraRole = .rear
    /// Mirror horizontally (the cover monitor faces the talent, so it reads like a mirror).
    var mirrored = false
    var showsAnalysisOverlay = true

    @State private var focusIndicator: CGPoint?

    var body: some View {
        ZStack {
            switch state.sourceMode {
            case .live:
                LivePreviewLayerView(controller: engine.controller, role: role) { devicePoint, layerPoint in
                    engine.focus(atDevicePoint: devicePoint)
                    showFocus(at: layerPoint)
                }
                // Rebuild only when the engine REPLACES the session (single ↔ multicam).
                // Lens switches keep the same session, so this layer stays attached.
                .id(state.sessionGeneration)
            case .mock:
                // Demo Mode hides the "SIMULATED" caption so screenshots are clean.
                MockCameraFeedView(store: engine.overlayStore, role: role, showsLabel: !state.isDemoMode)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        engine.focus(atDevicePoint: .zero)
                        showFocus(at: location)
                    }
            }

            if showsAnalysisOverlay && role == .rear {
                FocusPeakingMetalOverlay(store: engine.overlayStore)
            }

            if let point = focusIndicator {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.yellow, lineWidth: 1.5)
                    .frame(width: 64, height: 64)
                    .position(point)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        // scaleEffect mirrors rendering AND hit-testing, so the UIKit tap location is
        // already in the layer's own (un-mirrored) coordinates.
        .scaleEffect(x: mirrored ? -1 : 1, y: 1)
        .clipped()
    }

    private func showFocus(at point: CGPoint) {
        withAnimation(.easeOut(duration: 0.15)) { focusIndicator = point }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation { focusIndicator = nil }
        }
    }
}

/// UIKit host for AVCaptureVideoPreviewLayer.
struct LivePreviewLayerView: UIViewRepresentable {
    let controller: CaptureSessionController
    let role: CaptureSessionController.CameraRole
    let onTap: (_ devicePoint: CGPoint, _ layerPoint: CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.onTap = onTap
        controller.sessionQueue.async {
            let layer = controller.makePreviewLayer(for: role)
            layer.videoGravity = .resizeAspectFill
            DispatchQueue.main.async { view.install(layer) }
        }
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        uiView.onTap = onTap
    }

    final class PreviewHostView: UIView {
        var onTap: ((CGPoint, CGPoint) -> Void)?
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?
        private var inputObservation: NSKeyValueObservation?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func install(_ layer: AVCaptureVideoPreviewLayer) {
            previewLayer?.removeFromSuperlayer()
            layer.frame = bounds
            self.layer.addSublayer(layer)
            previewLayer = layer
            bindRotation()
            // A lens switch replaces the device input, which re-creates the layer's
            // connection. Re-bind the rotation coordinator to the new device when it does.
            inputObservation = layer.observe(\.connection, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.bindRotation() }
            }
        }

        private func bindRotation() {
            guard let layer = previewLayer,
                  let device = (layer.connection?.inputPorts.first?.input as? AVCaptureDeviceInput)?.device else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
            rotationCoordinator = coordinator
            layer.connection?.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview) { [weak layer] coordinator, _ in
                DispatchQueue.main.async {
                    layer?.connection?.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
                }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let layer = previewLayer else { return }
            let point = recognizer.location(in: self)
            onTap?(layer.captureDevicePointConverted(fromLayerPoint: point), point)
        }
    }
}

/// Simulator stand-in for the camera: shows MockFrameSource's synthetic frames, which are
/// the same frames the analyzer processes, so the peaking/zebra overlay lines up.
struct MockCameraFeedView: View {
    let store: AnalysisOverlayStore
    var role: CaptureSessionController.CameraRole = .rear
    var showsLabel = true

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Phase 4: the inner role gets its own synthetic "host" scene (warm desk, 15 fps)
            // so Demo Mode screenshots show two distinct angles.
            if let frame = role == .rear ? store.mockFrame : store.mockInnerFrame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [.orange.opacity(0.5), .brown.opacity(0.4)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            if showsLabel {
                Text(role == .rear ? "SIMULATED REAR · GUEST" : "SIMULATED INNER · HOST")
                    .font(.caption2.monospaced().bold())
                    .padding(6)
                    .background(.black.opacity(0.5), in: .rect(cornerRadius: 4))
                    .padding(8)
            }
        }
        .background(.black)
    }
}
