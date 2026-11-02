interface Env { RELAYS: DurableObjectNamespace }

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url)
    const parts = url.pathname.split("/").filter(Boolean)
    if (parts.length !== 3 || parts[0] !== "v1" || !/^[a-zA-Z0-9_-]{16,64}$/.test(parts[1]) || !["host", "phone"].includes(parts[2])) {
      return new Response("Not found", { status: 404 })
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("WebSocket required", { status: 426 })
    const token = request.headers.get("Authorization")?.replace(/^Bearer\s+/i, "")
    if (!token || token.length < 32 || token.length > 256) return new Response("Unauthorized", { status: 401 })
    const id = env.RELAYS.idFromName(parts[1])
    const headers = new Headers(request.headers)
    headers.set("x-relay-role", parts[2])
    headers.set("x-relay-token", token)
    return env.RELAYS.get(id).fetch(new Request(request, { headers }))
  }
}

export class Relay {
  private sockets = new Set<WebSocket>()
  constructor(private state: DurableObjectState) {
    this.sockets = new Set(state.getWebSockets())
  }
  async fetch(request: Request): Promise<Response> {
    return this.state.blockConcurrencyWhile(async () => {
      const role = request.headers.get("x-relay-role")
      const token = request.headers.get("x-relay-token")
      if ((role !== "host" && role !== "phone") || !token || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("Bad request", { status: 400 })
      const supplied = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token))
      let expected = await this.state.storage.get<ArrayBuffer>("tokenHash")
      if (!expected) {
        expected = supplied
        await this.state.storage.put("tokenHash", expected)
      }
      if (!constantTimeEqual(new Uint8Array(expected), new Uint8Array(supplied))) return new Response("Unauthorized", { status: 401 })
      if ([...this.sockets].some(socket => socket.readyState === WebSocket.OPEN && socket.deserializeAttachment() === role)) return new Response("Peer already connected", { status: 409 })
      if (role === "phone" && ![...this.sockets].some(socket => socket.readyState === WebSocket.OPEN && socket.deserializeAttachment() === "host")) return new Response("Host companion offline", { status: 503 })
      const pair = new WebSocketPair()
      const client = pair[0]
      const server = pair[1]
      server.serializeAttachment(role)
      this.state.acceptWebSocket(server)
      this.sockets.add(server)
      const peerRole = role === "host" ? "phone" : "host"
      const peer = [...this.sockets].find(socket => socket !== server && socket.readyState === WebSocket.OPEN && socket.deserializeAttachment() === peerRole)
      if (peer) {
        // Tell both ends the phone is ready before allowing SSH bytes through.
        // The host then creates its localhost:22 connection, avoiding sshd's
        // idle pre-authentication timeout while the phone is not connected.
        peer.send("PEER_CONNECTED")
        server.send("PEER_CONNECTED")
      }
      return new Response(null, { status: 101, webSocket: client } as ResponseInit)
    })
  }
  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message === "string" || message.byteLength > 1_048_576) {
      socket.close(1003, "Binary SSH frames up to 1 MiB only")
      return
    }
    await this.state.blockConcurrencyWhile(async () => {
      const role = socket.deserializeAttachment()
      let delivered = false
      for (const peer of this.sockets) {
        if (peer !== socket && peer.readyState === WebSocket.OPEN && peer.deserializeAttachment() !== role) {
          try { peer.send(message); delivered = true } catch { /* peer will reconnect */ }
        }
      }
      // SSH is a live TCP byte stream. Buffering bytes across peer reconnects
      // would inject stale SSH protocol data into a new connection.
      if (!delivered) socket.close(1013, "Relay peer is offline")
    })
  }
  async webSocketClose(socket: WebSocket): Promise<void> { await this.detach(socket) }
  async webSocketError(socket: WebSocket): Promise<void> { await this.detach(socket) }

  private async detach(socket: WebSocket): Promise<void> {
    this.sockets.delete(socket)
    await this.state.blockConcurrencyWhile(async () => {
      const role = socket.deserializeAttachment()
      if (role !== "host" && role !== "phone") return
      const peerRole = role === "host" ? "phone" : "host"
      for (const peer of this.sockets) {
        if (peer.readyState === WebSocket.OPEN && peer.deserializeAttachment() === peerRole) {
          try { peer.send("PEER_DISCONNECTED") } catch { /* peer will reconnect */ }
        }
      }
    })
  }
}

function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i]
  return diff === 0
}
