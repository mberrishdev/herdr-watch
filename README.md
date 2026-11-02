# HerdrWatch

Small SwiftUI iPhone MVP for one existing SSH host. It discovers Herdr sessions and agents, reads live terminal screens, and provides an inline field to send an explicit instruction to a detected agent. Requires iOS 17+, ordinary SSH password authentication, and either **Herdr desktop / herdr-core 0.1.16 (generation 1)** or **upstream Herdr 0.9.5 (protocol 22)** on the remote SSH PATH. No server component or cloud backend is added.

## Build

Open `HerdrWatch.xcodeproj`, select `HerdrWatch`, select your signing team for a physical device (device signing is automatic; simulator and preview builds remain unsigned). Or compile without signing:

```sh
xcodebuild -project HerdrWatch.xcodeproj -scheme HerdrWatch -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath .build build
```

`project.yml` is the XcodeGen source. Regenerate with `xcodegen generate`. Citadel is pinned to `ae8562f895de06ccb86fdb1cbb65fd99c8976e12`; transitive dependencies are locked by the checked-in `Package.resolved`.

## Connect

1. Open Host settings and enter the SSH hostname/IP, port and username. The app doesn't configure Tailscale; establish your private-network route separately.
2. Enter your SSH password. Passwords are saved only in device-only Keychain, scoped to host, port and username. The SSH server must allow password authentication; keyboard-interactive/MFA login is not implemented. SSH credentials grant your host account's authority.
3. Save, connect, and compare the displayed host-key SHA-256 fingerprint using an independent trusted channel before trusting it. For example, inspect the relevant host public key with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256` on the host.
4. Choose a running session. Refresh manually or leave the app active for 15-second foreground polling. Tap an agent row to open its real terminal screen.

Unknown host keys abort the handshake before authentication and require explicit trust plus a new connection. Changed keys fail closed; independently verify rotation before using Forget trusted host key. Passwords and exact trusted public keys use non-synchronizing `WhenUnlockedThisDeviceOnly` Keychain records. Host address/port/username alone use preferences. The inline agent input is available by default; each send is explicit. No output/snapshot is persisted, no credentials or host output are logged, and no agent forwarding is enabled. Delete saved SSH password removes the locally stored password.

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
