import AVFoundation
import SwiftUI

/// Pairing: scan the code in Studio One's Settings › iPhone Remote, or paste
/// the remote's link.
struct PairView: View {
    @Environment(RemoteStore.self) private var store
    @State private var scanning = false
    @State private var link = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "music.mic.circle.fill")
                    .font(.system(size: 84))
                    .foregroundStyle(.white, Theme.pink)
                    .padding(.top, 50)
                Text("Studio One Remote").font(.largeTitle.weight(.bold))
                Text("On the Mac, open Studio One › Settings › iPhone Remote, turn it on, and scan the code it shows.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button {
                    scanning = true
                } label: {
                    Label("Scan the Code", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(working)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Or paste the remote's link").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    HStack {
                        TextField("http://…/r/…", text: $link)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .onSubmit { Task { await pair(link) } }
                        Button("Pair") { Task { await pair(link) } }
                            .disabled(link.isEmpty || working)
                    }
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                }

                if working { ProgressView("Reaching Studio One…") }
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 26)
        }
        .background(
            LinearGradient(colors: [Theme.violet.opacity(0.55), Theme.ink], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        )
        .sheet(isPresented: $scanning) {
            CodeScanner { text in
                scanning = false
                Task { await pair(text) }
            }
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                Text("Point at the code on the Mac")
                    .font(.headline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 24)
            }
        }
    }

    private func pair(_ text: String) async {
        guard let candidate = Pairing(scanned: text) else {
            problem = "That isn't Studio One's remote code. It looks like http://192.168.1.20:8710/r/… "
            return
        }
        working = true
        problem = nil
        if !(await store.pair(with: candidate)) {
            problem = "Couldn't reach Studio One at \(candidate.host). Is this phone on the Mac's Wi-Fi, and is Local Network on for S1 Remote in Settings › Privacy & Security?"
        }
        working = false
    }
}

/// The camera, reading QR codes; the first one found is handed over.
struct CodeScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.found = found
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var found: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var reported = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
                let label = UILabel()
                label.text = "No camera — paste the link instead."
                label.textColor = .white
                label.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(label)
                NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                             label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.layer.bounds
            view.layer.addSublayer(preview)
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.compactMap { $0 as? AVCaptureVideoPreviewLayer }.forEach { $0.frame = view.layer.bounds }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !reported, let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first?.stringValue else { return }
            reported = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            found?(code)
        }
    }
}

/// The paired Mac, the Lock Screen's Live Activity, and unpairing.
struct SettingsView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ActivityController.enabledKey) private var liveActivity = true
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
                    LabeledContent("Name", value: store.pairing?.name ?? "Studio One")
                    LabeledContent("Address", value: store.pairing.map { "\($0.host):\($0.port)" } ?? "—")
                    Button(store.finding ? "Looking…" : "Find It Again on the Wi-Fi") { Task { await store.findAgain() } }
                        .disabled(store.finding)
                }
                Section {
                    Toggle("Song on the Lock Screen", isOn: $liveActivity)
                        .onChange(of: liveActivity) { _, on in
                            if on { Task { await store.refresh() } } else { store.activity.end() }
                        }
                } footer: {
                    Text("A Live Activity with the song, the singer and who's next, with play and skip buttons. It's as fresh as this app's last look: open the app now and then on a long night.")
                }
                Section {
                    Button("Unpair", role: .destructive) { confirmUnpair = true }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Unpair from this Mac?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    dismiss()
                    store.unpair()
                }
            }
        }
    }
}
