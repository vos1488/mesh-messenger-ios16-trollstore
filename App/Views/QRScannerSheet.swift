import SwiftUI

#if canImport(AVFoundation) && canImport(UIKit)
import AVFoundation
import UIKit

struct QRScannerSheet: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QRScannerRepresentable { code in
                onScan(code)
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Сканер QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> QRScannerViewController {
        QRScannerViewController(onScan: context.coordinator.handleScan)
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}

    final class Coordinator {
        private let onScan: (String) -> Void
        private var didScan = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func handleScan(_ value: String) {
            guard !didScan else { return }
            didScan = true
            onScan(value)
        }
    }
}

private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let onScan: (String) -> Void
    private var configured = false

    init(onScan: @escaping (String) -> Void) {
        self.onScan = onScan
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            setupCaptureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCaptureSession()
                    } else {
                        self?.showPermissionHint()
                    }
                }
            }
        case .restricted, .denied:
            showPermissionHint()
        @unknown default:
            showPermissionHint()
        }
    }

    private func setupCaptureSession() {
        guard let videoDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              captureSession.canAddInput(videoInput) else {
            showCameraUnavailable()
            return
        }
        captureSession.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(metadataOutput) else {
            showCameraUnavailable()
            return
        }
        captureSession.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        metadataOutput.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    private func showPermissionHint() {
        let label = UILabel(frame: view.bounds.insetBy(dx: 20, dy: 20))
        label.text = "Разрешите доступ к камере в настройках iOS."
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        view.addSubview(label)
    }

    private func showCameraUnavailable() {
        let label = UILabel(frame: view.bounds.insetBy(dx: 20, dy: 20))
        label.text = "Камера недоступна на этом устройстве."
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        view.addSubview(label)
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let metadata = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadata.type == .qr,
              let value = metadata.stringValue else { return }
        captureSession.stopRunning()
        onScan(value)
    }
}

#else

struct QRScannerSheet: View {
    let onScan: (String) -> Void
    var body: some View {
        Text("QR сканер недоступен на этой платформе")
            .padding()
    }
}

#endif

