import Foundation
import Citadel
import NIO
import NIOSSH
import Darwin

@MainActor protocol SSHTransport: AnyObject {
    func connect(host: Host, trustedKey: String?) async throws
    func execute(_ operation: ReadOperation) async throws -> Data
    func disconnect() async
}
@MainActor final class CitadelTransport: SSHTransport {
    private var client: SSHClient?
    private var generation = UUID()
    private let passwordProvider: (Host) throws -> String
    init(passwordProvider: ((Host) throws -> String)? = nil) {
        self.passwordProvider = passwordProvider ?? { host in
            guard let data = try Vault.read(host.passwordAccount), let password = String(data: data, encoding: .utf8), !password.isEmpty else {
                throw WatchError.message("Enter and save your SSH password in Host settings.")
            }
            return password
        }
    }
    func connect(host: Host, trustedKey: String?) async throws {
        try host.validate()
        let authentication = SSHAuthenticationMethod.passwordBased(username: host.username, password: try passwordProvider(host))
        let attempt = generation
        let connection = try await SSHClient.connect(host: host.address, port: host.port,
            authenticationMethod: authentication,
            hostKeyValidator: .custom(PinValidator(expected: trustedKey)), reconnect: .never,
            connectTimeout: .seconds(12))
        guard attempt == generation else { try? await connection.close(); throw CancellationError() }
        client = connection
    }
    func execute(_ operation: ReadOperation) async throws -> Data {
        guard let client else { throw WatchError.message("Connect to your host first.") }
        let command = try operation.command
        var result = Data()
        var stderrBytes = 0
        var completeReply = false
        var timedOut = false
        // Closing the connection unblocks a suspended SSH channel read.
        let deadline = Task {
            try await Task.sleep(for: .seconds(15))
            timedOut = true
            try? await client.close()
        }
        defer { deadline.cancel() }
        func consume(_ chunk: ExecCommandOutput) throws -> Bool {
            try Task.checkCancellation()
            switch chunk {
            case .stdout(let bytes):
                guard result.count + bytes.readableBytes <= 1_048_576 else { throw WatchError.message("Host response exceeded the 1 MiB limit.") }
                result.append(contentsOf: bytes.readableBytesView)
                if operation.stdin != nil, let newline = result.firstIndex(of: 10) {
                    result = result.prefix(upTo: newline)
                    completeReply = true
                    return true
                }
            case .stderr(let bytes):
                stderrBytes += bytes.readableBytes
                guard stderrBytes <= 8192 else { throw WatchError.message("Host error output exceeded its limit.") }
            }
            return false
        }
        do {
            if let input = operation.stdin {
                do {
                    try await client.withExec(command) { inbound, outbound in
                        try await outbound.write(ByteBuffer(bytes: input))
                        for try await chunk in inbound {
                            if try consume(chunk) { return }
                        }
                    }
                } catch ChannelError.alreadyClosed where completeReply {
                    // A full NDJSON response arrived before the peer closed the channel.
                    // Citadel's withExec then tries to close it again. Only accept this
                    // race when a complete response was received; parsing remains required.
                }
                guard completeReply else { throw WatchError.message("Herdr closed the bridge before returning a complete JSON response.") }
            } else {
                // Finite CLI commands close their own channels. Avoid withExec's
                // second close, which can mask both successful exits and real errors.
                let stream = try await client.executeCommandStream(command)
                for try await chunk in stream { _ = try consume(chunk) }
            }
        } catch {
            if timedOut { throw WatchError.message("Herdr command timed out after 15 seconds. SSH login succeeded; check the host's non-interactive shell and Herdr command.") }
            throw error
        }
        if timedOut { throw WatchError.message("Herdr command timed out after 15 seconds. SSH login succeeded; check the host's non-interactive shell and Herdr command.") }
        return result
    }
    func disconnect() async { generation = UUID(); let old = client; client = nil; try? await old?.close() }
}

enum ConnectionStage: String {
    case ssh = "SSH connection"
    case bridge = "Herdr bridge check"
    case snapshot = "Herdr session discovery / snapshot"
}
enum ConnectionFailure {
    static func message(_ error: Error, stage: ConnectionStage) -> String {
        if let failure = error as? SSHClientError {
            switch failure {
            case .unsupportedPasswordAuthentication:
                return "The SSH server does not offer password authentication. Termius may be using keyboard-interactive login, which this SSH library does not support."
            case .allAuthenticationOptionsFailed:
                return "The SSH server rejected the saved username/password. Check the exact username, port and saved password."
            default: return "\(stage.rawValue) failed (SSH channel setup)."
            }
        }
        if error is AuthenticationFailed { return "SSH authentication was rejected by the server." }
        if let error = error as? SSHClient.CommandFailed {
            if error.exitCode == 69 { return "The Herdr desktop default session is not running at its standard socket. Open the Herdr desktop app as this SSH user, then reconnect. This app never starts the server." }
            return "\(stage.rawValue) failed: remote command exited with status \(error.exitCode). SSH login succeeded; check that herdr is installed in the non-interactive SSH PATH."
        }
        if let error = error as? NIOSSHError {
            return "\(stage.rawValue) failed during SSH protocol negotiation (\(error.type))."
        }
        if let error = error as? NIOConnectionError {
            if error.connectionErrors.isEmpty && (error.dnsAError != nil || error.dnsAAAAError != nil) {
                return "SSH hostname could not be resolved. Use the same IP address as Termius, or check DNS / Tailscale connectivity."
            }
            let codes = error.connectionErrors.compactMap { ($0.error as? IOError)?.errnoCode }
            if codes.contains(ECONNREFUSED) { return "SSH port refused the connection. Check the host and port against Termius." }
            if codes.contains(EACCES) || codes.contains(EPERM) { return "iOS denied network access. Check Settings → Privacy & Security → Local Network → HerdrWatch and your VPN access." }
            if codes.contains(EHOSTUNREACH) || codes.contains(ENETUNREACH) { return "No route to the SSH host. Check iPhone local-network permission and VPN / Tailscale access." }
            return "Could not reach the SSH host. Check the exact hostname/IP and port, and iPhone local-network or VPN access."
        }
        if error is CancellationError { return "Connection interrupted while the app was inactive. Tap Connect again." }
        if error is ChannelError { return "\(stage.rawValue) timed out or the server closed the connection. Check host reachability and SSH server logs." }
        return "\(stage.rawValue) failed (\(String(reflecting: type(of: error))))."
    }
}
