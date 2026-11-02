import Foundation

/// Separate, explicitly gated profile for the installed Herdr desktop runtime.
/// Its JSON-RPC generation 1 is not upstream Herdr's protocol 22.
enum CoreAdapter {
    struct Hello: Decodable {
        struct Identity: Decodable { let id: String }
        let core: Identity
        let version: String
        let generation: Int
        let methods: [String]
    }
    struct TerminalList: Decodable { let terminals: [Terminal] }
    struct Terminal: Decodable {
        struct Status: Decodable { let state: String; let app: String?; let title: String? }
        struct Foreground: Decodable { let name: String; let cwd: String }
        let address: String
        let name: String?
        let cwd: String
        let state: String
        let status: Status?
        let foreground: Foreground?
        var agentName: String? {
            if let status { return status.app ?? foreground?.name ?? "Reported agent" }
            guard let name = foreground?.name, ["codex", "claude", "copilot", "gemini", "opencode"].contains(name.lowercased()) else { return nil }
            return name
        }
    }
    struct Document: Decodable { let value: Layout? }
    struct Layout: Decodable { let spaces: [Space] }
    struct Space: Decodable { let id: String; let name: String; let tabs: [LayoutTab] }
    struct LayoutTab: Decodable { let id: String; let name: String?; let root: Node }
    struct Node: Decodable {
        struct Content: Decodable { let terminal: String? }
        let id: String
        let type: String
        let children: [Node]?
        let content: Content?
        var leaves: [Node] { type == "block" ? [self] : (children ?? []).flatMap(\.leaves) }
    }
    private struct Header: Decodable { let jsonrpc: String; let id: String; let error: Failure? }
    private struct Failure: Decodable { let code: Int }
    static func result<T: Decodable>(_ type: T.Type, from data: Data, id: String) throws -> T {
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.jsonrpc == "2.0", header.id == id, header.error == nil else { throw WatchError.message("Herdr desktop returned an invalid or rejected read request.") }
        let envelope = try JSONDecoder().decode(CoreEnvelope<T>.self, from: data)
        return envelope.result
    }
    @discardableResult static func verify(_ data: Data) throws -> Hello {
        let hello = try result(Hello.self, from: data, id: "core-hello")
        guard hello.generation == 1, hello.version == "0.1.16", ["terminal.list", "doc.get"].allSatisfy(hello.methods.contains) else {
            throw WatchError.message("Unsupported Herdr desktop runtime. This profile requires herdr-core 0.1.16 / generation 1 with terminal.list and doc.get.")
        }
        return hello
    }
    static func snapshot(terminals: Data, document: Data) throws -> Snapshot {
        let list = try result(TerminalList.self, from: terminals, id: "core-terminals")
        let layout = try result(Document.self, from: document, id: "core-layout")
        var workspaces: [Workspace] = [], tabs: [Tab] = [], panes: [Pane] = [], agents: [Agent] = []
        var placed = Set<String>()
        var terminalByID: [String: Terminal] = [:]
        for terminal in list.terminals {
            guard terminalByID.updateValue(terminal, forKey: terminal.address) == nil else { throw WatchError.message("Herdr desktop returned duplicate terminal identities.") }
        }
        func appendAgent(_ terminal: Terminal, workspace: String, tab: String, pane: String) {
            guard !agents.contains(where: { $0.terminal_id == terminal.address }), let kind = terminal.agentName else { return }
            agents.append(Agent(terminal_id: terminal.address, workspace_id: workspace, pane_id: pane,
                name: [terminal.name, terminal.status?.title].compactMap { $0 }.first(where: { !$0.isEmpty }), agent: kind, cwd: terminal.foreground?.cwd ?? terminal.cwd,
                agent_status: terminal.status?.state ?? "unknown"))
        }
        for space in layout.value?.spaces ?? [] {
            var spacePanes = 0
            for tab in space.tabs {
                tabs.append(Tab(tab_id: tab.id, workspace_id: space.id, label: tab.name))
                for node in tab.root.leaves {
                    panes.append(Pane(pane_id: node.id, tab_id: tab.id)); spacePanes += 1
                    if let address = node.content?.terminal, let terminal = terminalByID[address] {
                        placed.insert(address)
                        appendAgent(terminal, workspace: space.id, tab: tab.id, pane: node.id)
                    }
                }
            }
            let statuses = agents.filter { $0.workspace_id == space.id }.map(\.agent_status)
            let status = ["blocked", "working", "error", "done", "idle"].first(where: statuses.contains) ?? "unknown"
            workspaces.append(Workspace(workspace_id: space.id, label: space.name, agent_status: status, pane_count: spacePanes, tab_count: space.tabs.count))
        }
        let unplaced = list.terminals.filter { !placed.contains($0.address) }
        if !unplaced.isEmpty {
            let group = "herdrwatch:unplaced"
            workspaces.append(Workspace(workspace_id: group, label: "Other live terminals", agent_status: ["blocked", "working", "error", "done", "idle"].first(where: { state in unplaced.contains { $0.status?.state == state } }) ?? "unknown", pane_count: unplaced.count, tab_count: unplaced.count))
            for terminal in unplaced {
                let tab = "herdrwatch:tab:\(terminal.address)", pane = "herdrwatch:pane:\(terminal.address)"
                tabs.append(Tab(tab_id: tab, workspace_id: group)); panes.append(Pane(pane_id: pane, tab_id: tab))
                appendAgent(terminal, workspace: group, tab: tab, pane: pane)
            }
        }
        guard Set(workspaces.map(\.id)).count == workspaces.count, Set(tabs.map(\.id)).count == tabs.count,
              Set(panes.map(\.id)).count == panes.count else { throw WatchError.message("Herdr desktop layout contains duplicate identities.") }
        return Snapshot(version: "0.1.16", protocol: 1, workspaces: workspaces, tabs: tabs, panes: panes, agents: agents)
    }
}
private struct CoreEnvelope<T: Decodable>: Decodable { let result: T }
