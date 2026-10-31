import AVFoundation
import SwiftUI

struct Pill: View {
    var text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct MacQRScanner: View {
    var onCode: (String) async -> Bool
    @State private var denied = false

    var body: some View {
        Group {
            if denied {
                Text("没有相机权限。请在系统设置里允许 Agent Bridge 使用相机，然后扫描 Mac 上的二维码。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                AVCaptureQRScanner(onCode: onCode)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                denied = !granted
            } else {
                denied = status == .denied || status == .restricted
            }
        }
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct AVCaptureQRScanner: UIViewRepresentable {
    var onCode: (String) async -> Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = context.coordinator.session
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.start()
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        let onCode: (String) async -> Bool
        private var handled = false

        init(onCode: @escaping (String) async -> Bool) {
            self.onCode = onCode
        }

        func start() {
            let configuration = { [session] in
                session.beginConfiguration()
                session.sessionPreset = .high
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: device),
                   session.canAddInput(input) {
                    session.addInput(input)
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        try? device.lockForConfiguration()
                        device.focusMode = .continuousAutoFocus
                        if device.isFocusPointOfInterestSupported {
                            device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                        }
                        device.unlockForConfiguration()
                    }
                }
                let output = AVCaptureMetadataOutput()
                if session.canAddOutput(output) {
                    session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: .main)
                    output.metadataObjectTypes = output.availableMetadataObjectTypes.filter { $0 == .qr }
                }
                session.commitConfiguration()
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                configuration()
                self.session.startRunning()
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !handled else { return }
            for case let object as AVMetadataMachineReadableCodeObject in metadataObjects where object.type == .qr {
                guard let value = object.stringValue else { continue }
                handled = true
                let callback = onCode
                Task { @MainActor in
                    let ok = await callback(value)
                    if !ok { self.handled = false }
                }
                return
            }
        }
    }
}

struct ToastBanner: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.primary, in: Capsule())
            .foregroundStyle(Color(.systemBackground))
            .padding(.bottom, 24)
            .accessibilityIdentifier("toast")
    }
}
