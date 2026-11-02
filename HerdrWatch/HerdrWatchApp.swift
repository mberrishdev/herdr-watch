import SwiftUI

@main struct HerdrWatchApp: App {
    @StateObject private var store: WatchStore
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HERDRWATCH_PREVIEW"] == "1" {
            let store = WatchStore(transport: PreviewTransport(
                core: ProcessInfo.processInfo.environment["HERDRWATCH_CORE_PREVIEW"] == "1",
                prompts: ProcessInfo.processInfo.environment["HERDRWATCH_PROMPT_PREVIEW"] == "1"
            ))
            store.host = Host(address: "sample.tailnet", port: 22, username: "developer")
            store.isPreview = true
            _store = StateObject(wrappedValue: store)
            return
        }
        #endif
        _store = StateObject(wrappedValue: WatchStore())
    }
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.environment["HERDRWATCH_OUTPUT_PREVIEW"] == "1" {
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
        }.padding(.horizontal, 11).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).glassPanel(cornerRadius: 17)
    }
}
private struct SetupStep: View {
    let number: String
    let title: String
    let active: Bool
    var body: some View {
        HStack(spacing: 6) {
            Text(number).font(.caption2.bold()).frame(width: 22, height: 22)
                .foregroundStyle(active ? Color.white : Color.secondary)
                .background(active ? Color.accentColor : Color.primary.opacity(0.08), in: Circle())
            Text(title).font(.caption.weight(active ? .semibold : .regular)).foregroundStyle(active ? Color.primary : Color.secondary)
        }.fixedSize()
    }
}
private struct LabeledInput: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2.weight(.semibold)).tracking(0.75).foregroundStyle(.secondary)
            TextField(placeholder, text: $text).font(.body)
                .padding(13).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
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
                        connectionCard
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
                                        .glassPanel(cornerRadius: 24)
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
                        else if store.sessions.isEmpty && !store.busy && !store.connected { firstUseCard }
                        Text("Foreground monitoring · agent input available · refreshes every 15 seconds")
                            .font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.top, 2)
                    }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 28)
                }
            }
            .navigationTitle("HerdrWatch")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Host settings").disabled(store.busy) }
            .refreshable { await store.refresh() }
            .onAppear {
                #if DEBUG
                if ProcessInfo.processInfo.environment["HERDRWATCH_SETTINGS"] != nil { settings = true }
                #endif
            }
            .sheet(isPresented: $settings) { HostSettings().environmentObject(store) }
            .onChange(of: store.snapshot?.workspaces.map(\.id)) { _, ids in
                if let selectedWorkspaceID, ids?.contains(selectedWorkspaceID) != true { self.selectedWorkspaceID = nil }
            }
            .task(id: phase) {
                if phase != .active { await store.suspend(); return }
                if !store.host.address.isEmpty && (store.observed != nil || store.isPreview) { await store.connect() }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    await store.refresh(silent: true)
                }
            }
        }
        .overlay { if phase != .active { Color(.gray).ignoresSafeArea().overlay { Label("HerdrWatch", systemImage: "lock.fill").font(.title) } } }
    }
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Image(systemName: store.connected ? "point.3.connected.trianglepath.dotted" : "network.slash")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(store.connected ? .green : .secondary)
                    .frame(width: 44, height: 44).background((store.connected ? Color.green : Color.secondary).opacity(0.13), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.connected ? "Connected" : "Your Herdr host").font(.headline)
                    Text(store.host.address.isEmpty ? "Add one SSH host to get started" : "\(store.host.username)@\(store.host.address) · SSH \(store.host.port)")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if store.isPreview { Text("SAMPLE").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.orange) }
            }
            if store.connected, let observed = store.observed {
                HStack(spacing: 6) {
                    Circle().fill(store.stale ? .orange : .green).frame(width: 6, height: 6)
                    Text("\(store.stale ? "Last updated" : "Live") · \(observed.formatted(date: .omitted, time: .shortened))")
                    Spacer()
                    Text(store.runtimeLabel.replacingOccurrences(of: "Herdr desktop · ", with: "").replacingOccurrences(of: "Herdr CLI · ", with: ""))
                }.font(.caption).foregroundStyle(.secondary)
            }
            if store.busy { ProgressView(store.connected ? "Refreshing workspace…" : "Connecting securely…").font(.subheadline).tint(.accentColor) }
            else {
                Button {
                    if store.host.address.isEmpty { settings = true }
                    else { Task { await store.connectOrRefresh() } }
                } label: {
                    Label(store.connected ? "Refresh workspace" : store.host.address.isEmpty ? "Set up connection" : "Connect securely",
                          systemImage: store.connected ? "arrow.clockwise" : "lock.shield")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                        .foregroundStyle(.white)
                }.buttonStyle(.plain)
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
        }.glassPanel(cornerRadius: 18)
    }
    private func noticeCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill").font(.subheadline)
            .foregroundStyle(.orange).padding(14).frame(maxWidth: .infinity, alignment: .leading).glassPanel(cornerRadius: 18)
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
        }.padding(18).glassPanel(cornerRadius: 24)
    }
    private var emptySnapshot: some View {
        ContentUnavailableView(store.sessions.isEmpty ? "No Herdr sessions found" : "No running session", systemImage: "rectangle.stack",
                               description: Text(store.sessions.isEmpty ? "Check that Herdr is running for this SSH account, then refresh." : "Open Herdr on the host with this account, then refresh."))
            .padding(16).glassPanel(cornerRadius: 24)
    }
    private func emptyAgents(workspace: Workspace) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("No agents in \(workspace.label.isEmpty ? "this workspace" : workspace.label)").font(.subheadline.weight(.medium))
                Text("Choose All workspaces or another workspace above.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).glassPanel(cornerRadius: 20)
    }
    private var firstUseCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "binoculars").font(.system(size: 34, weight: .light)).foregroundStyle(Color.accentColor)
            Text("Your agents, at a glance").font(.title3.weight(.semibold))
            Text("Connect to one Herdr host over SSH to see workspaces and agent status.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Set up SSH host") { settings = true }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity).padding(22).glassPanel(cornerRadius: 26)
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
            ZStack {
                GlassBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Connect your host").font(.largeTitle.weight(.bold))
                            Text("A few details to securely find your Herdr workspace.").font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.horizontal, 3).padding(.top, 10)
                        HStack(spacing: 0) {
                            SetupStep(number: "1", title: "Host", active: true)
                            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).frame(maxWidth: 28)
                            SetupStep(number: "2", title: "Password", active: true)
                            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).frame(maxWidth: 28)
                            SetupStep(number: "3", title: "Verify", active: false)
                        }.padding(.vertical, 2)
                        VStack(alignment: .leading, spacing: 13) {
                            cardHeading("Host details", subtitle: "The Mac or server where Herdr is running.", symbol: "network")
                            VStack(spacing: 9) {
                                LabeledInput(title: "HOSTNAME OR TAILSCALE IP", placeholder: "mac-mini.example.ts.net", text: $host.address)
                                    #if os(iOS)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                    #endif
                                HStack(spacing: 9) {
                                    LabeledInput(title: "SSH USERNAME", placeholder: "developer", text: $host.username)
                                        #if os(iOS)
                                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                                        #endif
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("PORT").font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                                        TextField("22", text: $port).font(.body.monospacedDigit())
                                            .padding(13).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
                                            #if os(iOS)
                                            .keyboardType(.numberPad)
                                            #endif
                                    }.frame(width: 86)
                                }
                            }
                            Text("Herdr needs to be installed and running for this SSH account. Use a private network such as Tailscale.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(17).glassPanel(cornerRadius: 24)
                        VStack(alignment: .leading, spacing: 13) {
                            cardHeading("SSH password", subtitle: "Used only to sign in to this host.", symbol: "key.horizontal")
                            SecureField("Enter SSH password", text: $password)
                                .font(.body).padding(14).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
                                .frame(minHeight: 48)
                                #if os(iOS)
                                .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                                #endif
                            if let hasSavedPassword {
                                Label(hasSavedPassword ? "Saved in this iPhone’s Keychain" : "No password saved yet",
                                      systemImage: hasSavedPassword ? "checkmark.shield.fill" : "lock")
                                    .font(.caption.weight(.medium)).foregroundStyle(hasSavedPassword ? .green : .secondary)
                            } else { Text("Checking saved password…").font(.caption).foregroundStyle(.secondary) }
                            Text("Stored on this device only. Leave blank to keep the saved password. Your server must allow SSH password login.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(17).glassPanel(cornerRadius: 24)
                        VStack(alignment: .leading, spacing: 10) {
                            cardHeading("Verify before connecting", subtitle: "On first connection, compare the server fingerprint with a trusted source. Your password is withheld until you trust it.", symbol: "checkmark.shield")
                        }.padding(17).glassPanel(cornerRadius: 24)
                        DisclosureGroup("Advanced local data") {
                            VStack(alignment: .leading, spacing: 12) {
                                Button("Clear in-memory snapshot") { store.clearCache() }
                                Button("Forget trusted host key", role: .destructive) { Task { await store.forgetTrust() } }
                                Button("Delete saved SSH password", role: .destructive) { Task { await store.deletePassword(); hasSavedPassword = try? Vault.contains(host.passwordAccount) } }
                            }.padding(.top, 12)
                        }.font(.subheadline.weight(.medium)).padding(16).glassPanel(cornerRadius: 20)
                        if let message = store.message { Label(message, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.orange).padding(14).glassPanel(cornerRadius: 18) }
                    }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 18)
                }
            }
            .navigationTitle("Connection")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button(action: saveHost) {
                    Label("Save connection", systemImage: "lock.shield.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                        .foregroundStyle(.white)
                }.buttonStyle(.plain).padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 8)
                    .background(.ultraThinMaterial)
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
    private func cardHeading(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol).font(.headline).foregroundStyle(Color.accentColor).frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func saveHost() {
        guard let number = Int(port) else { store.message = "Enter a numeric port."; return }
        host.port = number
        do {
            try host.validate()
            if !password.isEmpty { try Vault.save(Data(password.utf8), account: host.passwordAccount) }
            password = ""
            Task { await store.suspend(); store.clearCache(); store.pendingKey = nil; store.host = host; UserDefaults.standard.set(try? JSONEncoder().encode(host), forKey: "host"); dismiss() }
        } catch { store.message = error.localizedDescription }
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
            }.padding(13).glassPanel(cornerRadius: 21)
        }.accessibilityHint("Opens the agent screen with live output and an instruction field")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
