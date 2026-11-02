# HerdrWatch desktop host manager

The Tauri app provides the host pairing QR, relay start/stop, live connection
status and basic activity. It bundles the Go companion, so end users do not
need to install Go. The same desktop manager can be built for Windows and
macOS; the native SwiftUI menu-bar manager remains available for Mac users.

## Windows host requirements

- Windows 10/11 with WebView2 Runtime.
- The optional **OpenSSH Server** Windows feature enabled and its `sshd`
  service running. HerdrWatch does not install Windows services or change
  firewall rules for you.
- Herdr installed for the Windows account that owns the SSH connection, and
  available on the SSH command PATH.

The app guides relay pairing, but the Windows Herdr session and agent bridge
has not yet been validated against every Herdr distribution. The current
mobile SSH profile is validated on macOS/Linux hosts; Windows end-to-end
session discovery remains an acceptance item.

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
