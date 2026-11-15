import AVFoundation
import SwiftUI
import UIKit

/// Camera sheet that imports the first proxy QR code it sees.
struct QRScannerSheet: View {
    @EnvironmentObject private var nodes: NodeStore
    @Environment(\.dismiss) private var dismiss
    @State private var handled = false

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerView { code in
                    guard !handled else { return }
                    handled = true
                    let result = nodes.importText(code)
                    nodes.toast = result.summary
                    dismiss()
                }
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    Text("Point the camera at a proxy QR code")
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle("Scan QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {
        controller.onCode = onCode
    }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.slproxy.app.qr-scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if granted {
                self.sessionQueue.async { self.configureSession() }
            } else {
                DispatchQueue.main.async {
                    self.statusLabel.text = "Camera access is required to scan QR codes. Enable it in Settings."
                }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            DispatchQueue.main.async { self.statusLabel.text = "No camera available on this device." }
            return
        }
        session.beginConfiguration()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        DispatchQueue.main.async {
            let layer = AVCaptureVideoPreviewLayer(session: self.session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = self.view.bounds
            self.view.layer.insertSublayer(layer, at: 0)
            self.previewLayer = layer
            self.statusLabel.isHidden = true
        }
        session.startRunning()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !delivered,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue, !value.isEmpty else { return }
        delivered = true
        onCode?(value)
    }
}
