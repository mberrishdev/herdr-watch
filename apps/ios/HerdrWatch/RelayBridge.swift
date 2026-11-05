import Foundation
import Network
import CryptoKit

/// Bridges Citadel's TCP byte stream to the shared opaque WebSocket relay.
/// SSH itself remains end-to-end encrypted and validates its pinned host key.
@MainActor final class RelayBridge {
    private var listener: NWListener?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var directKey: SymmetricKey?
    private var directChallenge: String?
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

    func openDirect(endpoint: String, hostID: String, authToken: String, secret: String) async throws {
        guard var components = URLComponents(string: endpoint), components.scheme == "wss" else {
            throw WatchError.message("The relay endpoint is invalid.")
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/\(hostID)/phone"
        guard let url = components.url else { throw WatchError.message("The relay endpoint is invalid.") }
        guard let secretBytes = Data(base64Encoded: Self.base64URL(secret)), secretBytes.count == 32 else {
            throw WatchError.message("The relay pairing secret is invalid.")
        }
        var keyMaterial = Data("herdrwatch-direct-v2\0".utf8)
        keyMaterial.append(secretBytes)
        let digest = Data(SHA256.hash(data: keyMaterial))
        var request = URLRequest(url: url)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
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
                    case .success(.string("PEER_CONNECTED")): continuation.resume()
                    case .success(.string("PEER_DISCONNECTED")): continuation.resume(throwing: WatchError.message("The Windows companion disconnected. Keep HerdrWatch Host open and connected."))
                    case .success: continuation.resume(throwing: WatchError.message("The relay returned an invalid readiness message."))
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
            Task {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                gate.resume {
                    socket.cancel(with: .goingAway, reason: nil)
                    continuation.resume(throwing: WatchError.message("The Windows companion did not confirm this pairing. Open HerdrWatch Host and connect it to the relay."))
                }
            }
        }
        let derivedKey = SymmetricKey(data: digest)
        let helloMessage = try await socket.receive()
        guard case .data(let helloFrame) = helloMessage else { throw WatchError.message("The relay did not send an encrypted session challenge.") }
        let helloBox = try AES.GCM.SealedBox(combined: helloFrame)
        let helloData = try AES.GCM.open(helloBox, using: derivedKey, authenticating: Data("herdrwatch-direct-v2".utf8))
        let hello = try JSONDecoder().decode(DirectRelayResponse.self, from: helloData)
        guard hello.version == 2, hello.type == "ready", let challenge = hello.challenge, !challenge.isEmpty else {
            throw WatchError.message("The encrypted relay session challenge was invalid.")
        }
        directKey = derivedKey
        directChallenge = challenge
    }

    func executeDirect(kind: String, sessionName: String? = nil, payload: Data? = nil) async throws -> Data {
        guard let socket, let directKey, let directChallenge else { throw WatchError.message("Connect to the Windows companion first.") }
        let id = UUID().uuidString
        var requestObject: [String: Any] = ["version": 2, "id": id, "kind": kind, "challenge": directChallenge]
        if let sessionName { requestObject["session"] = sessionName }
        if let payload {
            let value = try JSONSerialization.jsonObject(with: payload)
            requestObject["payload"] = value
        }
        let plaintext = try JSONSerialization.data(withJSONObject: requestObject)
        let sealed = try AES.GCM.seal(plaintext, using: directKey, authenticating: Data("herdrwatch-direct-v2".utf8))
        guard let combined = sealed.combined else { throw WatchError.message("Could not encrypt the request.") }
        try await socket.send(.data(combined))
        let message = try await socket.receive()
        guard case .data(let encrypted) = message else { throw WatchError.message("The relay returned an invalid encrypted response.") }
        let box = try AES.GCM.SealedBox(combined: encrypted)
        let clear = try AES.GCM.open(box, using: directKey, authenticating: Data("herdrwatch-direct-v2".utf8))
        let response = try JSONDecoder().decode(DirectRelayResponse.self, from: clear)
        guard response.version == 2, response.id == id else { throw WatchError.message("The encrypted response did not match this request.") }
        guard response.ok == true else { throw WatchError.message(response.error ?? "The Windows Herdr bridge rejected the request.") }
        return response.data ?? Data()
    }

    private static func base64URL(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
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
        directKey = nil
        directChallenge = nil
    }
}

private struct DirectRelayResponse: Decodable {
    let version: Int
    let id: String?
    let type: String?
    let challenge: String?
    let ok: Bool?
    let data: Data?
    let error: String?
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
