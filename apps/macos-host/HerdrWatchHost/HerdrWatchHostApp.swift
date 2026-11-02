import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import SwiftUI

@main struct HerdrWatchHostApp: App {
    @StateObject private var controller = HostController()
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("HerdrWatch Host", id: "manager") {
            HostManagerView().environmentObject(controller)
                .frame(width: 380, height: 640)
                .onAppear { appDelegate.install(controller: controller) }
        }
        .windowResizability(.contentSize)
    }
}

@MainActor final class HostAppDelegate: NSObject, NSApplicationDelegate {
    private weak var controller: HostController?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var stateObservation: AnyCancellable?

    func install(controller: HostController) {
        guard statusItem == nil else { return }
        self.controller = controller
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        self.statusItem = statusItem

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 250)
        popover.contentViewController = NSHostingController(
            rootView: HostMenuBarView().environmentObject(controller)
                .frame(width: 320, height: 250)
        )
        self.popover = popover
        updateStatusItem()
        stateObservation = controller.$state.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown { popover.performClose(sender) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    private func updateStatusItem() {
        guard let controller, let button = statusItem?.button else { return }
        let logo = NSImage(named: "HerdrMark")
        logo?.size = NSSize(width: 18, height: 18)
        logo?.isTemplate = false
        button.image = logo
        button.title = " Herdr"
        button.toolTip = "HerdrWatch Host · \(controller.state.title)"
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}

@MainActor final class HostController: ObservableObject {
    static let defaultEndpoint = "wss://herdrwatch-relay.herdrwatch-relay.workers.dev"

    private struct RelayStatus: Decodable {
        let configured: Bool
        let endpoint: String?
    }
    private struct PairingResponse: Decodable { let pairing_code: String }

    @Published private(set) var configured = false
    @Published private(set) var state: RelayDisplayState = .connecting
    @Published private(set) var activity: [String] = []
    @Published private(set) var lastConnectedAt: Date?
    @Published var pairingCode: String?
    @Published var errorMessage: String?
    @Published var endpoint = HostController.defaultEndpoint
    @Published private(set) var isLoadingPairingCode = false
    @Published private(set) var isCreatingPairing = false

    private var process: Process?
    private var outputPipe: Pipe?
    private var outputBuffer = Data()
    private let lastConnectedKey = "host.lastPhoneConnectedAt"

    init() {
        let savedConnectionTime = UserDefaults.standard.object(forKey: lastConnectedKey) as? Date
        lastConnectedAt = savedConnectionTime
        refreshConfiguration()
    }

    var isRunning: Bool { process?.isRunning == true }
    func refreshConfiguration() {
        Task {
            do {
                let data = try await HostCompanion.run(["relay", "status", "--json"])
                let result = try JSONDecoder().decode(RelayStatus.self, from: data)
                configured = result.configured
                if let savedEndpoint = result.endpoint { endpoint = savedEndpoint }
                if !isRunning { state = result.configured ? .stopped : .notPaired }
                errorMessage = nil
            } catch {
                if !isRunning { state = .failed(error.localizedDescription) }
                errorMessage = error.localizedDescription
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        guard configured else {
            errorMessage = "Create a pairing code before starting the relay."
            state = .notPaired
            return
        }
        do {
            let helper = try HostCompanion.url()
            let process = Process()
            let pipe = Pipe()
            process.executableURL = helper
            process.arguments = ["relay", "run"]
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in self?.processEnded(status: process.terminationStatus) }
            }
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                guard !bytes.isEmpty else { return }
                Task { @MainActor in self?.consume(bytes) }
            }
            try process.run()
            self.process = process
            self.outputPipe = pipe
            state = .connecting
            errorMessage = nil
            appendActivity("Starting the relay companion.")
        } catch {
            state = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        guard let process else { return }
        self.process = nil
        process.terminationHandler = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        process.terminate()
        state = .stopped
        appendActivity("Relay stopped.")
    }

    func createPairing() {
        guard !isCreatingPairing else { return }
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: value)?.scheme == "wss", URL(string: value)?.host != nil else {
            errorMessage = "Enter a relay address beginning with wss://."
            return
        }
        isCreatingPairing = true
        Task {
            defer { isCreatingPairing = false }
            do {
                let data = try await HostCompanion.run(["relay", "init", "--endpoint", value, "--json"])
                let result = try JSONDecoder().decode(PairingResponse.self, from: data)
                pairingCode = result.pairing_code
                configured = true
                state = .stopped
                errorMessage = nil
                appendActivity("Created a new iPhone pairing code.")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func revealPairingCode() {
        guard !isLoadingPairingCode else { return }
        isLoadingPairingCode = true
        Task {
            defer { isLoadingPairingCode = false }
            do {
                let data = try await HostCompanion.run(["relay", "pairing-code", "--json"])
                pairingCode = try JSONDecoder().decode(PairingResponse.self, from: data).pairing_code
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            consumeLine(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func consumeLine(_ line: String) {
        guard !line.isEmpty else { return }
        appendActivity(line)
        if line.contains("HerdrWatch connected") {
            state = .connected
            lastConnectedAt = Date()
            UserDefaults.standard.set(lastConnectedAt, forKey: lastConnectedKey)
        } else if line.contains("Relay connected; waiting") {
            state = .waiting
        } else if line.contains("HerdrWatch disconnected") {
            state = .waiting
        } else if line.contains("relay disconnected:") {
            state = .connecting
        } else if line.contains("HerdrWatch relay is connecting") {
            state = .connecting
        }
    }

    private func processEnded(status: Int32) {
        guard process != nil else { return }
        process = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        state = status == 0 ? .stopped : .failed("The relay companion exited with code \(status).")
        if status != 0 { errorMessage = "The relay companion exited with code \(status)." }
    }

    private func appendActivity(_ line: String) {
        activity.append(line)
        if activity.count > 40 { activity.removeFirst(activity.count - 40) }
    }
}

enum RelayDisplayState: Equatable {
    case notPaired, stopped, connecting, waiting, connected, failed(String)

    var title: String {
        switch self {
        case .notPaired: return "Setup needed"
        case .stopped: return "Relay stopped"
        case .connecting: return "Connecting to relay…"
        case .waiting: return "Relay ready"
        case .connected: return "iPhone connected"
        case .failed: return "Needs attention"
        }
    }

    var detail: String {
        switch self {
        case .notPaired: return "Create a pairing QR code for your iPhone."
        case .stopped: return "Start the relay when your iPhone is ready."
        case .connecting: return "Opening a secure connection to the relay."
        case .waiting: return "Online and waiting for HerdrWatch on your iPhone."
        case .connected: return "An end-to-end encrypted SSH session is active."
        case .failed(let message): return message
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var color: Color {
        switch self {
        case .connected: return .green
        case .waiting: return .blue
        case .connecting: return .orange
        case .failed: return .red
        case .notPaired, .stopped: return .secondary
        }
    }
}

private enum HostCompanion {
    static func url() throws -> URL {
        guard let resourceURL = Bundle.main.resourceURL else { throw HostAppError.companionMissing }
        let url = resourceURL.appendingPathComponent("herdrwatch-host", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw HostAppError.companionMissing }
        return url
    }

    static func run(_ arguments: [String]) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { try runSynchronously(arguments) }.value
    }

    private static func runSynchronously(_ arguments: [String]) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = try url()
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 15) == .success else {
            process.terminate()
            throw HostAppError.commandTimedOut
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostAppError.commandFailed(detail.isEmpty ? "The host companion command failed." : detail)
        }
        return data
    }
}

private enum HostAppError: LocalizedError {
    case companionMissing
    case commandFailed(String)
    case commandTimedOut
    var errorDescription: String? {
        switch self {
        case .companionMissing: return "The host companion is missing from this app. Rebuild HerdrWatch Host from Xcode."
        case .commandFailed(let message): return message
        case .commandTimedOut: return "The host companion did not respond within 15 seconds. Check macOS Keychain access and try again."
        }
    }
}

private struct HostManagerView: View {
    @EnvironmentObject private var controller: HostController
    @State private var confirmingReplace = false
    @State private var pairingPresentation: PairingPresentation?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                header
                Divider()
                statusCard
                if controller.configured { relayControls }
                else { pairingSetup }
                if let message = controller.errorMessage, !controller.state.isFailed {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                activityDisclosure
                Divider()
                HStack {
                    Button("Refresh status") { controller.refreshConfiguration() }
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }.buttonStyle(.borderless).font(.caption)
            }.padding(16)
        }
        .frame(width: 360, height: 600)
        .onChange(of: controller.pairingCode) { _, code in
            guard let code else { return }
            pairingPresentation = PairingPresentation(code: code)
            controller.pairingCode = nil
        }
        .sheet(item: $pairingPresentation) { presentation in
            PairingCodeSheet(code: presentation.code)
        }
        .confirmationDialog("Replace the iPhone pairing?", isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button("Replace pairing", role: .destructive) { controller.createPairing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The old pairing code will stop working. Scan the new code in HerdrWatch.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("HerdrMark")
                .resizable().scaledToFit().frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("HerdrWatch Host").font(.headline)
                Text("Secure Mac relay").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { controller.refreshConfiguration() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Refresh status")
        }
    }

    private var statusCard: some View {
        HStack(spacing: 11) {
            Circle().fill(controller.state.color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.state.title).font(.subheadline.weight(.semibold))
                Text(controller.state.detail)
                    .font(.caption).foregroundStyle(.secondary)
                if controller.state != .connected, let lastConnected = controller.lastConnectedAt {
                    Text("Last connected \(lastConnected.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }.padding(13).background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var relayControls: some View {
        VStack(spacing: 10) {
            Button {
                if controller.isRunning { controller.stop() } else { controller.start() }
            } label: {
                Label(controller.isRunning ? "Stop relay" : "Start relay", systemImage: controller.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }.buttonStyle(.borderedProminent).tint(controller.isRunning ? .secondary : .accentColor)
            HStack {
                Button {
                    controller.revealPairingCode()
                } label: {
                    if controller.isLoadingPairingCode {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading QR…") }
                    } else {
                        Text("Show pairing QR")
                    }
                }.disabled(controller.isLoadingPairingCode)
                Spacer()
                Button("Replace pairing…") { confirmingReplace = true }.foregroundStyle(.secondary)
            }.buttonStyle(.borderless).font(.caption)
        }
    }

    private var pairingSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your iPhone").font(.subheadline.weight(.semibold))
            setupStep(1, title: "Enable Remote Login", detail: "System Settings → Sharing → Remote Login.")
            setupStep(2, title: "Open Herdr for this account", detail: "Keep Herdr available to the same macOS user.")
            setupStep(3, title: "Pair, then start the relay", detail: "Scan the QR code in HerdrWatch. Start the relay after pairing.")
            TextField("Relay address", text: $controller.endpoint)
                .textFieldStyle(.roundedBorder).font(.caption.monospaced())
            Button {
                controller.createPairing()
            } label: {
                if controller.isCreatingPairing {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Creating secure pairing…") }
                } else {
                    Text("Create pairing QR")
                }
            }
            .disabled(controller.isCreatingPairing)
            .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
        }
    }

    private func setupStep(_ number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(width: 22, height: 22)
                .background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.medium))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var activityDisclosure: some View {
        DisclosureGroup("Recent activity") {
            VStack(alignment: .leading, spacing: 5) {
                if controller.activity.isEmpty {
                    Text("No relay activity yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(controller.activity.suffix(8).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(.top, 8)
        }.font(.caption.weight(.medium))
    }

}

private struct HostMenuBarView: View {
    @EnvironmentObject private var controller: HostController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image("HerdrMark").resizable().scaledToFit().frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("HerdrWatch Host").font(.headline)
                Spacer()
                Button("Manage") { openWindow(id: "manager") }
                    .buttonStyle(.borderless).font(.caption)
            }

            Divider()

            HStack(alignment: .top, spacing: 9) {
                Circle().fill(controller.state.color).frame(width: 9, height: 9).padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.state.title).font(.subheadline.weight(.semibold))
                    Text(controller.state.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if controller.configured {
                Button {
                    if controller.isRunning { controller.stop() } else { controller.start() }
                } label: {
                    Label(controller.isRunning ? "Stop relay" : "Start relay",
                          systemImage: controller.isRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.isRunning ? .secondary : .accentColor)
            } else {
                Button("Set up this Mac…") { openWindow(id: "manager") }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .frame(width: 292)
    }
}

private struct PairingPresentation: Identifiable {
    let id = UUID()
    let code: String
}

private struct PairingCodeSheet: View {
    let code: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 25, weight: .medium)).foregroundStyle(Color.accentColor)
            Text("Scan this QR code")
                .font(.title2.weight(.semibold))
            Text("On iPhone, open HerdrWatch → Connection → Encrypted relay and scan this code.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let image = Self.qrImage(code) {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 230, height: 230)
                    .background(.white).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Button("Copy pairing code") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }.buttonStyle(.bordered)
            Label("Treat this code like a password. It grants access to this host.", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Done") { NSApplication.shared.keyWindow?.close() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func qrImage(_ code: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 7, y: 7)) else { return nil }
        let representation = NSCIImageRep(ciImage: image)
        let result = NSImage(size: representation.size)
        result.addRepresentation(representation)
        return result
    }
}
