# HerdrWatch host companion

The host companion is a Go CLI for macOS and Windows. The recommended shared-relay mode connects outbound to the HerdrWatch Worker and does not require users to have a Cloudflare account. An older Cloudflare One mode is also retained: it creates a remotely managed Tunnel and private route, then runs `cloudflared` in the foreground.

On macOS, shared-relay mode forwards the iPhone's end-to-end encrypted SSH stream to `127.0.0.1:22`; the host does not open an inbound router port. On Windows, pairing uses protocol v2: the phone and companion encrypt fixed Herdr API requests and responses with AES-GCM using a key derived from the one-time pairing secret. The relay forwards ciphertext and can observe relay ID, timing, and traffic volume. The companion runs Herdr locally as the signed-in user and does not accept remote shell commands.

See the root [README](../../README.md#shared-relay-no-vpn-app-on-iphone) for the shared-relay deployment and pairing flow.

## Desktop host manager

The Tauri manager in [apps/desktop](../../apps/desktop/README.md) supports Windows and macOS. The native SwiftUI menu-bar manager remains available through the root Xcode project and **HerdrWatchHost** scheme on macOS. Both bundle this Go companion, create/reveal the pairing QR, and start/stop the relay. The current relay accepts one iPhone at a time.

The GUI uses `relay status --json`, `relay pairing-code --json`, and
`relay init --json`; the JSON forms are intended for the local desktop app.
They never include Cloudflare credentials. The pairing-code response contains
the relay secret and should only be shown on demand or during first pairing.

## Legacy Cloudflare One tunnel mode

The `start`, `login`, `setup`, and `run` commands below are for the retained
Cloudflare One/WARP flow. New users should use the shared relay steps in the
root README instead.

### One-time Cloudflare OAuth client registration

Cloudflare OAuth requires the app publisher to register an OAuth client before sign-in can work. For a personal build, create a private OAuth client in your Cloudflare account. For distribution to other Cloudflare accounts, the client must be made public and the publisher domain verified.

Configure the client for:

- Authorization Code grant, with refresh-token support.
- Public client / token endpoint authentication `none`.
- Redirect URI: `http://127.0.0.1:8976/oauth/callback`.
- PKCE with `S256` (the CLI does this automatically).
- Account Settings Read (`account-settings.read`) to find and display your Cloudflare account automatically.
- Cloudflare Tunnel Edit (`argotunnel.write`), shown in the dashboard as **Argo Tunnel (Legacy) → Edit**. Cloudflare accepts the Tunnel permission for private-route creation too.
- Zero Trust Write (`zero-trust.write`) to create and remove the WARP device profile for the host route.

This personal OAuth client ID is built into this companion. You can override it with
`HERDRWATCH_CLOUDFLARE_CLIENT_ID` when building for a different Cloudflare account. The ID is
public and is not a password. The publisher-verification TXT value is only needed if you
promote the OAuth client to public distribution; keep it in your DNS provider, not this repo.

macOS:

```sh
export HERDRWATCH_CLOUDFLARE_CLIENT_ID="your-client-id" # optional override
```

Windows PowerShell:

```powershell
$env:HERDRWATCH_CLOUDFLARE_CLIENT_ID = "your-client-id" # optional override
```

## Install and connect (legacy Cloudflare One mode)

Build the companion once:

```sh
cd services/host
go build -o dist/herdrwatch-host ./cmd/herdrwatch-host
./dist/herdrwatch-host start
```

If `cloudflared` is missing, `start` prints the install command for your platform. On macOS with Homebrew, run `brew install cloudflared`; on Windows with winget, run `winget install --id Cloudflare.cloudflared`. Then run `start` again. It opens Cloudflare sign-in if needed, discovers the computer's private IP, creates a route for that one address, creates an iOS device profile with that host as the only included WARP route, and starts the connector. The profile matches all enrolled iOS devices in this Zero Trust organization. Other iOS traffic bypasses WARP under this Include profile. Cloudflare may take up to 10 minutes to apply profile changes. OAuth and tunnel tokens are kept in the macOS Keychain or Windows Credential Manager; the local settings file contains IDs and the host address only. On later runs, use the same `start` command to reconnect.

The connector runs in the foreground. Keep the terminal open; Ctrl+C stops the tunnel. `doctor`, `login`, `setup --ip ...`, and `run` remain available as separate troubleshooting commands.

Use `herdrwatch-host status` to see configured IDs and credential-store presence. `herdrwatch-host remove --yes` deletes this companion's route and tunnel from Cloudflare and clears the local tunnel credential.

## iPhone setup (legacy Cloudflare One mode)

Install the official Cloudflare One app on the iPhone and enroll it in the same Zero Trust organization. The companion creates a dedicated iOS profile automatically. Then use the host IP, SSH port, and username in HerdrWatch and verify the SSH host key.

HerdrWatch cannot embed Cloudflare One's iOS VPN profile. The official Cloudflare One app manages that system VPN connection.

## Host requirements

- Herdr must be installed and running for the same user account that runs the companion.
- The host needs a stable private IPv4 address. A DHCP reservation is recommended.
- macOS includes OpenSSH; enable **System Settings → General → Sharing → Remote Login**.
- Windows does not require OpenSSH Server. Herdr must be installed for the signed-in account and available as `herdr` on PATH.
- The Windows direct Herdr bridge supports upstream `herdr remote-api-bridge` operations through a restricted method allowlist. It should be validated with the Herdr versions intended for release.

## Build

From this directory:

```sh
go build -o dist/herdrwatch-host ./cmd/herdrwatch-host
```

Cross-compile a Windows binary from macOS:

```sh
GOOS=windows GOARCH=amd64 go build -o dist/herdrwatch-host.exe ./cmd/herdrwatch-host
```
