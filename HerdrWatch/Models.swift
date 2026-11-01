import Foundation

struct Host: Codable, Equatable {
    var address = ""
    var port = 22
    var username = ""
    var passwordAccount: String { "password:\(identity):\(username)" }
    var identity: String { "\(address.lowercased()):\(port)" }
    func validate() throws {
        guard !address.isEmpty, address.count <= 253, !address.contains("\0"), !username.contains("\0"), username.count <= 128, !username.contains(where: { $0.isWhitespace }), !address.contains(where: { $0.isWhitespace || $0.isNewline }), !username.isEmpty, (1...65535).contains(port) else { throw WatchError.message("Enter a host, SSH username and port 1–65535.") }
    }
}
enum WatchError: LocalizedError {
    case message(String), trust(String), changed
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .trust: return "Verify this host key through an independent channel before trusting it."
        case .changed: return "Host key changed. Connection blocked before authentication. Verify the host independently, then forget its trusted key in settings if the change is expected."
        }
    }
}
struct Session: Decodable, Identifiable {
    let name: String
    let `default`: Bool
    let running: Bool
    let connection_error: String?
    var id: String { name }
    var state: String { connection_error != nil ? "Unavailable" : running ? "Running" : "Stopped" }
}
struct Snapshot: Decodable {
    let version: String
    let `protocol`: Int
    let workspaces: [Workspace]
    let tabs: [Tab]
    let panes: [Pane]
    let agents: [Agent]
}
struct Workspace: Decodable, Identifiable {
    let workspace_id: String
    let label: String
    let agent_status: String
    let pane_count: Int
    let tab_count: Int
    var id: String { workspace_id }
}
struct Tab: Decodable, Identifiable {
    let tab_id: String
    let workspace_id: String
    var label: String? = nil
    var id: String { tab_id }
}
struct Pane: Decodable, Identifiable {
    let pane_id: String
    let tab_id: String
    var id: String { pane_id }
}
struct Agent: Decodable, Identifiable {
    let terminal_id: String
    let workspace_id: String
    let pane_id: String
    let name: String?
    let agent: String?
    let cwd: String?
    let agent_status: String
    var id: String { terminal_id }
    var title: String { name ?? agent ?? "Detected agent" }
}
func statusLabel(_ raw: String) -> String {
    switch raw { case "unknown": return "Unknown"; case "error": return "Error"; case "working": return "Working"; case "blocked": return "Needs attention"; case "idle": return "Idle"; case "done": return "Done"; default: return "Unknown (\(raw))" }
}
enum ReadOperation {
    // Non-interactive SSH shells often omit per-user and Homebrew install paths.
    // This fixed prefix expands only the remote account's HOME/PATH, never user input.
    static let launcher = "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\" exec herdr"
    case runtime, coreHello, coreTerminals, coreLayout
    case sessions, probe, snapshot(Session)
    case coreOutput(String), agentOutput(Session, String)
    static let pathSetup = "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; export PATH; "
    static let coreCommand = pathSetup + "if [ ! -S \"${XDG_STATE_HOME:-$HOME/.local/state}/herdr-core/default/default.sock\" ]; then exit 69; fi; exec herdr-core connect --session default"
    var command: String {
        get throws {
            switch self {
            case .runtime: return Self.pathSetup + "if command -v herdr-core >/dev/null 2>&1; then exec herdr-core --version; else exec herdr remote-api-bridge --check; fi"
            case .coreHello, .coreTerminals, .coreLayout: return Self.coreCommand
            case .coreOutput(let target):
                try Self.validateTarget(target)
                return Self.coreCommand
            case .agentOutput(let session, let target):
                try Self.validateTarget(target)
                return try Self.snapshot(session).command
            case .sessions: return "\(Self.launcher) session list --json"
            case .probe: return "\(Self.launcher) remote-api-bridge --check"
            case .snapshot(let session):
                guard session.name.utf8.count <= 128, session.name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw WatchError.message("Unsupported session name.") }
                return session.default ? "\(Self.launcher) remote-api-bridge" : "\(Self.launcher) --session '\(session.name)' remote-api-bridge"
            }
        }
    }
    private static func validateTarget(_ target: String) throws {
        guard !target.isEmpty, target.utf8.count <= 256, !target.contains("\0") else { throw WatchError.message("Invalid terminal identity.") }
    }
    private static func json(_ object: [String: Any]) -> Data {
        // Only JSON primitives are constructed here; no arbitrary Encodable values.
        var data = try! JSONSerialization.data(withJSONObject: object)
        data.append(10)
        return data
    }
    var stdin: Data? {
        let request: String?
        switch self {
        case .coreOutput(let target):
            return Self.json(["jsonrpc": "2.0", "id": "core-output", "method": "terminal.read", "params": ["terminal": target, "lines": 0]])
        case .agentOutput(_, let target):
            return Self.json(["id": "agent-output", "method": "agent.read", "params": ["target": target, "source": "recent_unwrapped", "lines": 100, "format": "text", "strip_ansi": true]])
        case .coreHello: request = #"{"jsonrpc":"2.0","id":"core-hello","method":"hello","params":{"generation":1,"framed":false}}"#
        case .coreTerminals: request = #"{"jsonrpc":"2.0","id":"core-terminals","method":"terminal.list","params":{}}"#
        case .coreLayout: request = #"{"jsonrpc":"2.0","id":"core-layout","method":"doc.get","params":{"name":"herdr-app"}}"#
        default: request = nil
        }
        if let request { return Data((request + "\n").utf8) }
        if case .snapshot = self { return Data("{\"id\":\"snapshot\",\"method\":\"session.snapshot\",\"params\":{}}\n".utf8) }
        return nil
    }
}
enum Wire {
    static func snapshot(_ data: Data) throws -> Snapshot {
        struct Envelope: Decodable {
            struct Result: Decodable { let type: String; let snapshot: Snapshot? }
            struct Failure: Decodable { let code: String }
            let id: String; let result: Result?; let error: Failure?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.id == "snapshot", envelope.error == nil, envelope.result?.type == "session_snapshot", let value = envelope.result?.snapshot else { throw WatchError.message("Herdr rejected the snapshot or returned an unexpected response.") }
        guard value.protocol == 22, value.version == "0.9.5" else { throw WatchError.message("Unsupported Herdr version. This build requires upstream 0.9.5 / protocol 22.") }
        return value
    }
}
