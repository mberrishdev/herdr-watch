import XCTest
import Citadel
import NIO
import NIOSSH
import Crypto
@testable import HerdrWatchPreview

final class HerdrWatchTests: XCTestCase {
    func testPasswordProfileCompatibilityAndScope() throws {
        let old = try JSONDecoder().decode(Host.self, from: Data(#"{"address":"server","port":22,"username":"alice"}"#.utf8))
        let passwordHost = old
        XCTAssertEqual(try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(passwordHost)), passwordHost)
        var otherUser = passwordHost
        otherUser.username = "bob"
        XCTAssertNotEqual(passwordHost.passwordAccount, otherUser.passwordAccount)
        var otherPort = passwordHost
        otherPort.port = 2222
        XCTAssertNotEqual(passwordHost.passwordAccount, otherPort.passwordAccount)
    }
    func testSessionStatesAndCommandInjection() throws {
        let data = Data(#"{"name":"default","default":true,"running":false,"connection_error":"denied"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Session.self, from: data).state, "Unavailable")
        let malicious = Session(name: "x'; touch /tmp/pwn; '", default: false, running: true, connection_error: nil)
        XCTAssertThrowsError(try ReadOperation.snapshot(malicious).command)
        let named = Session(name: "work-1", default: false, running: true, connection_error: nil)
        XCTAssertEqual(try ReadOperation.snapshot(named).command, "\(ReadOperation.launcher) --session 'work-1' remote-api-bridge")
        XCTAssertNotNil(ReadOperation.snapshot(named).stdin)
    }
    func testProtocolAndEnvelopeGate() throws {
        let json = #"{"id":"snapshot","result":{"type":"session_snapshot","snapshot":{"version":"0.9.5","protocol":22,"workspaces":[],"tabs":[],"panes":[],"agents":[]}}}"#
        XCTAssertEqual(try Wire.snapshot(Data(json.utf8)).version, "0.9.5")
        for invalid in [json.replacingOccurrences(of: "22", with: "23"), json.replacingOccurrences(of: "0.9.5", with: "0.9.6"), json.replacingOccurrences(of: "\"id\":\"snapshot\"", with: "\"id\":\"wrong\"")] {
            XCTAssertThrowsError(try Wire.snapshot(Data(invalid.utf8)))
        }
        XCTAssertEqual(statusLabel("new_status"), "Unknown (new_status)")
        XCTAssertEqual(statusLabel("blocked"), "Needs attention")
    }
    func testHostKeyFailClosed() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try! group.syncShutdownGracefully() }
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let wire = String(openSSHPublicKey: key)
        for expected in [nil, "different"] as [String?] {
            let promise = group.next().makePromise(of: Void.self)
            PinValidator(expected: expected).validateHostKey(hostKey: key, validationCompletePromise: promise)
            XCTAssertThrowsError(try promise.futureResult.wait())
        }
        let promise = group.next().makePromise(of: Void.self)
        PinValidator(expected: wire).validateHostKey(hostKey: key, validationCompletePromise: promise)
        XCTAssertNoThrow(try promise.futureResult.wait())
        XCTAssertTrue(PinValidator.fingerprint(wire).hasPrefix("SHA256:"))
    }
}

private final class ClosingExecFixture: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private var command = ""
    private var input = Data()
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let request = event as? SSHChannelRequestEvent.ExecRequest else { context.fireUserInboundEventTriggered(event); return }
        command = request.command
        let channel = context.channel
        channel.triggerUserOutboundEvent(ChannelSuccessEvent()).whenSuccess {
            if request.command == "\(ReadOperation.launcher) remote-api-bridge --check" {
                self.reply(channel, text: "herdr-api-bridge-v1\n", status: 0)
            } else if request.command == "\(ReadOperation.launcher) session list --json" {
                self.reply(channel, text: "", status: 127)
            }
        }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let value = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = value.data else { return }
        input.append(contentsOf: bytes.readableBytesView)
        if command == ReadOperation.coreCommand, input.contains(10) {
            let response: Data
            if input == ReadOperation.coreHello.stdin { response = CoreSampleData.hello }
            else if input == ReadOperation.coreTerminals.stdin { response = CoreSampleData.terminals }
            else if input == ReadOperation.coreLayout.stdin { response = CoreSampleData.layout }
            else if let request = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
                    request["method"] as? String == "terminal.read",
                    let params = request["params"] as? [String: Any], params["terminal"] as? String == "t2", params["lines"] as? Int == 0 { response = CoreSampleData.output }
            else { reply(context.channel, text: "", status: 1); return }
            reply(context.channel, text: String(decoding: response, as: UTF8.self) + "\n", status: 0)
            return
        }
        if command == "\(ReadOperation.launcher) remote-api-bridge", input.contains(10) {
            let expected = Data("{\"id\":\"snapshot\",\"method\":\"session.snapshot\",\"params\":{}}\n".utf8)
            guard input == expected else { reply(context.channel, text: "", status: 1); return }
            reply(context.channel, text: #"{"id":"snapshot","result":{"type":"session_snapshot","snapshot":{"version":"0.9.5","protocol":22,"workspaces":[],"tabs":[],"panes":[],"agents":[]}}}"# + "\n", status: 0)
        }
    }
    private func reply(_ channel: Channel, text: String, status: Int) {
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: text))))
            .flatMap { channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: status)) }
            .flatMap { channel.close() }.whenFailure { _ in }
    }
}

private final class PasswordTestServer: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        switch request.request {
        case .password(let value) where request.username == "tester" && value.password == "fixture-only": responsePromise.succeed(.success)
        default: responsePromise.succeed(.failure)
        }
    }
}
extension HerdrWatchTests {
    @MainActor func testRealSSHFirstTrustAndPasswordAuthentication() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let privateKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(NIOSSHHandler(role: .server(SSHServerConfiguration(hostKeys: [privateKey], userAuthDelegate: PasswordTestServer())), allocator: channel.allocator, inboundChildChannelInitializer: { channel, _ in channel.pipeline.addHandler(ClosingExecFixture()) }))
            }.bind(host: "127.0.0.1", port: 0).get()
        let host = Host(address: "127.0.0.1", port: try XCTUnwrap(server.localAddress?.port), username: "tester")
        let client = CitadelTransport(passwordProvider: { _ in "fixture-only" })
        let wire = String(openSSHPublicKey: privateKey.publicKey)
        do {
            try await client.connect(host: host, trustedKey: nil)
            XCTFail("Unknown host key must stop before password authentication")
        } catch let error as WatchError {
            guard case .trust(let observed) = error else { return XCTFail("Wrong trust error: \(error)") }
            XCTAssertEqual(observed, wire)
        } catch { XCTFail("First trust was lost by SSH stack: \(String(reflecting: error))") }
        do {
            try await client.connect(host: host, trustedKey: wire)
            let probe = try await client.execute(.probe)
            XCTAssertEqual(String(decoding: probe, as: UTF8.self), "herdr-api-bridge-v1\n")
            do {
                _ = try await client.execute(.sessions)
                XCTFail("A failed command must retain its exit status")
            } catch let failure as Citadel.SSHClient.CommandFailed { XCTAssertEqual(failure.exitCode, 127) }
            let session = Session(name: "default", default: true, running: true, connection_error: nil)
            let snapshot = try Wire.snapshot(await client.execute(.snapshot(session)))
            XCTAssertTrue(snapshot.workspaces.isEmpty)
            try CoreAdapter.verify(await client.execute(.coreHello))
            let terminals = try await client.execute(.coreTerminals)
            let document = try await client.execute(.coreLayout)
            let coreSnapshot = try CoreAdapter.snapshot(terminals: terminals, document: document)
            XCTAssertEqual(coreSnapshot.workspaces.count, 2)
            XCTAssertEqual(coreSnapshot.agents.count, 2)
            let agent = try XCTUnwrap(coreSnapshot.agents.first)
            let output = try TerminalOutput.decode(await client.execute(.coreOutput(agent.terminal_id)), core: true, agent: agent)
            XCTAssertTrue(output.text.contains("Add a read-only terminal screen"))
            await client.disconnect()
        } catch { XCTFail("Pinned password login failed: \(String(reflecting: error))") }
        do {
            try await client.connect(host: host, trustedKey: "changed-host-key")
            XCTFail("Changed host key must fail closed")
        } catch let error as WatchError {
            guard case .changed = error else { return XCTFail("Expected changed host key") }
        }
        let wrongPassword = CitadelTransport(passwordProvider: { _ in "wrong-fixture-password" })
        do {
            try await wrongPassword.connect(host: host, trustedKey: wire)
            XCTFail("Incorrect password must be rejected")
        } catch {
            XCTAssertTrue(ConnectionFailure.message(error, stage: .ssh).contains("rejected"))
        }
        try await server.close().get()
        try await group.shutdownGracefully()
    }
    func testConnectionFailureSeparatesAuthenticationFromBridge() {
        XCTAssertTrue(ConnectionFailure.message(Citadel.SSHClientError.unsupportedPasswordAuthentication, stage: .ssh).contains("keyboard-interactive"))
        XCTAssertTrue(ConnectionFailure.message(Citadel.SSHClientError.allAuthenticationOptionsFailed, stage: .ssh).contains("rejected"))
    }
}

extension HerdrWatchTests {
    func testDesktopCoreProfileAndLayoutMapping() throws {
        try CoreAdapter.verify(CoreSampleData.hello)
        let badVersion = String(decoding: CoreSampleData.hello, as: UTF8.self).replacingOccurrences(of: "0.1.16", with: "0.1.17")
        XCTAssertThrowsError(try CoreAdapter.verify(Data(badVersion.utf8)))
        XCTAssertThrowsError(try CoreAdapter.verify(Data(String(decoding: CoreSampleData.hello, as: UTF8.self).replacingOccurrences(of: "\"generation\":1", with: "\"generation\":2").utf8)))
        let snapshot = try CoreAdapter.snapshot(terminals: CoreSampleData.terminals, document: CoreSampleData.layout)
        XCTAssertEqual(snapshot.workspaces.first?.label, "Mobile project")
        XCTAssertEqual(snapshot.workspaces.first?.pane_count, 2)
        XCTAssertEqual(snapshot.workspaces.last?.label, "Other live terminals")
        XCTAssertEqual(snapshot.tabs.count, 2)
        XCTAssertEqual(snapshot.agents.count, 2)
        XCTAssertEqual(snapshot.agents.first?.pane_id, "pane2")
        XCTAssertEqual(snapshot.agents.first?.terminal_id, "t2")
        XCTAssertEqual(snapshot.agents.first?.agent_status, "working")
        XCTAssertEqual(snapshot.agents.last?.agent_status, "blocked")
        let wrongID = String(decoding: CoreSampleData.layout, as: UTF8.self).replacingOccurrences(of: "core-layout", with: "another-request")
        XCTAssertThrowsError(try CoreAdapter.snapshot(terminals: CoreSampleData.terminals, document: Data(wrongID.utf8)))
        XCTAssertTrue(try ReadOperation.coreHello.command.contains("-S"))
        XCTAssertFalse(try ReadOperation.coreHello.command.contains("server start"))
    }
    @MainActor func testDesktopStoreDiscoveryAndRefresh() async {
        let store = WatchStore(transport: PreviewTransport(core: true))
        store.isPreview = true
        store.host = Host(address: "fixture", port: 22, username: "tester")
        await store.connect()
        XCTAssertTrue(store.connected)
        XCTAssertEqual(store.sessions.map(\.name), ["default"])
        XCTAssertEqual(store.snapshot?.workspaces.count, 2)
        XCTAssertTrue(store.runtimeLabel.contains("herdr-core"))
        await store.suspend()
        XCTAssertTrue(store.stale)
        await store.connect()
        XCTAssertFalse(store.stale)
        XCTAssertEqual(store.snapshot?.agents.count, 2)
    }
}

extension HerdrWatchTests {
    func testOutputRequestsAreReadOnlyAndStdinEncoded() throws {
        let target = "t1'; echo injected\nwith spaces"
        let operation = ReadOperation.coreOutput(target)
        XCTAssertEqual(try operation.command, ReadOperation.coreCommand)
        XCTAssertFalse(try operation.command.contains(target))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(operation.stdin)) as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "terminal.read")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["terminal"] as? String, target)
        XCTAssertEqual(params["lines"] as? Int, 0)
        XCTAssertNil(params["caller"])
        XCTAssertThrowsError(try ReadOperation.coreOutput(String(repeating: "t", count: 257)).command)
    }
    func testTerminalOutputSanitizationAndByteCap() throws {
        let raw = "before\u{1b}[31mred\u{1b}[0m\u{1b}]52;c;secret\u{7}\u{1b}]8;;https://example.com\u{1b}\\link\u{1b}]8;;\u{1b}\\\u{1b}Pdiscard\u{1b}\\\u{202E} after\r\n"
        XCTAssertEqual(PlainTerminalText.clean(raw), "beforeredlink after\n")
        XCTAssertEqual(PlainTerminalText.clean("safe\u{1b}]unfinished"), "safe")
        let agent = Agent(terminal_id: "t2", workspace_id: "w1", pane_id: "p1", name: nil, agent: "codex", cwd: nil, agent_status: "working")
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "core-output", "result": ["text": String(repeating: "🌱", count: 10000), "complete": false, "how": "screen"]])
        let output = try TerminalOutput.decode(data, core: true, agent: agent)
        XCTAssertLessThanOrEqual(output.text.utf8.count, 32768)
        XCTAssertTrue(output.truncated)
        XCTAssertTrue(output.partial)
        XCTAssertFalse(output.text.contains("�"))
    }
    @MainActor func testOutputCannotCrossHostsAndSurvivesSameHostReconnect() async throws {
        let store = WatchStore(transport: PreviewTransport(core: true))
        store.isPreview = true
        store.host = Host(address: "fixture", port: 22, username: "tester")
        await store.connect()
        let target = OutputTarget(agent: try XCTUnwrap(store.snapshot?.agents.first), scope: store.outputScope)
        let first = try await store.readOutput(for: target)
        XCTAssertTrue(try XCTUnwrap(first).text.contains("Add a read-only terminal screen"))
        await store.suspend()
        await store.connect()
        let resumed = try await store.readOutput(for: target)
        XCTAssertNotNil(resumed)
        store.host = Host(address: "another-host", port: 22, username: "tester")
        do { _ = try await store.readOutput(for: target); XCTFail("A different host must not receive the old target") }
        catch let error as WatchError { XCTAssertTrue(error.localizedDescription.contains("host or session changed")) }
    }
}
