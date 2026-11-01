import SwiftUI

@main struct HerdrWatchApp: App {
    @StateObject private var store: WatchStore
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HERDRWATCH_PREVIEW"] == "1" {
            let store = WatchStore(transport: PreviewTransport(core: ProcessInfo.processInfo.environment["HERDRWATCH_CORE_PREVIEW"] == "1"))
            store.host = Host(address: "sample.tailnet", port: 22, username: "developer")
            store.isPreview = true
            _store = StateObject(wrappedValue: store)
            return
        }
        #endif
        _store = StateObject(wrappedValue: WatchStore())
    }
    var body: some Scene {
        WindowGroup { Dashboard().environmentObject(store) }
        #if os(macOS)
        .defaultSize(width: 440, height: 820)
        #endif
    }
}
struct Dashboard: View {
    @EnvironmentObject var store: WatchStore
    @Environment(\.scenePhase) private var phase
    @State private var settings = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.isPreview { Text("Preview · sample data").font(.caption).foregroundStyle(.orange) }
                    Label(store.connected ? "Connected · read only" : "Disconnected", systemImage: store.connected ? "network" : "network.slash")
                        .foregroundStyle(store.connected ? .green : .secondary)
                    if !store.host.address.isEmpty { Text("\(store.host.username)@\(store.host.address):\(store.host.port)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                    if !store.runtimeLabel.isEmpty { Text(store.runtimeLabel).font(.caption).foregroundStyle(.secondary) }
                    if let observed = store.observed {
                        Text("\(store.stale ? "Stale · " : "")Observed \(observed.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(store.stale ? .orange : .secondary)
                    }
                    Button(store.connected ? "Refresh" : "Connect") { Task { await store.connectOrRefresh() } }.disabled(store.busy || store.host.address.isEmpty)
                    if store.busy { ProgressView("Reading host…") }
                }
                if let message = store.message {
                    Section("Connection notice") { Text(message).font(.callout).textSelection(.enabled) }
                }
                if let key = store.pendingKey {
                    Section("Verify host identity") {
                        Text("\(store.host.address):\(store.host.port)").font(.headline)
                        Text(key.split(separator: " ").first.map(String.init) ?? "SSH key")
                        Text(PinValidator.fingerprint(key)).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Compare this fingerprint with your host through an independent channel. No credentials have been sent.").font(.caption)
                        Button("Trust this host key and reconnect") { Task { await store.trust() } }.disabled(store.busy)
                        Button("Cancel", role: .cancel) { store.pendingKey = nil }
                    }
                }
                if !store.sessions.isEmpty {
                    Section("Sessions") {
                        ForEach(store.sessions) { session in
                            Button { Task { await store.select(session.id) } } label: {
                                HStack { Text(session.name); Spacer(); Text(session.state).foregroundStyle(.secondary); if store.selected == session.id { Image(systemName: "checkmark.circle.fill") } }
                            }.disabled(!session.running || session.connection_error != nil || store.busy)
                        }
                    }
                }
                if store.connected && !store.busy && store.snapshot == nil {
                    Section { Text(store.sessions.isEmpty ? "No sessions were discovered for this SSH account." : "No running session. Open Herdr on the host using the same account, then refresh.").foregroundStyle(.secondary) }
                }
                if let snapshot = store.snapshot {
                    Section("Overview") {
                        LabeledContent("Workspaces", value: "\(snapshot.workspaces.count)")
                        LabeledContent("Detected agents", value: "\(snapshot.agents.count)")
                        LabeledContent("Working", value: "\(snapshot.agents.filter { $0.agent_status == "working" }.count)")
                        LabeledContent("Needs attention", value: "\(snapshot.agents.filter { $0.agent_status == "blocked" }.count)")
                    }
                    ForEach(snapshot.workspaces) { workspace in
                        Section(workspace.label.isEmpty ? "Workspace" : workspace.label) {
                            Text("\(workspace.tab_count) tabs · \(workspace.pane_count) panes · \(statusLabel(workspace.agent_status))").font(.caption).foregroundStyle(.secondary)
                            ForEach(snapshot.tabs.filter { $0.workspace_id == workspace.id }) { tab in
                                Text("Tab \(tab.label ?? tab.id) · \(snapshot.panes.filter { $0.tab_id == tab.id }.count) panes").font(.caption.monospaced()).lineLimit(2)
                            }
                            ForEach(snapshot.agents.filter { $0.workspace_id == workspace.id }) { agent in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack { Text(agent.title).font(.headline); Spacer(); Text(statusLabel(agent.agent_status)).font(.caption) }
                                    if let cwd = agent.cwd { Text(cwd).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                    Text("Pane \(agent.pane_id)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }.textSelection(.enabled)
                            }
                        }
                    }
                    if snapshot.workspaces.isEmpty { ContentUnavailableView("No workspaces", systemImage: "rectangle.stack", description: Text("This running session has no workspaces.")) }
                } else if store.sessions.isEmpty && !store.busy && !store.connected {
                    Section {
                        ContentUnavailableView("Your agents, at a glance", systemImage: "binoculars", description: Text("Connect to an existing Herdr host over SSH to see sessions, workspaces and agent status."))
                        Button("Set up SSH host") { settings = true }
                    }
                }
                Section { Text("Foreground only. Refreshes every 15 seconds while connected. SSH access uses your host account; this app only reads Herdr state.").font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("HerdrWatch")
            .toolbar { Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Host settings").disabled(store.busy) }
            .refreshable { await store.refresh() }
            .onAppear {
                #if DEBUG
                if ProcessInfo.processInfo.environment["HERDRWATCH_SETTINGS"] != nil { settings = true }
                #endif
            }
            .sheet(isPresented: $settings) { HostSettings().environmentObject(store) }
            .task(id: phase) {
                if phase != .active { await store.suspend(); return }
                if !store.host.address.isEmpty && (store.observed != nil || store.isPreview) { await store.connect() }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    await store.refresh()
                }
            }
        }
        .overlay { if phase != .active { Color(.gray).ignoresSafeArea().overlay { Label("HerdrWatch", systemImage: "lock.fill").font(.title) } } }
    }
}
extension WatchStore {
    func connectOrRefresh() async { if connected { await refresh() } else { await connect() } }
}
struct HostSettings: View {
    @EnvironmentObject var store: WatchStore
    @Environment(\.dismiss) private var dismiss
    @State private var host = Host()
    @State private var port = "22"
    @State private var password = ""
    @State private var hasSavedPassword: Bool?
    var body: some View {
        NavigationStack {
            Form {
                Section("One SSH host") {
                    TextField("Hostname or Tailscale IP", text: $host.address)
                    TextField("SSH username", text: $host.username)
                    TextField("Port", text: $port)
                    Text("Use ordinary SSH on your private network. The Herdr desktop app (herdr-core 0.1.16) or upstream Herdr 0.9.5 must already be running on the host.").font(.caption).foregroundStyle(.secondary)
                }
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                Section("SSH password") {
                    SecureField("Enter SSH password", text: $password)
                        .frame(minHeight: 44)
                        #if os(iOS)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    if let hasSavedPassword {
                        Label(hasSavedPassword ? "Password saved for this host and username" : "No saved password for this host and username", systemImage: hasSavedPassword ? "checkmark.shield" : "key")
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Text("Saved-password status unavailable").font(.caption).foregroundStyle(.secondary) }
                    Text("Saved in device-only Keychain. Leave blank to keep the saved password for this host and username. The SSH server must allow password authentication.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Local data") {
                    Button("Clear in-memory snapshot") { store.clearCache() }
                    Button("Forget trusted host key", role: .destructive) { Task { await store.forgetTrust() } }
                    Button("Delete saved SSH password", role: .destructive) { Task { await store.deletePassword(); hasSavedPassword = try? Vault.contains(host.passwordAccount) } }
                }
                if let message = store.message { Section { Text(message).font(.caption) } }
            }
            .formStyle(.grouped)
            .navigationTitle("Host settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let number = Int(port) else { store.message = "Enter a numeric port."; return }
                        host.port = number
                        do {
                            try host.validate()
                            if !password.isEmpty {
                                try Vault.save(Data(password.utf8), account: host.passwordAccount)
                            }
                            password = ""
                            Task { await store.suspend(); store.clearCache(); store.pendingKey = nil; store.host = host; UserDefaults.standard.set(try? JSONEncoder().encode(host), forKey: "host"); dismiss() }
                        } catch { store.message = error.localizedDescription }
                    }
                }
            }
            .onAppear {
                host = store.host; port = String(host.port)
            }
            .task(id: host.passwordAccount) { hasSavedPassword = try? Vault.contains(host.passwordAccount) }
        }
        #if os(macOS)
        .frame(minWidth: 340, minHeight: 550)
        #endif
    }
}
