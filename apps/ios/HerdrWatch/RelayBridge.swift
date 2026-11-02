import Foundation
import Network

/// Bridges Citadel's TCP byte stream to the shared opaque WebSocket relay.
/// SSH itself remains end-to-end encrypted and validates its pinned host key.
@MainActor final class RelayBridge {
    private var listener: NWListener?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private let queue = DispatchQueue(label: "dev.herdr.relay-bridge")

    func open(endpoint: String, hostID: String, secret: String) async throws -> UInt16 {
        guard var components = URLComponents(string: endpoint), components.scheme == "wss" else {
            throw WatchError.message("The relay endpoint is invalid.")
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/\(hostID)/phone"
        guard let url = components.url else { throw WatchError.message("The relay endpoint is invalid.") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        socket.resume()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate()
            socket.receive { result in
                gate.resume {
                    switch result {
                    case .success(.string("PEER_CONNECTED")):
                        continuation.resume()
                    case .success(.string("PEER_DISCONNECTED")):
                        continuation.resume(throwing: WatchError.message("The Mac companion disconnected. Keep herdrwatch-host relay run active, then reconnect."))
                    case .success:
                        continuation.resume(throwing: WatchError.message("The relay returned an invalid readiness message."))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
            Task {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                gate.resume {
                    socket.cancel(with: .goingAway, reason: nil)
                    continuation.resume(throwing: WatchError.message("The Mac companion did not confirm this relay pairing. Keep herdrwatch-host relay run active and check that its pairing code matches this iPhone."))
                }
            }
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume { continuation.resume() }
                case .failed(let error):
                    gate.resume { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        guard let port = listener.port?.rawValue else { throw WatchError.message("Could not open the local SSH relay.") }
        return port
    }

    private func accept(_ connection: NWConnection) {
        guard let socket else { connection.cancel(); return }
        connection.start(queue: queue)
        readTCP(connection, socket: socket)
        Task { @MainActor in await readWebSocket(connection, socket: socket) }
    }

    private func readTCP(_ connection: NWConnection, socket: URLSessionWebSocketTask) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in
                    do { try await socket.send(.data(data)); self.readTCP(connection, socket: socket) }
                    catch { connection.cancel() }
                }
            } else if complete || error != nil { connection.cancel() }
            else { Task { @MainActor in self.readTCP(connection, socket: socket) } }
        }
    }

    private func readWebSocket(_ connection: NWConnection, socket: URLSessionWebSocketTask) async {
        do {
            while true {
                let message = try await socket.receive()
                switch message {
                case .string("PEER_CONNECTED"):
                    continue
                case .string("PEER_DISCONNECTED"):
                    connection.cancel()
                    return
                case .data(let data):
                    try await send(data, through: connection)
                case .string:
                    throw WatchError.message("Relay returned an invalid control message.")
                @unknown default:
                    throw WatchError.message("Relay returned an invalid SSH frame.")
                }
            }
        } catch { connection.cancel() }
    }

    private func send(_ data: Data, through connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func close() {
        listener?.cancel(); listener = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func resume(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body()
    }
}
