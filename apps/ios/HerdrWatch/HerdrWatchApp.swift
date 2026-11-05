import SwiftUI

@main struct HerdrWatchApp: App {
    @StateObject private var store: WatchStore
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HERDRWATCH_PREVIEW"] == "1" {
            let sampleHost: Host
            if ProcessInfo.processInfo.environment["HERDRWATCH_RELAY_PREVIEW"] == "1" {
                sampleHost = Host(username: "developer", relayEndpoint: "wss://relay.example.workers.dev", relayHostID: "preview-relay-host-identifier")
            } else {
                sampleHost = Host(address: "sample.tailnet", port: 22, username: "developer")
            }
            let previewDefaults = UserDefaults(suiteName: "dev.herdr.HerdrWatch.preview")!
            previewDefaults.removePersistentDomain(forName: "dev.herdr.HerdrWatch.preview")
            let sample = HerdrConnection(name: "Sample Mac", host: sampleHost)
            let other = HerdrConnection(name: "Work Mac", host: Host(username: "developer", relayEndpoint: "wss://relay.example.workers.dev", relayHostID: "work-preview-host-identifier"))
            previewDefaults.set(try? JSONEncoder().encode(ConnectionLibrary(connections: [sample, other], activeID: sample.id)), forKey: "connections")
            let store = WatchStore(transport: PreviewTransport(
                core: ProcessInfo.processInfo.environment["HERDRWATCH_CORE_PREVIEW"] == "1",
                prompts: ProcessInfo.processInfo.environment["HERDRWATCH_PROMPT_PREVIEW"] == "1"
            ), defaults: previewDefaults)
            store.isPreview = true
            if ProcessInfo.processInfo.environment["HERDRWATCH_CONNECTING_PREVIEW"] == "1" {
                store.busy = true
                store.connectionProgress = "Waiting for the Mac companion…"
            }
            _store = StateObject(wrappedValue: store)
            return
        }
        #endif
        _store = StateObject(wrappedValue: WatchStore())
    }
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.environment["HERDRWATCH_SETTINGS_PREVIEW"] == "1" {
                ConnectionSettings().environmentObject(store)
            } else if ProcessInfo.processInfo.environment["HERDRWATCH_OUTPUT_PREVIEW"] == "1" {
                OutputPreviewRoot().environmentObject(store)
            } else { Dashboard().environmentObject(store) }
            #else
            Dashboard().environmentObject(store)
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 440, height: 820)
        #endif
    }
}
private struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.46), .white.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                }
        }
    }
}
extension View {
    func glassPanel(cornerRadius: CGFloat) -> some View { modifier(GlassPanelModifier(cornerRadius: cornerRadius)) }
    func contentPanel(cornerRadius: CGFloat) -> some View {
        background(.background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.primary.opacity(0.05), lineWidth: 1) }
    }
}
private struct GlassBackdrop: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle().fill(.background)
            Circle().fill(Color.accentColor.opacity(0.09)).frame(width: 260, height: 260).blur(radius: 70).offset(x: 100, y: -90)
            Circle().fill(Color.cyan.opacity(0.06)).frame(width: 220, height: 220).blur(radius: 75).offset(x: -180, y: 320)
        }.ignoresSafeArea()
    }
}
private struct MetricTile: View {
    let value: String
    let label: String
    let symbol: String
    var tint: Color = .accentColor
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title3.weight(.bold).monospacedDigit())
                Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 11).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentPanel(cornerRadius: 17)
    }
}
private struct PrimaryGlassButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
        } else {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
    }
}

struct Dashboard: View {
    @EnvironmentObject var store: WatchStore
    @Environment(\.scenePhase) private var phase
    @State private var settings = false
    // nil means the overview is showing every workspace.
    @State private var selectedWorkspaceID: String?
    private var workspaces: [Workspace] { store.snapshot?.workspaces ?? [] }
    private var visibleWorkspace: Workspace? {
        workspaces.first(where: { $0.id == selectedWorkspaceID })
    }
    private var visibleAgents: [Agent] {
        guard let selectedWorkspaceID else { return store.snapshot?.agents ?? [] }
        return (store.snapshot?.agents ?? []).filter { $0.workspace_id == selectedWorkspaceID }
    }
    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackdrop()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if store.host.isConfigured { connectionCard }
                        if let message = store.message { noticeCard(message) }
                        if let key = store.pendingKey { trustCard(key) }
                        if !store.sessions.isEmpty { sessionPicker }
                        if let snapshot = store.snapshot {
                            overview(snapshot)
                            workspacePicker
                            if visibleAgents.isEmpty {
                                if let workspace = visibleWorkspace { emptyAgents(workspace: workspace) }
                                else {
                                    ContentUnavailableView("No agents detected", systemImage: "terminal", description: Text("The current Herdr snapshot has no recognized agents."))
                                        .contentPanel(cornerRadius: 24)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack {
                                        Text(selectedWorkspaceID == nil ? "AGENTS · ALL WORKSPACES" : "AGENTS · \(visibleWorkspace?.label ?? "WORKSPACE")")
                                            .font(.caption.weight(.semibold)).tracking(1.0).foregroundStyle(.secondary).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text("\(visibleAgents.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }.padding(.horizontal, 4)
                                    ForEach(visibleAgents) { agent in
                                        let label = workspaces.first(where: { $0.id == agent.workspace_id })?.label
                                        AgentSessionRow(agent: agent, workspaceLabel: label)
                                    }
                                }
                            }
                        } else if store.connected && !store.busy { emptySnapshot }
                        else if store.sessions.isEmpty && !store.busy && !store.connected && !store.host.isConfigured { firstUseCard }
                        if store.host.isConfigured {
                            Text("Updates every 15 seconds while you’re here")
                                .font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.top, 2)
                        }
                    }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 28)
                }
            }
            .navigationTitle("HerdrWatch")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 7) {
                        Image("HerdrMark").resizable().scaledToFit().frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("HerdrWatch").font(.headline)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { settingsButton }
                #else
                ToolbarItem(placement: .automatic) { settingsButton }
                #endif
            }
            .refreshable { await store.refresh() }
            .onAppear {
                #if DEBUG
                if ProcessInfo.processInfo.environment["HERDRWATCH_SETTINGS"] != nil { settings = true }
                #endif
            }
            .sheet(isPresented: $settings) { ConnectionSettings().environmentObject(store) }
            .onChange(of: store.snapshot?.workspaces.map(\.id)) { _, ids in
                if let selectedWorkspaceID, ids?.contains(selectedWorkspaceID) != true { self.selectedWorkspaceID = nil }
            }
            .task(id: phase) {
                if phase != .active { await store.suspend(); return }
                if store.host.isConfigured && (store.observed != nil || store.isPreview) { await store.connect() }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    await store.refresh(silent: true)
                }
            }
        }
        .overlay { if phase != .active { Color(.gray).ignoresSafeArea().overlay { Label("HerdrWatch", systemImage: "lock.fill").font(.title) } } }
    }
    private var settingsButton: some View {
        Button { settings = true } label: { Image(systemName: "laptopcomputer.and.iphone") }
            .accessibilityLabel("Computers").disabled(store.busy)
    }
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Image(systemName: store.connected ? "point.3.connected.trianglepath.dotted" : "network.slash")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(store.connected ? .green : .secondary)
                    .frame(width: 44, height: 44).background((store.connected ? Color.green : Color.secondary).opacity(0.13), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.activeConnection?.title ?? (store.connected ? "Connected" : "Your Herdr host")).font(.headline)
                    Text(store.host.usesRelay ? (store.host.relayProtocol == 2 ? "Windows companion · Encrypted relay" : "\(store.host.username) · Encrypted SSH relay") : store.host.address.isEmpty ? "Add a connection to get started" : "\(store.host.username)@\(store.host.address) · SSH \(store.host.port)")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if store.isPreview { Text("SAMPLE").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.orange) }
            }
            if !store.connections.isEmpty {
                Menu {
                    ForEach(store.connections) { connection in
                        Button {
                            Task { await store.activateConnection(connection.id) }
                        } label: {
                            Label(connection.title, systemImage: connection.id == store.library.activeID ? "checkmark.circle.fill" : "network")
                        }
                    }
                    Divider()
                    Button("Add computer", systemImage: "plus") { settings = true }
                } label: {
                    Label("Switch computer", systemImage: "arrow.left.arrow.right").font(.subheadline.weight(.medium))
                }.disabled(store.busy || store.refreshInProgress)
            }
            if store.connected, let observed = store.observed {
                HStack(spacing: 6) {
                    Circle().fill(store.stale ? .orange : .green).frame(width: 6, height: 6)
                    Text("\(store.stale ? "Last updated" : "Live") · \(observed.formatted(date: .omitted, time: .shortened))")
                    Spacer()
                    Text(store.runtimeLabel.replacingOccurrences(of: "Herdr desktop · ", with: "").replacingOccurrences(of: "Herdr CLI · ", with: ""))
                }.font(.caption).foregroundStyle(.secondary)
            }
            if store.busy {
                ProgressView(store.connectionProgress.isEmpty ? (store.connected ? "Refreshing workspace…" : "Connecting securely…") : store.connectionProgress)
                    .font(.subheadline).tint(.accentColor)
            }
            else {
                Button {
                    if !store.host.isConfigured { settings = true }
                    else { Task { await store.connectOrRefresh() } }
                } label: {
                    Label(store.connected ? "Refresh workspace" : store.host.isConfigured ? "Connect securely" : "Set up connection",
                          systemImage: store.connected ? "arrow.clockwise" : "lock.shield")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.modifier(PrimaryGlassButton()).controlSize(.large)
            }
        }.padding(17).glassPanel(cornerRadius: 26)
    }
    private func overview(_ snapshot: Snapshot) -> some View {
        HStack(spacing: 9) {
            MetricTile(value: "\(snapshot.agents.count)", label: "Agents", symbol: "terminal")
            MetricTile(value: "\(snapshot.agents.filter { $0.agent_status == "working" }.count)", label: "Working", symbol: "bolt.fill", tint: .blue)
            MetricTile(value: "\(snapshot.agents.filter { $0.agent_status == "blocked" || $0.agent_status == "error" }.count)", label: "Attention", symbol: "exclamationmark.circle.fill", tint: .orange)
        }
    }
    private var workspacePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                workspaceChip(id: nil, title: "All workspaces", count: store.snapshot?.agents.count ?? 0)
                ForEach(workspaces) { workspace in
                    workspaceChip(id: workspace.id, title: workspace.label.isEmpty ? "Workspace" : workspace.label,
                                  count: (store.snapshot?.agents ?? []).filter { $0.workspace_id == workspace.id }.count)
                }
            }.padding(.vertical, 2)
        }.contentMargins(.horizontal, 1)
    }
    private func workspaceChip(id: String?, title: String, count: Int) -> some View {
        let selected = selectedWorkspaceID == id
        return Button { withAnimation(.snappy(duration: 0.22)) { selectedWorkspaceID = id } } label: {
            HStack(spacing: 7) {
                if id == nil { Image(systemName: "square.grid.2x2.fill").font(.caption.weight(.semibold)) }
                else { Image(systemName: "folder").font(.caption.weight(.semibold)) }
                Text(title).lineLimit(1)
                Text("\(count)").font(.caption2.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(selected ? Color.white.opacity(0.2) : Color.primary.opacity(0.07), in: Capsule())
            }.font(.subheadline.weight(selected ? .semibold : .medium)).padding(.horizontal, 13).padding(.vertical, 10)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var sessionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.on.rectangle.angled").foregroundStyle(.secondary).padding(.leading, 4)
                ForEach(store.sessions) { session in
                    Button {
                        guard store.selected != session.id else { return }
                        Task { await store.select(session.id) }
                    } label: {
                        HStack(spacing: 5) {
                            Text(session.name).lineLimit(1)
                            if store.selected == session.id { Image(systemName: "checkmark.circle.fill") }
                        }.font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 7)
                            .background(store.selected == session.id ? Color.accentColor.opacity(0.16) : Color.clear, in: Capsule())
                    }.buttonStyle(.plain).disabled(!session.running || session.connection_error != nil || store.busy)
                }
            }.padding(9)
        }.contentPanel(cornerRadius: 18)
    }
    private func noticeCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill").font(.subheadline)
            .foregroundStyle(.orange).padding(14).frame(maxWidth: .infinity, alignment: .leading).contentPanel(cornerRadius: 18)
    }
    private func trustCard(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Verify this host", systemImage: "shield.lefthalf.filled").font(.headline)
            Text("Compare this fingerprint with your host through an independent channel. Your password has not been sent.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(PinValidator.fingerprint(key)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .padding(11).frame(maxWidth: .infinity, alignment: .leading).background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            Button("Trust fingerprint and connect") { Task { await store.trust() } }.buttonStyle(.borderedProminent).disabled(store.busy)
            Button("Not now", role: .cancel) { store.pendingKey = nil }.buttonStyle(.borderless)
        }.padding(18).contentPanel(cornerRadius: 24)
    }
    private var emptySnapshot: some View {
        ContentUnavailableView(store.sessions.isEmpty ? "No Herdr sessions found" : "No running session", systemImage: "rectangle.stack",
                               description: Text(store.sessions.isEmpty ? "Check that Herdr is running for this SSH account, then refresh." : "Open Herdr on the host with this account, then refresh."))
            .padding(16).contentPanel(cornerRadius: 24)
    }
    private func emptyAgents(workspace: Workspace) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("No agents in \(workspace.label.isEmpty ? "this workspace" : workspace.label)").font(.subheadline.weight(.medium))
                Text("Choose All workspaces or another workspace above.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).contentPanel(cornerRadius: 20)
    }
    private var firstUseCard: some View {
        VStack(spacing: 12) {
            Image("HerdrMark").resizable().scaledToFit().frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Text("Your agents. Anywhere.").font(.largeTitle.bold())
            Text("Connect your computer to follow your agents, read their work, and send the next instruction.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Add your computer", systemImage: "plus") { settings = true }.modifier(PrimaryGlassButton()).controlSize(.large)
        }.frame(maxWidth: .infinity).padding(22).contentPanel(cornerRadius: 26)
    }
}
extension WatchStore {
    func connectOrRefresh() async { if connected { await refresh() } else { await connect() } }
}
struct ConnectionSettings: View {
    @EnvironmentObject var store: WatchStore
    @Environment(\.dismiss) private var dismiss
    @State private var removing: HerdrConnection?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "laptopcomputer.and.iphone")
                            .font(.system(size: 48, weight: .light)).foregroundStyle(Color.accentColor)
                        Text("Your computers, with you.").font(.title2.bold())
                        Text("Pair once. Switch computers whenever you need.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 22)
                }.listRowBackground(Color.clear)
                Section {
                    ForEach(store.connections) { connection in
                        HStack(spacing: 12) {
                            Button {
                                Task {
                                    if connection.id == store.library.activeID { await store.connectOrRefresh() }
                                    else { await store.activateConnection(connection.id) }
                                    dismiss()
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: connection.host.relayProtocol == 2 ? "pc" : "laptopcomputer")
                                        .font(.title2).foregroundStyle(Color.accentColor).frame(width: 38)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(connection.title).font(.headline).foregroundStyle(.primary)
                                        Text(connection.id == store.library.activeID
                                             ? (store.connected ? "Connected" : "Selected · tap to connect")
                                             : "Tap to connect")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if connection.id == store.library.activeID {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                    }
                                }.padding(.vertical, 8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            NavigationLink { HostSettings(connection: connection, onSaved: { dismiss() }).environmentObject(store) } label: {
                                Image(systemName: "info.circle").accessibilityLabel("Edit \(connection.title)")
                            }.fixedSize()
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { removing = connection }
                        }
                        .contextMenu {
                            Button("Remove computer", role: .destructive) { removing = connection }
                        }
                    }
                    NavigationLink { HostSettings(onSaved: { dismiss() }).environmentObject(store) } label: {
                        Label("Add computer", systemImage: "plus.circle.fill").padding(.vertical, 8)
                    }
                } header: { Text("My computers") } footer: {
                    Text("Monitor one computer at a time. Your other pairings stay saved on this iPhone.")
                }
            }
            .disabled(store.busy || store.refreshInProgress)
            .navigationTitle("Computers")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Remove \(removing?.title ?? "computer")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove computer", role: .destructive) {
                    if let removing { Task { await store.removeConnection(removing.id) } }
                    removing = nil
                }
            } message: { Text("This removes the saved computer. Its credentials remain in this device’s Keychain.") }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 550)
        #endif
    }
}

struct HostSettings: View {
    var connection: HerdrConnection? = nil
    var onSaved: (() -> Void)? = nil
    @EnvironmentObject var store: WatchStore
    @Environment(\.dismiss) private var dismiss
    @State private var connectionName = ""
    @State private var saving = false
    @State private var host = Host()
    @State private var port = "22"
    @State private var password = ""
    @State private var pairingCode = ""
    @State private var scannerPresented = false
    @State private var hasSavedPassword: Bool?
    @State private var directSSH = false
    @State private var showCode = false
    @State private var errorMessage: String?
    private var pairing: RelayPairing? { try? RelayPairing.decode(pairingCode) }
    private var paired: Bool { pairing != nil || (host.usesRelay && pairingCode.isEmpty) }
    private var usingDirectRelay: Bool { pairing?.version == 2 || (pairingCode.isEmpty && host.relayProtocol == 2) }
    private var ready: Bool {
        (directSSH ? !host.address.trimmingCharacters(in: .whitespaces).isEmpty : paired)
        && (usingDirectRelay || !host.username.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: paired ? "checkmark.shield" : "laptopcomputer.and.iphone")
                        .font(.system(size: 52, weight: .light)).foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(paired ? "Computer found" : "Bring your work along.").font(.title2.bold())
                    Text(paired ? (usingDirectRelay ? "Your Windows computer is ready to connect." : "Sign in with your Mac account to finish pairing.")
                         : "Open HerdrWatch Host on your computer, then scan its pairing QR code.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            }.listRowBackground(Color.clear)
            if !directSSH {
                Section {
                    if paired {
                        Label("Secure pairing ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    #if os(iOS)
                    Button { scannerPresented = true } label: {
                        Label(paired ? "Scan another code" : "Scan QR code", systemImage: "qrcode.viewfinder")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.modifier(PrimaryGlassButton()).listRowBackground(Color.clear)
                    #endif
                    DisclosureGroup("Paste pairing code instead", isExpanded: $showCode) {
                        TextField("Pairing code", text: $pairingCode, axis: .vertical)
                            .font(.body.monospaced()).lineLimit(2...4)
                            #if os(iOS)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            #endif
                        if !pairingCode.isEmpty && pairing == nil {
                            Label("Copy the complete code from HerdrWatch Host.", systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                } footer: { Text("Keep HerdrWatch Host running on your computer while connected.") }
            }
            if paired || directSSH {
                Section("Computer") {
                    TextField("Name (optional)", text: $connectionName)
                        #if os(iOS)
                        .textContentType(.nickname)
                        #endif
                }
                if !usingDirectRelay {
                    Section {
                        TextField("Mac username", text: $host.username)
                            #if os(iOS)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            #endif
                        SecureField(hasSavedPassword == true ? "Saved password · leave blank to keep" : "Mac password", text: $password)
                            #if os(iOS)
                            .textContentType(.password)
                            #endif
                    } header: { Text("Mac login") } footer: {
                        Text("Enable Remote Login in your Mac’s System Settings. Your password is saved only on this iPhone. You’ll verify the Mac’s fingerprint before signing in.")
                    }
                }
            }
            if !paired || directSSH {
                Section {
                    DisclosureGroup("Advanced: direct SSH", isExpanded: $directSSH) {
                        TextField("Hostname or private IP", text: $host.address)
                            #if os(iOS)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            #endif
                        TextField("Port", text: $port)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }
                } footer: { if directSSH { Text("Your iPhone must be able to reach this computer on your private network.") } }
            }
            if connection?.id == store.library.activeID, connection != nil {
                Section {
                    DisclosureGroup("Saved credentials") {
                        Button("Forget trusted host key", role: .destructive) { Task { await store.forgetTrust() } }
                        Button("Delete saved password", role: .destructive) { Task { await store.deletePassword(); hasSavedPassword = false } }
                    }
                }
            }
            if let errorMessage {
                Section { Label(errorMessage, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(connection == nil ? "Add computer" : "Edit computer")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $scannerPresented) {
            PairingScannerSheet { value in
                pairingCode = value
                if (try? RelayPairing.decode(value)) == nil {
                    showCode = true
                    errorMessage = "This QR code isn’t a HerdrWatch pairing code. Scan the code in HerdrWatch Host."
                } else { errorMessage = nil }
            }
        }
        #endif
        .safeAreaInset(edge: .bottom) {
            Button(action: saveHost) {
                HStack(spacing: 8) {
                    if saving { ProgressView().tint(.white) }
                    Text(saving ? "Saving…" : "Save and connect").font(.headline)
                    if !saving { Image(systemName: "arrow.right") }
                }.frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .modifier(PrimaryGlassButton()).controlSize(.large)
            .disabled(!ready || saving || store.busy || store.refreshInProgress)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .onAppear {
            host = connection?.host ?? Host(); port = String(host.port)
            connectionName = connection?.name ?? ""
            directSSH = connection != nil && !host.usesRelay
        }
        .task(id: host.passwordAccount) { hasSavedPassword = try? Vault.contains(host.passwordAccount) }
        .disabled(saving || store.busy || store.refreshInProgress)
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 600)
        #endif
    }
    private func saveHost() {
        guard ready, !saving, !store.busy, !store.refreshInProgress else { return }
        guard let number = Int(port) else { errorMessage = "Enter a numeric port."; return }
        var draft = host
        draft.port = number
        if directSSH {
            draft.relayEndpoint = nil
            draft.relayHostID = nil
            draft.relayProtocol = nil
        }
        let code = directSSH ? "" : pairingCode
        let enteredPassword = password
        errorMessage = nil
        saving = true
        Task {
            defer { saving = false }
            do {
                try await store.savePairedConnection(id: connection?.id, name: connectionName,
                                                     host: draft, pairingCode: code, password: enteredPassword)
                pairingCode = ""
                password = ""
                dismiss()
                onSaved?()
                await store.connect()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

struct AgentSessionRow: View {
    @EnvironmentObject var store: WatchStore
    let agent: Agent
    var workspaceLabel: String? = nil
    private var kind: String { agent.agent?.capitalized ?? "Agent" }
    private var location: String? {
        [workspaceLabel, agent.cwd].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " · ").nilIfEmpty
    }
    var body: some View {
        NavigationLink {
            AgentOutputView(target: OutputTarget(agent: agent, scope: store.outputScope))
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "terminal.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                    .frame(width: 39, height: 39).background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(kind).font(.headline)
                        if agent.title.lowercased() != kind.lowercased() {
                            Text(agent.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if let location {
                        Label { Text(verbatim: location).lineLimit(1).truncationMode(.middle) } icon: { Image(systemName: "folder") }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                VStack(spacing: 6) {
                    AgentStatusBadge(status: agent.agent_status)
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                }
            }.padding(13).contentPanel(cornerRadius: 21)
        }.accessibilityHint("Opens the agent screen with live output and an instruction field")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
