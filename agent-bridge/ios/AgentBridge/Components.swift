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



/// Full-screen scan page, presented modally (e.g. `.fullScreenCover`) so
/// scanning reads as its own step rather than content inlined on whatever
/// page requested it. Dismisses itself once `onCode` reports success.
struct QRScanScreen: View {
    var onCode: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @State private var denied = false
    @State private var torchOn = false
    @State private var torchAvailable = false
    @State private var focusPoint: CGPoint?
    @State private var focusTrigger = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if denied {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("没有相机权限")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("请在系统设置里允许 ArcLink 使用相机，然后重新扫描 Mac 上的二维码。")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            } else {
                AVCaptureQRScanner(torchOn: torchOn, onCode: { code in
                    let ok = await onCode(code)
                    if ok { dismiss() }
                    return ok
                }, onFocusTap: { point in
                    focusPoint = point
                    focusTrigger += 1
                })
                .ignoresSafeArea()
                QRViewfinderOverlay()
                if let focusPoint {
                    FocusRing()
                        .position(focusPoint)
                        .id(focusTrigger)
                        .allowsHitTesting(false)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Button {
                    store.cancelPairing()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.18), in: Circle())
                }
                .accessibilityLabel("关闭扫描")
                Spacer()
                if !denied && torchAvailable {
                    Button {
                        torchOn.toggle()
                    } label: {
                        Image(systemName: torchOn ? "bolt.fill" : "bolt.slash.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(torchOn ? .yellow : .white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.18), in: Circle())
                    }
                    .accessibilityLabel(torchOn ? "关闭手电筒" : "打开手电筒，弱光下扫描")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom) {
            if !denied {
                Text("将二维码放入框内，自动识别；点按画面可对焦")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.bottom, 28)
            }
        }
        .overlay(alignment: .bottom) {
            // `store.toast` (e.g. "扫到的不是 Mac 配对码", a failed-pair
            // message) is normally shown by `RootView`'s own overlay, but a
            // `.fullScreenCover` completely occludes the presenting view —
            // without this, every failure here was silent: the scan screen
            // just sat there looking unresponsive.
            if let toast = store.toast {
                ToastBanner(text: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onDisappear { store.cancelPairing() }
        .animation(.easeOut(duration: 0.2), value: store.toast)
        .task {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                denied = !granted
            } else {
                denied = status == .denied || status == .restricted
            }
            torchAvailable = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)?.hasTorch ?? false
        }
        .onDisappear { torchOn = false }
    }
}

/// Brief ring that expands and fades at a tap-to-focus point, giving the
/// native "focusing here" feedback real camera apps show.
private struct FocusRing: View {
    @State private var scale: CGFloat = 1.5
    @State private var opacity: Double = 1

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.yellow, lineWidth: 1.5)
            .frame(width: 62, height: 62)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                scale = 1.5
                opacity = 1
                withAnimation(.easeOut(duration: 0.5)) {
                    scale = 1.0
                    opacity = 0
                }
            }
    }
}

/// Dims everything outside a centered square, outlining it, so the scan
/// target reads clearly against the live camera feed.
private struct QRViewfinderOverlay: View {
    @State private var sweepDown = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) * 0.68
            let travel = side / 2 - 16
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .frame(width: side, height: side)
                            .blendMode(.destinationOut)
                    )
                    .compositingGroup()
                QRCornerBrackets()
                    .frame(width: side, height: side)
                ZStack {
                    LinearGradient(
                        colors: [.clear, Color.green.opacity(0.95), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(height: 2.5)
                    .shadow(color: .green.opacity(0.8), radius: 6)
                    .padding(.horizontal, 10)
                    .offset(y: sweepDown ? travel : -travel)
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) {
                sweepDown = true
            }
        }
    }
}

/// Four L-shaped corner marks instead of a full border — the common native
/// look for a scan target, and it reads better against a live camera feed.
private struct QRCornerBrackets: View {
    var length: CGFloat = 26
    var thickness: CGFloat = 3
    var cornerRadius: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ForEach(0..<4, id: \.self) { corner in
                Path { path in
                    let (x, y, dx, dy): (CGFloat, CGFloat, CGFloat, CGFloat) = switch corner {
                    case 0: (0, 0, 1, 1)
                    case 1: (w, 0, -1, 1)
                    case 2: (0, h, 1, -1)
                    default: (w, h, -1, -1)
                    }
                    path.move(to: CGPoint(x: x + dx * cornerRadius, y: y))
                    path.addLine(to: CGPoint(x: x + dx * (cornerRadius + length), y: y))
                    path.move(to: CGPoint(x: x, y: y + dy * cornerRadius))
                    path.addLine(to: CGPoint(x: x, y: y + dy * (cornerRadius + length)))
                }
                .stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: thickness, lineCap: .round))
            }
        }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct AVCaptureQRScanner: UIViewRepresentable {
    var torchOn: Bool = false
    var onCode: (String) async -> Bool
    var onFocusTap: (CGPoint) -> Void = { _ in }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = context.coordinator.session
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.previewView = view
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.start()
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.setTorch(on: torchOn)
        context.coordinator.onFocusTap = onFocusTap
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(onCode: onCode)
        coordinator.onFocusTap = onFocusTap
        return coordinator
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        let onCode: (String) async -> Bool
        var onFocusTap: (CGPoint) -> Void = { _ in }
        weak var previewView: PreviewView?
        private var handled = false
        private var device: AVCaptureDevice?

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
                    self.device = device
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

        /// Toggles the back camera's torch for scanning in low light. A
        /// missing/unsupported torch (front camera, simulator) is a quiet
        /// no-op — `QRScanScreen` only shows the button when `hasTorch`.
        func setTorch(on: Bool) {
            DispatchQueue.global(qos: .userInitiated).async { [device] in
                guard let device, device.hasTorch, device.isTorchModeSupported(on ? .on : .off) else { return }
                do {
                    try device.lockForConfiguration()
                    device.torchMode = on ? .on : .off
                    device.unlockForConfiguration()
                } catch {
                    // Losing the torch toggle is not fatal to scanning.
                }
            }
        }

        /// Tap-to-focus: points the camera's focus/exposure at the tapped
        /// spot (mirrors the system Camera app) and reports the tap's
        /// on-screen location so SwiftUI can show a focus ring there.
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let previewView else { return }
            let point = gesture.location(in: previewView)
            let devicePoint = previewView.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            focus(at: devicePoint)
            onFocusTap(point)
        }

        /// Re-aims continuous AF/AE at the tapped point without switching to
        /// a one-shot focus mode — a one-shot lock would freeze focus at
        /// whatever distance that tap happened to be, so any later QR code
        /// at a different distance/position would stay out of focus and
        /// never decode.
        private func focus(at devicePoint: CGPoint) {
            DispatchQueue.global(qos: .userInitiated).async { [device] in
                guard let device else { return }
                do {
                    try device.lockForConfiguration()
                    if device.isFocusPointOfInterestSupported {
                        device.focusPointOfInterest = devicePoint
                    }
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = devicePoint
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    device.unlockForConfiguration()
                } catch {
                    // A missed focus request still leaves continuous
                    // autofocus running from `start()`.
                }
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
