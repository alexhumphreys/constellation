import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// QR-based pairing flow. Two tabs:
// - SHOW: render our own pairing code so another device can scan it.
//   QR carries our pid plus a one-shot token that authorizes whichever
//   peer scans it to be added to our trust list. Auto-dismisses as
//   soon as the scanner's MC claim arrives.
// - SCAN: open the rear camera, detect a peer's QR. On detect, add
//   the peer to our trust list and send an MC invitation back to
//   them carrying their token — that's how the other side knows to
//   trust us in return.
//
// Why scan-and-claim (vs. both-scan): one user scans and both ends
// up paired. Cost: the advertiser side accepts an invitation from a
// not-yet-trusted peer only when its context carries our current
// inviteToken — token forgery requires guessing a UUIDv4 (122 bits)
// and tokens expire on PairSheet close so a leaked QR can't be
// replayed. The whole sheet's lifetime is the threat window.
struct PairSheet: View {
    let peerSync: PeerSync
    let onClose: () -> Void

    @State private var tab: Tab = .show
    @State private var inviteToken: String? = nil
    @State private var lastScannedPid: String? = nil
    @State private var scanError: String? = nil
    @State private var pairCountAtAppear: Int = 0

    enum Tab: Hashable { case show, scan }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $tab) {
                    Text("Show").tag(Tab.show)
                    Text("Scan").tag(Tab.scan)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 12)

                switch tab {
                case .show:
                    showContent
                case .scan:
                    scanContent
                }
            }
            .background(Theme.Sky.bg2)
            .navigationTitle("Pair device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
            .alert("Couldn't pair", isPresented: Binding(
                get: { scanError != nil },
                set: { if !$0 { scanError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(scanError ?? "")
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            pairCountAtAppear = peerSync.pairCount
            if inviteToken == nil {
                inviteToken = peerSync.makeInviteToken()
            }
        }
        .onDisappear {
            peerSync.clearInviteToken()
        }
        // Show side: the moment a scanner's claim arrives, pairCount
        // bumps. Dismiss with a success haptic so the user knows it
        // worked without having to walk back to the other device.
        .onChange(of: peerSync.pairCount) { _, _ in
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onClose()
        }
    }

    // MARK: - Show tab

    private var showContent: some View {
        VStack(spacing: 24) {
            Spacer()
            if let image = Self.qrImage(for: payloadURL) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 280)
                    .padding(20)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                Text("Couldn't generate code.")
                    .foregroundStyle(.red)
            }
            VStack(spacing: 4) {
                Text(UIDevice.current.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Scan with the other device's Constellation app.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Scan tab

    private var scanContent: some View {
        ZStack(alignment: .bottom) {
            QRScannerView { payload in
                handleScanned(payload)
            }
            .ignoresSafeArea(edges: .bottom)
            VStack(spacing: 4) {
                Text("Point at the other device's pairing code")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                Text("It's on the SHOW tab over there.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(.bottom, 28)
        }
    }

    // MARK: - Payload

    private var payloadURL: URL {
        var c = URLComponents()
        c.scheme = "constellation"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "pid", value: PeerTrust.myPairId),
            URLQueryItem(name: "name", value: UIDevice.current.name),
            URLQueryItem(name: "token", value: inviteToken ?? ""),
            URLQueryItem(name: "v", value: "2"),
        ]
        return c.url ?? URL(string: "constellation://pair")!
    }

    private func handleScanned(_ payload: String) {
        guard let parsed = Self.parse(payload) else {
            scanError = "That doesn't look like a Constellation pairing code."
            return
        }
        // Debounce: AVFoundation fires the metadata callback every frame
        // the QR is in view. Once we've successfully claimed one, ignore
        // re-fires of the same pid until the user resets the sheet.
        if lastScannedPid == parsed.pid { return }
        // Reject our own QR — pairing with self is meaningless and a
        // common mis-tap when both phones are on the table.
        guard parsed.pid != PeerTrust.myPairId else {
            scanError = "That's this device's own code."
            return
        }
        guard !parsed.token.isEmpty else {
            scanError = "That code is missing its pairing token. Try regenerating it from the other device."
            return
        }
        lastScannedPid = parsed.pid
        peerSync.claimPairing(
            remotePid: parsed.pid,
            remoteName: parsed.name,
            remoteToken: parsed.token
        )
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onClose()
    }

    // MARK: - Static helpers

    fileprivate static func parse(_ payload: String) -> (pid: String, name: String, token: String)? {
        guard let url = URL(string: payload),
              url.scheme == "constellation",
              url.host == "pair",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let items = comps.queryItems ?? []
        guard let pid = items.first(where: { $0.name == "pid" })?.value,
              !pid.isEmpty
        else { return nil }
        let name = items.first(where: { $0.name == "name" })?.value ?? ""
        let token = items.first(where: { $0.name == "token" })?.value ?? ""
        return (pid, name, token)
    }

    private static func qrImage(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // CIFilter renders at native resolution (one module per pixel).
        // Scale up so the printed/photographed code stays readable.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - QR scanner

// AVCaptureSession wrapped as a UIViewControllerRepresentable so the
// preview layer sits in the SwiftUI layout. Why a representable (rather
// than rolling our own SwiftUI camera): AVCaptureMetadataOutput is the
// most reliable QR pipeline on iOS, and it requires an AVCaptureSession
// living in a UIView. ImageAnalysisInteraction / DataScannerViewController
// would also work but require iOS 16+/iPad-specific paths; the
// AVFoundation pipeline is the lowest-common-denominator that runs on
// every supported device.
private struct QRScannerView: UIViewControllerRepresentable {
    let onScanned: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let vc = QRScannerController()
        vc.onScanned = onScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
}

private final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasFired = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Tearing down on disappear (rather than dealloc) makes sure the
        // camera LED indicator clears the moment the sheet leaves the
        // screen, even before SwiftUI releases the controller.
        if session.isRunning {
            // Capture sessions must start/stop on a background queue —
            // doing so on the main thread blocks for ~100ms.
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.stopRunning()
            }
        }
    }

    private func configure() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            buildSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async { self?.buildSession(); self?.startSession() }
                } else {
                    DispatchQueue.main.async { self?.renderPermissionDenied() }
                }
            }
        case .denied, .restricted:
            renderPermissionDenied()
        @unknown default:
            renderPermissionDenied()
        }
    }

    private func buildSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            renderCameraUnavailable()
            return
        }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
        }
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    private func startSession() {
        guard !session.isRunning, !session.inputs.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    private func renderPermissionDenied() {
        renderOverlay(
            "Camera access denied. Enable it in Settings → Constellation → Camera "
            + "to scan pairing codes."
        )
    }

    private func renderCameraUnavailable() {
        renderOverlay("Couldn't open the camera on this device.")
    }

    private func renderOverlay(_ message: String) {
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textColor = .white
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        for obj in metadataObjects {
            guard let qr = obj as? AVMetadataMachineReadableCodeObject,
                  let payload = qr.stringValue
            else { continue }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.hasFired else { return }
                self.hasFired = true
                self.onScanned?(payload)
            }
            return
        }
    }
}
