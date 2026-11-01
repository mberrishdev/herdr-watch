#if DEBUG
import Foundation

/// Deterministic sample data for UI checks; never selected by a release build.
final class PreviewTransport: SSHTransport {
    let core: Bool
    init(core: Bool = false) { self.core = core }
    func connect(host: Host, trustedKey: String?) async throws {}
    func disconnect() async {}
    func execute(_ operation: ReadOperation) async throws -> Data {
        switch operation {
        case .runtime: return Data((core ? "hc 0.1.16\n" : "herdr-api-bridge-v1\n").utf8)
        case .probe: return Data("herdr-api-bridge-v1\n".utf8)
        case .sessions: return Data(#"{"sessions":[{"name":"default","default":true,"running":true},{"name":"archive","default":false,"running":false},{"name":"restricted","default":false,"running":false,"connection_error":"permission denied"}]}"#.utf8)
        case .coreHello: return CoreSampleData.hello
        case .coreTerminals: return CoreSampleData.terminals
        case .coreLayout: return CoreSampleData.layout
        case .snapshot:
            return Data(#"{"id":"snapshot","result":{"type":"session_snapshot","snapshot":{"version":"0.9.5","protocol":22,"workspaces":[{"workspace_id":"w1","label":"Herdr mobile","agent_status":"working","pane_count":2,"tab_count":1}],"tabs":[{"tab_id":"t1","workspace_id":"w1"}],"panes":[{"pane_id":"p1","tab_id":"t1"},{"pane_id":"p2","tab_id":"t1"}],"agents":[{"terminal_id":"a1","workspace_id":"w1","pane_id":"p1","name":"Build iPhone dashboard","agent":"codex","cwd":"~/Projects/herdr-mobile","agent_status":"working"},{"terminal_id":"a2","workspace_id":"w1","pane_id":"p2","name":"Review transport","agent":"copilot","cwd":"~/Projects/herdr-mobile","agent_status":"blocked"}]}}}"#.utf8)
        }
    }
}
enum CoreSampleData {
    static let hello = Data(#"{"jsonrpc":"2.0","id":"core-hello","result":{"version":"0.1.16","generation":1,"methods":["terminal.list","doc.get"]}}"#.utf8)
    static let terminals = Data(#"{"jsonrpc":"2.0","id":"core-terminals","result":{"terminals":[{"address":"t1","cwd":"~/Projects/mobile","state":"live","foreground":{"name":"zsh","cwd":"~/Projects/mobile"}},{"address":"t2","cwd":"~/Projects/mobile","state":"live","status":{"state":"working","app":"codex","title":"Build dashboard"}},{"address":"t3","cwd":"~/Projects/api","state":"live","status":{"state":"blocked","app":"copilot","title":"Review API"}}]}}"#.utf8)
    static let layout = Data(#"{"jsonrpc":"2.0","id":"core-layout","result":{"value":{"spaces":[{"id":"w1","name":"Mobile project","tabs":[{"id":"tab1","root":{"id":"row1","type":"row","children":[{"id":"pane1","type":"block","content":{"terminal":"t1"}},{"id":"pane2","type":"block","content":{"terminal":"t2"}}]}}]}]}}}"#.utf8)
}
#endif
