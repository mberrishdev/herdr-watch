import QRCode from "qrcode";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { check } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import "./style.css";

type Status = { configured: boolean; endpoint?: string };
type SshReadiness = { openSshInstalled: boolean; sshdRunning: boolean; firewallReady: boolean; herdrAvailable: boolean };
type ViewState = "setup" | "stopped" | "connecting" | "ready" | "connected" | "error";

const endpointDefault = "wss://herdrwatch-relay.herdrwatch-relay.workers.dev";
const root = document.querySelector<HTMLDivElement>("#app")!;
let viewState: ViewState = "setup";
let endpoint = endpointDefault;
let pairingCode = "";
let busy = false;
let errorMessage = "";
let activity = ["Host manager started."];
let unlisten: UnlistenFn | undefined;
let updateMessage = "";
let updateAvailable = false;
let updateChecking = false;
let updateStatus = "";
let sshReadiness: SshReadiness | null = null;
let sshBusy = false;
const isWindows = navigator.userAgent.includes("Windows");

function esc(value: string) {
  return value.replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]!);
}

function titleForState() {
  return ({ setup: "Finish setup", stopped: "Relay is stopped", connecting: "Connecting securely", ready: "Ready for your iPhone", connected: "iPhone is connected", error: "Needs attention" } as const)[viewState];
}
function descriptionForState() {
  return ({
    setup: "Pair this computer once. Your iPhone will use the same encrypted SSH flow as before.",
    stopped: "The host is paired. Start the relay when you want to connect from HerdrWatch.",
    connecting: "The host is reaching HerdrWatch’s relay. This window can stay open in the background.",
    ready: "The encrypted relay is online and waiting for your iPhone.",
    connected: "Your iPhone reached this computer. SSH and agent traffic stay encrypted end to end.",
    error: errorMessage || "The companion could not start. Check the relay setup and try again.",
  } as const)[viewState];
}

function renderWindowsSetup() {
  if (!isWindows) return "";
  const checks = [
    ["OpenSSH Server", sshReadiness?.openSshInstalled, "Install it from Windows Settings → Optional features."],
    ["SSH service", sshReadiness?.sshdRunning, "Start the `sshd` service in an administrator PowerShell."],
    ["Windows Firewall", sshReadiness?.firewallReady, "Allow the OpenSSH Server rule through Windows Firewall."],
    ["Herdr", sshReadiness?.herdrAvailable, "Install Herdr for this Windows user and ensure it is on PATH."],
  ] as const;
  const ready = sshReadiness && checks.every(([, passed]) => passed);
  return `<section class="card setup-card"><div class="status-header"><div><span class="section-kicker">WINDOWS READINESS</span><h2>${ready ? "Ready to connect" : "Finish Windows setup"}</h2></div><button class="quiet" id="check-ssh" ${sshBusy ? "disabled" : ""}>${sshBusy ? "Checking…" : "Check again"}</button></div><p class="setup-intro">HerdrWatch needs local SSH access before the encrypted relay can start.</p><div class="check-list">${checks.map(([name, passed, help]) => `<div class="check-row ${passed ? "passed" : ""}"><span class="check-icon">${passed ? "✓" : "!"}</span><div><b>${name}</b><span>${passed ? "Configured" : esc(help)}</span></div></div>`).join("")}</div></section>`;
}

function render() {
  root.innerHTML = `
    <main class="shell">
      <header class="topbar">
        <div class="brand"><div class="brand-mark"><img src="/herdr-mark.png" alt="" /></div><div><strong>HerdrWatch</strong><span>HOST MANAGER</span></div></div>
        <span class="platform">${isWindows ? "WINDOWS" : "DESKTOP"}</span>
      </header>
      <section class="hero">
        <div class="eyebrow"><span class="pulse ${viewState}"></span> PRIVATE CONNECTION</div>
        <h1>${esc(titleForState())}</h1>
        <p>${esc(descriptionForState())}</p>
      </section>
      ${errorMessage ? `<div class="error"><span>!</span><div>${esc(errorMessage)}</div><button id="clear-error" aria-label="Dismiss">×</button></div>` : ""}
      ${updateAvailable ? `<div class="update"><span>↻</span><div>${esc(updateMessage || "A new version is ready.")}</div><button id="install-update">Install</button></div>` : ""}
      ${renderWindowsSetup()}
      <section class="card pairing-card">
        <div class="card-heading"><div class="step-icon">${viewState === "setup" ? "01" : "✓"}</div><div><h2>Connect your iPhone</h2><p>Pair once, then start the encrypted relay.</p></div></div>
        ${pairingCode ? `<div class="pairing-preview"><div class="qr-wrap"><canvas id="qr" width="200" height="200"></canvas></div><div class="pairing-info"><span class="tag">PAIRING CODE READY</span><h3>Scan with HerdrWatch</h3><p>On iPhone: <b>Settings → Connection → Encrypted relay → Scan QR</b></p><button class="text-button" id="hide-qr">Hide QR code</button></div></div>` : `
          <label class="field-label" for="endpoint">Relay address</label>
          <div class="input-wrap"><span class="lock">⌁</span><input id="endpoint" value="${esc(endpoint)}" spellcheck="false" autocomplete="url" ${busy ? "disabled" : ""} /></div>
          <div class="actions"><button class="primary" id="pair" ${busy ? "disabled" : ""}>${busy ? `<span class="spinner"></span> Creating secure code…` : `Create pairing QR <span>→</span>`}</button>${viewState !== "setup" ? `<button class="secondary" id="show-qr">Show QR</button>` : ""}</div>
        `}
        ${pairingCode ? `<div class="pair-actions"><button class="primary" id="done-pairing">Done</button><button class="secondary" id="hide-qr-2">Close</button></div>` : ""}
      </section>
      <section class="card status-card">
        <div class="status-header"><div><span class="section-kicker">HOST STATUS</span><h2>${viewState === "connected" ? "Your iPhone can reach this host" : "Encrypted relay"}</h2></div><span class="status-badge ${viewState}"><i></i>${viewState === "setup" ? "NOT PAIRED" : viewState.toUpperCase()}</span></div>
        <div class="status-detail"><div class="status-icon">${viewState === "connected" ? "↔" : "⌁"}</div><div><b>${viewState === "setup" ? "Not connected yet" : viewState === "connected" ? "iPhone connected" : "HerdrWatch relay"}</b><span>${viewState === "setup" ? "Create a pairing code to begin" : esc(endpoint.replace(/^wss:\/\//, ""))}</span></div></div>
        <div class="status-actions">${viewState === "ready" || viewState === "connected" || viewState === "connecting" ? `<button class="secondary danger" id="stop">Stop relay</button>` : `<button class="primary" id="start" ${busy || viewState === "setup" || (isWindows && (!sshReadiness || !sshReadiness.openSshInstalled || !sshReadiness.sshdRunning || !sshReadiness.firewallReady || !sshReadiness.herdrAvailable)) ? "disabled" : ""}>Start relay</button>`}<button class="quiet" id="refresh">Refresh status</button></div>
      </section>
      <details class="activity"><summary><span>Recent activity</span><span class="activity-count">${activity.length}</span></summary><div class="activity-lines">${activity.slice(-6).reverse().map((line) => `<div><i></i>${esc(line)}</div>`).join("")}</div></details>
      <footer><span>🔒 SSH stays encrypted between this computer and your iPhone.</span><div class="footer-actions"><span>Credentials stay on this device.</span><button class="text-button" id="check-updates" ${updateChecking ? "disabled" : ""}>${updateChecking ? "Checking…" : "Check for updates"}</button></div>${updateStatus ? `<span class="update-status">${esc(updateStatus)}</span>` : ""}</footer>
    </main>`;

  const endpointInput = document.querySelector<HTMLInputElement>("#endpoint");
  endpointInput?.addEventListener("input", () => endpoint = endpointInput.value);
  document.querySelector("#pair")?.addEventListener("click", createPairing);
  document.querySelector("#start")?.addEventListener("click", startRelay);
  document.querySelector("#stop")?.addEventListener("click", stopRelay);
  document.querySelector("#refresh")?.addEventListener("click", refreshStatus);
  document.querySelector("#show-qr")?.addEventListener("click", revealPairing);
  document.querySelector("#hide-qr")?.addEventListener("click", hidePairing);
  document.querySelector("#hide-qr-2")?.addEventListener("click", hidePairing);
  document.querySelector("#done-pairing")?.addEventListener("click", async () => { hidePairing(); await startRelay(); });
  document.querySelector("#clear-error")?.addEventListener("click", () => { errorMessage = ""; render(); });
  document.querySelector("#install-update")?.addEventListener("click", installUpdate);
  document.querySelector("#check-updates")?.addEventListener("click", () => checkForUpdates(true));
  document.querySelector("#check-ssh")?.addEventListener("click", checkSshReadiness);
  const canvas = document.querySelector<HTMLCanvasElement>("#qr");
  if (canvas && pairingCode) QRCode.toCanvas(canvas, pairingCode, { width: 200, margin: 1, color: { dark: "#15233c", light: "#ffffff" }, errorCorrectionLevel: "M" });
}

async function checkForUpdates(showResult = false) {
  if (updateChecking || (updateAvailable && !showResult)) return;
  updateChecking = true;
  let shouldRender = showResult;
  if (showResult) { updateStatus = "Checking GitHub releases…"; render(); }
  try {
    const update = await check();
    if (update) {
      updateAvailable = true;
      updateMessage = `HerdrWatch ${update.version} is available.`;
      updateStatus = "";
      shouldRender = true;
    } else if (showResult) {
      updateAvailable = false;
      updateStatus = "You’re up to date.";
      render();
    }
  } catch (error) {
    activity.push(`Update check failed: ${String(error)}`);
    if (showResult) {
      updateAvailable = false;
      updateStatus = "Could not check for updates. Try again later.";
      render();
    }
  } finally {
    updateChecking = false;
    if (shouldRender) render();
  }
}

async function installUpdate() {
  try {
    updateMessage = "Downloading update…";
    render();
    const update = await check();
    if (!update) {
      updateAvailable = false;
      render();
      return;
    }
    await update.downloadAndInstall();
    await relaunch();
  } catch (error) {
    updateAvailable = false;
    errorMessage = `The update could not be installed: ${String(error)}`;
    render();
  }
}

async function checkSshReadiness() {
  if (!isWindows) return;
  sshBusy = true;
  render();
  try {
    sshReadiness = await invoke<SshReadiness>("ssh_readiness");
    addActivity("Checked Windows SSH readiness.");
  } catch (error) {
    errorMessage = `Windows readiness check failed: ${String(error)}`;
  } finally {
    sshBusy = false;
    render();
  }
}

async function refreshStatus() {
  try {
    const status = await invoke<Status>("relay_status");
    if (status.endpoint) endpoint = status.endpoint;
    if (status.configured && viewState === "setup") viewState = "stopped";
    if (!status.configured && viewState !== "connecting" && viewState !== "connected") viewState = "setup";
    errorMessage = "";
  } catch (error) { errorMessage = String(error); viewState = "error"; }
  render();
}
async function createPairing() {
  const input = document.querySelector<HTMLInputElement>("#endpoint");
  if (input) endpoint = input.value.trim();
  if (!endpoint.startsWith("wss://")) { errorMessage = "The relay address must start with wss://."; render(); return; }
  busy = true; errorMessage = ""; render();
  try { pairingCode = await invoke<string>("create_pairing", { endpoint }); viewState = "stopped"; addActivity("Created a new iPhone pairing code."); }
  catch (error) { errorMessage = String(error); }
  finally { busy = false; render(); }
}
async function revealPairing() {
  busy = true; render();
  try { pairingCode = await invoke<string>("show_pairing"); errorMessage = ""; }
  catch (error) { errorMessage = String(error); }
  finally { busy = false; render(); }
}
function hidePairing() { pairingCode = ""; render(); }
async function startRelay() {
  busy = true; errorMessage = ""; viewState = "connecting"; addActivity("Connecting to the shared relay…"); render();
  try { await invoke("start_relay"); }
  catch (error) { errorMessage = String(error); viewState = "error"; }
  finally { busy = false; render(); }
}
async function stopRelay() {
  try { await invoke("stop_relay"); viewState = "stopped"; addActivity("Relay stopped."); }
  catch (error) { errorMessage = String(error); viewState = "error"; }
  render();
}
function addActivity(line: string) { activity.push(line); if (activity.length > 20) activity.shift(); }

render();
void refreshStatus();
void checkSshReadiness();
void checkForUpdates();
window.setInterval(() => void checkForUpdates(), 4 * 60 * 60 * 1000);
window.addEventListener("focus", () => void checkForUpdates());
void listen<string>("relay-event", ({ payload }) => {
  const separator = payload.indexOf(":");
  const kind = payload.slice(0, separator);
  const line = payload.slice(separator + 1).trim();
  if (kind === "terminated") { viewState = "stopped"; addActivity("Relay companion stopped."); }
  else if (line.includes("HerdrWatch connected")) { viewState = "connected"; addActivity("iPhone connected to the host."); }
  else if (line.includes("Relay connected; waiting")) { viewState = "ready"; addActivity("Relay is online and ready for the iPhone."); }
  else if (line.includes("relay disconnected:")) { viewState = "connecting"; addActivity(line); }
  else if (line.includes("HerdrWatch relay is connecting")) addActivity("Connecting to the shared relay…");
  else if (kind === "stderr" && line) { errorMessage = line; }
  render();
}).then((fn) => unlisten = fn);
window.addEventListener("beforeunload", () => { unlisten?.(); });
