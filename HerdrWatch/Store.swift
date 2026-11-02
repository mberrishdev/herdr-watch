import SwiftUI

@MainActor final class WatchStore: ObservableObject {
    var isPreview = false
    @Published var runtimeLabel = ""
    private var coreProfile = false
    private var coreIdentity: String?
    private var coreCanRead = false
    @Published var host: Host
    @Published var sessions: [Session] = []
    @Published var selected: String?
    @Published var snapshot: Snapshot?
    @Published var observed: Date?
    @Published var connected = false
    @Published var busy = false
    @Published var stale = true
    @Published var message: String?
    @Published var pendingKey: String?
    private var generation = UUID()
    private var refreshInProgress = false
    private let transport: SSHTransport
    init(transport: SSHTransport? = nil) {
        self.transport = transport ?? CitadelTransport()
        host = (UserDefaults.standard.data(forKey: "host").flatMap { try? JSONDecoder().decode(Host.self, from: $0) }) ?? Host()
    }
    func connect() async {
        guard !busy, !refreshInProgress else { return }
        generation = UUID()
        let attempt = generation
        busy = true; message = nil; pendingKey = nil; stale = true
        defer { busy = false }
        await transport.disconnect(); connected = false
        var stage = ConnectionStage.ssh
        do {
            try host.validate()
            let pin = try isPreview ? nil : Vault.read("host:\(host.identity)").flatMap { String(data: $0, encoding: .utf8) }
            try await transport.connect(host: host, trustedKey: pin)
            guard generation == attempt else { await transport.disconnect(); return }
            if !isPreview { UserDefaults.standard.set(try JSONEncoder().encode(host), forKey: "host") }
            connected = true
            stage = .bridge
            let runtime = String(decoding: try await transport.execute(.runtime), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if runtime == "hc 0.1.16" {
                coreProfile = true
                runtimeLabel = "Herdr desktop · herdr-core 0.1.16"
            } else if runtime == "herdr-api-bridge-v1" {
                coreProfile = false
                coreIdentity = nil
                runtimeLabel = "Herdr CLI · upstream 0.9.5 / protocol 22"
            } else { throw WatchError.message("Unsupported Herdr runtime. Supported profiles: herdr-core 0.1.16 or upstream Herdr 0.9.5.") }
            stage = .snapshot
            try await discover()
        } catch let error as WatchError {
            if case .trust(let key) = error { pendingKey = key }
            message = error.localizedDescription
            await transport.disconnect(); connected = false
        } catch {
            message = ConnectionFailure.message(error, stage: stage)
            await transport.disconnect(); connected = false
        }
    }
    private func discover() async throws {
        let attempt = generation
        if coreProfile {
            let hello = try CoreAdapter.verify(await transport.execute(.coreHello))
            let terminals = try await transport.execute(.coreTerminals)
            let document = try await transport.execute(.coreLayout)
            let value = try CoreAdapter.snapshot(terminals: terminals, document: document)
            guard attempt == generation else { throw CancellationError() }
            coreIdentity = hello.core.id; coreCanRead = hello.methods.contains("terminal.read")
            let defaultSession = Session(name: "default", default: true, running: true, connection_error: nil)
            if sessions != [defaultSession] { sessions = [defaultSession] }
            if selected != "default" { selected = "default" }
            if snapshot != value { snapshot = value }
            observed = Date()
            if stale { stale = false }
            return
        }
        struct List: Decodable { let sessions: [Session] }
        let items = try JSONDecoder().decode(List.self, from: await transport.execute(.sessions)).sessions
        guard attempt == generation else { throw CancellationError() }
        if sessions != items { sessions = items }
        if !items.contains(where: { $0.id == selected && $0.running && $0.connection_error == nil }) {
            let next = items.first(where: { $0.running && $0.connection_error == nil })?.id
            if selected != next { selected = next }
            if snapshot != nil { snapshot = nil }
            if observed != nil { observed = nil }
        }
        try await fetchSnapshot()
    }
    private func fetchSnapshot() async throws {
        let attempt = generation
        guard let session = sessions.first(where: { $0.id == selected && $0.running && $0.connection_error == nil }) else {
            if snapshot != nil { snapshot = nil }
            if observed != nil { observed = nil }
            return
        }
        let value = try Wire.snapshot(await transport.execute(.snapshot(session)))
        guard attempt == generation else { throw CancellationError() }
        if snapshot != value { snapshot = value }
        observed = Date()
        if stale { stale = false }
    }
    var outputScope: OutputScope { OutputScope(host: host, session: selected ?? "default", coreIdentity: coreIdentity) }
    func readOutput(for target: OutputTarget) async throws -> TerminalOutput? {
        guard connected, !busy, !refreshInProgress else { return nil }
        guard target.scope == outputScope else { throw WatchError.message("The host or session changed. Go back and open the current agent.") }
        let attempt = generation
        busy = true
        defer { busy = false }
        do {
            try await discover()
            guard attempt == generation, connected else { throw CancellationError() }
            guard target.scope == outputScope, snapshot?.agents.contains(where: {
                $0.id == target.agent.id && $0.pane_id == target.agent.pane_id && $0.workspace_id == target.agent.workspace_id
            }) == true else { throw WatchError.message("This agent is no longer in the current snapshot. Go back and refresh the dashboard.") }
            let operation: ReadOperation
            if coreProfile {
                guard coreCanRead else { throw WatchError.message("This Herdr core does not offer terminal screen reads.") }
                operation = .coreOutput(target.agent.terminal_id)
            } else {
                guard let session = sessions.first(where: { $0.id == selected }) else { throw WatchError.message("Session is unavailable.") }
                operation = .agentOutput(session, target.agent.terminal_id)
            }
            let data = try await transport.execute(operation)
            guard attempt == generation, target.scope == outputScope, connected else { throw CancellationError() }
            return try TerminalOutput.decode(data, core: coreProfile, agent: target.agent)
        } catch let error as WatchError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            stale = true; connected = false
            await transport.disconnect()
            throw WatchError.message(ConnectionFailure.message(error, stage: .output))
        }
    }
    func refresh(silent: Bool = false) async {
        guard connected, !busy, !refreshInProgress else { return }
        refreshInProgress = true
        if !silent { busy = true; message = nil }
        defer {
            refreshInProgress = false
            if !silent { busy = false }
        }
        do { try await discover() }
        catch {
            if !stale { stale = true }
            message = (error as? WatchError)?.localizedDescription ?? "Refresh failed. Showing the last observed state. Reconnect to retry."
            await transport.disconnect()
            connected = false
        }
    }
    func select(_ id: String) async {
        guard !busy else { return }
        selected = id; snapshot = nil; observed = nil; stale = true
        await refresh()
    }
    func trust() async {
        guard let pendingKey else { return }
        do { try Vault.save(Data(pendingKey.utf8), account: "host:\(host.identity)"); self.pendingKey = nil; await connect() }
        catch { message = error.localizedDescription }
    }
    func suspend() async { generation = UUID(); stale = true; connected = false; await transport.disconnect() }
    func clearCache() { generation = UUID(); snapshot = nil; observed = nil; sessions = []; selected = nil; stale = true }
    func forgetTrust() async {
        await suspend()
        do { try Vault.delete("host:\(host.identity)"); clearCache(); message = "Trusted host key removed. Verify the next connection independently." }
        catch { message = error.localizedDescription }
    }
    func deletePassword() async {
        await suspend()
        do { try Vault.delete(host.passwordAccount); message = "Saved SSH password deleted." }
        catch { message = error.localizedDescription }
    }
}
