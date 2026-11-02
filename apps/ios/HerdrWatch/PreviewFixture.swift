#if DEBUG
import Foundation

/// Deterministic sample data for UI checks; never selected by a release build.
final class PreviewTransport: SSHTransport {
    let core: Bool
    let prompts: Bool
    init(core: Bool = false, prompts: Bool = false) { self.core = core; self.prompts = prompts }
    func connect(host: Host, trustedKey: String?, progress: @escaping @MainActor (String) -> Void) async throws {}
    func disconnect() async {}
    func execute(_ operation: ReadOperation) async throws -> Data {
        switch operation {
        case .runtime: return Data((core ? "hc 0.1.16\n" : "herdr-api-bridge-v1\n").utf8)
        case .probe: return Data("herdr-api-bridge-v1\n".utf8)
        case .sessions: return Data(#"{"sessions":[{"name":"default","default":true,"running":true},{"name":"archive","default":false,"running":false},{"name":"restricted","default":false,"running":false,"connection_error":"permission denied"}]}"#.utf8)
        case .coreOutput: return CoreSampleData.output
        case .agentOutput: return Data(#"{"id":"agent-output","result":{"type":"pane_read","read":{"text":"I finished the first pass.\n\n### What changed\n- Kept the session screen focused on the active agent.\n- Added an inline `Message the agent…` field.\n\n### Validation\n```sh\nxcodebuild -scheme HerdrWatchPreview build\n```\n\n> This is a live output snapshot, not a complete transcript.","pane_id":"p1","workspace_id":"w1","truncated":false}}}"#.utf8)
        case .corePrompt: return Data(#"{"jsonrpc":"2.0","id":"core-prompt","result":{"turn":1}}"#.utf8)
        case .agentPrompt: return Data(#"{"id":"agent-prompt","result":{"type":"agent_prompted","agent":{}}}"#.utf8)
        case .coreHello: return prompts ? CoreSampleData.promptHello : CoreSampleData.hello
        case .coreTerminals: return prompts ? CoreSampleData.promptTerminals : CoreSampleData.terminals
        case .coreLayout: return CoreSampleData.layout
        case .snapshot:
            if prompts {
                return Data(#"{"id":"snapshot","result":{"type":"session_snapshot","snapshot":{"version":"0.9.5","protocol":22,"workspaces":[{"workspace_id":"w1","label":"Herdr mobile","agent_status":"done","pane_count":2,"tab_count":1}],"tabs":[{"tab_id":"t1","workspace_id":"w1"}],"panes":[{"pane_id":"p1","tab_id":"t1"},{"pane_id":"p2","tab_id":"t1"}],"agents":[{"terminal_id":"a1","workspace_id":"w1","pane_id":"p1","name":"Build iPhone dashboard","agent":"codex","cwd":"~/Projects/herdr-mobile","agent_status":"done"},{"terminal_id":"a2","workspace_id":"w1","pane_id":"p2","name":"Review transport","agent":"copilot","cwd":"~/Projects/herdr-mobile","agent_status":"blocked"}]}}}"#.utf8)
            }
            return Data(#"{"id":"snapshot","result":{"type":"session_snapshot","snapshot":{"version":"0.9.5","protocol":22,"workspaces":[{"workspace_id":"w1","label":"Herdr mobile","agent_status":"working","pane_count":2,"tab_count":1}],"tabs":[{"tab_id":"t1","workspace_id":"w1"}],"panes":[{"pane_id":"p1","tab_id":"t1"},{"pane_id":"p2","tab_id":"t1"}],"agents":[{"terminal_id":"a1","workspace_id":"w1","pane_id":"p1","name":"Build iPhone dashboard","agent":"codex","cwd":"~/Projects/herdr-mobile","agent_status":"working"},{"terminal_id":"a2","workspace_id":"w1","pane_id":"p2","name":"Review transport","agent":"copilot","cwd":"~/Projects/herdr-mobile","agent_status":"blocked"}]}}}"#.utf8)
        }
    }
}
enum CoreSampleData {
    static let output = Data(#"{"jsonrpc":"2.0","id":"core-output","result":{"text":"Codex · Build dashboard\n\n› Add a read-only terminal screen\n\n• Inspecting workspace and agent state…\n• Added safe, bounded text output.\n• Running SSH transport checks…\n\nWorking · press nothing to observe","complete":true,"how":"screen"}}"#.utf8)
    static let hello = Data(#"{"jsonrpc":"2.0","id":"core-hello","result":{"version":"0.1.16","generation":1,"core":{"id":"sample-core"},"methods":["terminal.list","doc.get","terminal.read"]}}"#.utf8)
    static let promptHello = Data(#"{"jsonrpc":"2.0","id":"core-hello","result":{"version":"0.1.16","generation":1,"core":{"id":"sample-core"},"methods":["terminal.list","doc.get","terminal.read","terminal.send"]}}"#.utf8)
    static let terminals = Data(#"{"jsonrpc":"2.0","id":"core-terminals","result":{"terminals":[{"address":"t1","cwd":"~/Projects/mobile","state":"live","foreground":{"name":"zsh","cwd":"~/Projects/mobile"}},{"address":"t2","cwd":"~/Projects/mobile","state":"live","status":{"state":"working","app":"codex","title":"Build dashboard"}},{"address":"t3","cwd":"~/Projects/api","state":"live","status":{"state":"blocked","app":"copilot","title":"Review API"}}]}}"#.utf8)
    static let promptTerminals = Data(#"{"jsonrpc":"2.0","id":"core-terminals","result":{"terminals":[{"address":"t1","cwd":"~/Projects/mobile","state":"live","foreground":{"name":"zsh","cwd":"~/Projects/mobile"}},{"address":"t2","cwd":"~/Projects/mobile","state":"live","status":{"state":"idle","app":"codex","title":"Build dashboard"}},{"address":"t3","cwd":"~/Projects/api","state":"live","status":{"state":"blocked","app":"copilot","title":"Review API"}}]}}"#.utf8)
    static let layout = Data(#"{"jsonrpc":"2.0","id":"core-layout","result":{"value":{"spaces":[{"id":"w1","name":"Mobile project","tabs":[{"id":"tab1","root":{"id":"row1","type":"row","children":[{"id":"pane1","type":"block","content":{"terminal":"t1"}},{"id":"pane2","type":"block","content":{"terminal":"t2"}}]}}]}]}}}"#.utf8)
}
#endif
