# HerdrWatch desktop host manager

The Tauri app provides the host pairing QR, relay start/stop, live connection
status and basic activity. It bundles the Go companion, so end users do not
need to install Go. The same desktop manager can be built for Windows and
macOS; the native SwiftUI menu-bar manager remains available for Mac users.

## Automatic updates

The Windows Tauri manager checks GitHub Releases at startup, when it returns
to the foreground, and every four hours. It shows an update banner and installs
the signed NSIS update package after you choose **Install**. Release builds require the
`TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`, and
`TAURI_SIGNING_PUBLIC_KEY` GitHub Actions secrets.

The header shows the installed application version, including prerelease suffixes
such as `0.1.1-beta.5`. Stable builds check the latest stable release's
`latest.json`. Beta, alpha, and release candidate builds check the rolling
`updates-beta` release's `latest.json`, which the release workflow updates after
publishing each prerelease. That metadata points to the signed installer in the
versioned release. Older builds with the stable feed built in need a manual
installer update once to switch to the prerelease feed. The old stable v0.1.0
release has no updater metadata; a new signed stable release is needed to make
its stable feed available.

The native macOS host uses Sparkle to check for updates automatically and
shows its standard install prompt when a signed update is available. You can
also choose **Check for Updates…** in the host manager or menu bar popover.
Updates are signed with Sparkle EdDSA and the feed and archive signatures are
verified before installation. Automatic installation is off; you choose when
to install an offered update.

The release workflow requires these GitHub Actions secrets:

- Windows/Tauri: `TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`,
  and `TAURI_SIGNING_PUBLIC_KEY`.
- macOS: `SPARKLE_EDDSA_PRIVATE_KEY`. The matching public key is embedded in
  the native host app. The Mac app is still not Apple code-signed or notarized,
  so Gatekeeper may show a warning on first launch.

The already published macOS v0.1.0 app does not contain Sparkle. Install a
later DMG manually once; that version can then update itself from future GitHub
releases.

## Windows host requirements

- Windows 10/11 with WebView2 Runtime.
- Herdr installed for the signed-in Windows account and `herdr` available in
  that account's PATH. The manager checks `herdr remote-api-bridge --check`.
- No OpenSSH Server, inbound firewall rule, or Windows service is required.

Windows pairing uses protocol v2: the iPhone and bundled Go companion exchange
AES-GCM encrypted Herdr requests over the shared relay. The companion invokes
only a fixed set of Herdr API operations locally; it does not accept shell
commands from the phone. The relay sees connection timing and traffic size,
but not the request or response payloads. The Mac manager continues to use the
SSH relay profile.

## Build on Windows

Install Node.js 22+, Go 1.23+, Rust stable, and the Microsoft C++ Build Tools
with the Windows 10/11 SDK. Then run from this directory:

```powershell
npm ci
npm run tauri:dev
```

To build an installer:

```powershell
npm run tauri:build
```

The NSIS installer is written under `src-tauri/target/release/bundle/nsis/`.
The build compiles the Go companion for the active Windows architecture and
includes it as a Tauri sidecar.

## Build on macOS

Install Node.js 22+, Go 1.23+, Rust stable, and Xcode Command Line Tools. Run
`npm ci` and `npm run tauri:dev` here to preview the cross-platform manager.
The existing native menu-bar app is still built with the root Xcode project.

The desktop UI calls a short list of Rust commands that invoke the bundled
companion. The frontend receives no general shell execution permission. The
pairing secret is displayed only in the QR while the pairing view is open and
is stored by the companion in the operating system credential store.
