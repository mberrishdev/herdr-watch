# HerdrWatch

## Shared relay (no VPN app on iPhone)

HerdrWatch can carry its existing SSH connection over the HerdrWatch shared
Cloudflare Worker relay. The relay forwards binary SSH frames; the SSH stream
is encrypted and host-key pinned end to end by Citadel. The relay cannot read
SSH passwords, Herdr session data, or agent output. It can observe connection
metadata (relay ID, timing, and traffic volume). The Mac companion listens only
on the host's loopback SSH port and opens an outbound WSS connection, so no
inbound router port or VPN app is needed.

### One-time maintainer deployment

Deploy the shared Worker once under the HerdrWatch service account. This is not
per-user Cloudflare setup:

```sh
cd services/relay
npm ci
npm run deploy
```

Cloudflare will print the Worker URL, for example
`https://herdrwatch-relay.<account>.workers.dev`. The host CLI expects the
WebSocket form, `wss://herdrwatch-relay.<account>.workers.dev`.

### Pair a Mac and iPhone in the Mac host app

In Xcode, choose the **HerdrWatchHost** scheme and run it on your Mac. The
menu-bar app can create the pairing QR, start or stop the relay, and show
whether the paired iPhone is connected. Scan the QR in HerdrWatch → Computers →
Add computer, then start the relay in the Mac app. You do not need to keep a
Terminal window open.

The companion CLI remains available for setup and troubleshooting. Build
`services/host/` for macOS or Windows, then run:

```sh
herdrwatch-host relay init --endpoint wss://herdrwatch-relay.<account>.workers.dev
```

In HerdrWatch, open Computers → Add computer and scan the QR
shown in the terminal (or expand **Paste pairing code instead**). On Mac, enter
the SSH username and password and enable Remote Login. Tap **Save and connect**
when ready, and start the local companion:

```sh
herdrwatch-host relay run
```

Keep it running while connected. The companion and app can be anywhere with
internet access; neither needs Cloudflare One/WARP or a Cloudflare login. On
macOS the phone verifies the SSH host fingerprint on first connection. On
Windows, pairing uses the direct Herdr bridge; no SSH server, inbound port or
firewall rule is needed. In both flows the pairing secret grants access to the
paired host, so treat the code like a password and re-pair if it is exposed.

SwiftUI iPhone app with multiple saved Herdr connections. It discovers sessions
and agents, reads terminal screens, and can send an explicit instruction to a
detected agent. The Mac path uses SSH; the Windows path uses an encrypted direct
bridge with upstream Herdr. The shared relay is an optional Cloudflare Worker
deployed once by the HerdrWatch publisher.

## Host manager scope

The Go CLI in [services/host/](services/host/README.md) targets macOS and Windows. The native SwiftUI menu-bar app is in `apps/macos-host/`. The cross-platform Tauri manager in [apps/desktop/](apps/desktop/README.md) is the Windows desktop path and also runs on macOS. Both managers show relay state and can create the phone pairing QR.
The older Cloudflare Tunnel mode remains available for people who already use
Cloudflare One/WARP.

## Desktop downloads

Download the latest [HerdrWatch Host release](https://github.com/mberrishdev/herdr-watch/releases/latest). It includes a universal DMG for Apple Silicon and Intel Macs and a full Windows x64 setup installer. The Windows installer is an NSIS setup wizard, not a standalone app executable. Windows requires Herdr installed for the same account; OpenSSH Server is not required.

On macOS, install the latest stable release with `./install.sh`, or choose the
latest published beta, alpha, or release candidate with `./install.sh --beta`.
The script downloads and verifies the release DMG, then installs the app under
`~/Applications`.

## Repository layout

- `apps/ios/` — iPhone app and UI preview fixture.
- `apps/macos-host/` — native Mac menu-bar host manager.
- `apps/desktop/` — Tauri manager for Windows and macOS.
- `services/host/` — Go companion and relay client.
- `services/relay/` — shared Cloudflare Worker.
- `research/` and `output/` — local-only research and generated notes; ignored by Git.

## Build

Open `HerdrWatch.xcodeproj`, select `HerdrWatch`, select your signing team for a physical device (device signing is automatic; simulator and preview builds remain unsigned). Or compile without signing:

```sh
xcodebuild -project HerdrWatch.xcodeproj -scheme HerdrWatch -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath .build build
```

`project.yml` is the XcodeGen source. Regenerate with `xcodegen generate`. Citadel is pinned to `ae8562f895de06ccb86fdb1cbb65fd99c8976e12`; transitive dependencies are locked by the checked-in `Package.resolved`.

The **HerdrWatchHost** scheme builds the Mac menu-bar manager from `apps/macos-host/` and embeds a universal Go companion for Apple Silicon and Intel Macs. Building that target requires Go and Xcode's `lipo` tool.

## Connect

Open **Computers → Add computer** to save a named direct SSH or
encrypted relay connection. Use **Switch computer** on the dashboard or
tap a computer in **Computers** to change the active host. Use the info button
to edit a computer, or swipe to remove it. The existing single-host setting
migrates automatically.
Switching clears sessions and terminal output before connecting to the next host.
Passwords, relay secrets and trusted keys keep their existing device Keychain
scopes. Removing a saved connection retains these credentials; use the active
connection’s advanced settings to delete its password or forget its trusted key.

1. Install HerdrWatch Host and follow [the shared relay setup](#shared-relay-no-vpn-app-on-iphone). Scan its pairing QR in **Computers → Add computer**. This uses the publisher's relay and does not require a phone VPN.
2. On Mac, enter your SSH username and password, then verify the SSH host-key fingerprint through an independent channel. On Windows, HerdrWatch Host talks to Herdr for the signed-in user; SSH credentials and host-key trust are not used.
3. Choose a running session. Refresh manually or leave the app active for 15-second foreground polling. Tap an agent row to open its real terminal screen.

On the Mac SSH path, unknown keys abort before authentication and changed keys fail closed. Passwords and trusted public keys use non-synchronizing `WhenUnlockedThisDeviceOnly` Keychain records. On Windows, the pairing secret encrypts each API request and response end to end; the relay forwards ciphertext only. The inline agent input is available by default; each send is explicit. No output or snapshot is persisted, and no credentials or host output are logged.

On macOS/Linux, the fixed SSH launcher prepends `$HOME/.local/bin`, `/opt/homebrew/bin`, and `/usr/local/bin` to the remote PATH before executing `herdr`. It does not load interactive shell startup files or accept an arbitrary executable/command.

Runtime detection prefers `herdr-core` when installed; otherwise it probes the upstream `herdr` bridge. The desktop profile supports the **default core session** and verifies the running server's generation, version and required methods with `hello`. It reads `terminal.list` and the desktop app's `herdr-app` layout via `doc.get`, reconstructing workspace/tab/pane locations. Live terminals absent from that document appear in a clearly labeled "Other live terminals" group. Shells without an agent status or recognized agent process are not counted as agents. The core's standard default-session socket must already exist; this app never runs a server-start command. Other core versions and named core sessions remain outside this profile.

Reads use runtime probing, core JSON-RPC reads plus `terminal.read`, upstream `agent.read`, bridge probing, `herdr session list --json`, and `session.snapshot`. Named sessions use a strict argument allowlist. Sends use one explicit `agent.prompt` or `terminal.send` request for a freshly revalidated detected agent. Idle and Done agents can receive prompts; blocked agents cannot. Desktop core sends to Idle with `if: idle`, and sends to Done after a fresh status check with `force: false` (the core schema has no atomic Done condition). There is no generic command/key API or blocked-agent override. Each request uses a fresh non-PTY exec channel and JSON on stdin, never shell interpolation. Response buffering is capped at 1 MiB; stderr is discarded with an 8 KiB limit; a 15-second deadline closes the connection. Submission acknowledgement does not mean task completion. Delivery without an acknowledgement is marked uncertain and is never retried automatically; inspect the agent before sending again.

## Validation

`HerdrWatchPreview` is a macOS target sharing the iPhone sources so Atlas can inspect UI when Simulator.app is unavailable. A Debug-only `HERDRWATCH_PREVIEW=1` launch environment selects a clearly labeled, deterministic sample transport; release builds always use Citadel. This fixture is not a live SSH test.

```sh
xcodebuild -project HerdrWatch.xcodeproj -scheme HerdrWatchPreview -derivedDataPath .build test
```

The preview fixture is not a live SSH test. Physical iPhone networking, device Keychain behavior, real host authentication, and remote bridge behavior on each intended OS remain release acceptance gates. Each profile deliberately rejects unvalidated versions/generations. Approval controls and background monitoring are not included.

## Agent screen

Tap **Open session** on an agent row. The detail view polls every five seconds while visible and active. Desktop core reads use `terminal.read` with zero history lines, so they do not scroll the laptop terminal or send keystrokes. The upstream profile reads up to 100 recent lines. Reads revalidate the host, session, current agent location and desktop core identity; a changed target is rejected. The response has the transport's 1 MiB limit, terminal controls are removed, and the display is capped at the newest 32 KiB with visible partial/truncation notices. Text is inert and selectable; output is held only in the view's memory and cleared when leaving/inactive.

Agent output defaults to readable formatting with prose, headings, lists and fenced code shown as distinct blocks. Text is selectable, terminal-provided links remain inert, and code stays monospaced with horizontal scrolling when needed. The **Aa** menu changes text size or switches to raw terminal formatting. Session metadata is available under **Session details**.

A Debug-only `HERDRWATCH_CORE_PREVIEW=1` alongside `HERDRWATCH_PREVIEW=1` selects sample desktop data. Add `HERDRWATCH_OUTPUT_PREVIEW=1` to open the sample terminal detail directly for visual checks. Add `HERDRWATCH_PROMPT_PREVIEW=1` to show a synthetic eligible agent; sending only receives a local sample acknowledgement. These flags do not connect to a real host and are ignored by release builds.
