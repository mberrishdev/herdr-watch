import { mkdir } from "node:fs/promises";
import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const hostRoot = resolve(root, "../../services/host");
const triple = process.env.TAURI_ENV_TARGET_TRIPLE || await rustHost();
const targets = {
  "aarch64-apple-darwin": ["darwin", "arm64", ""],
  "x86_64-apple-darwin": ["darwin", "amd64", ""],
  "x86_64-pc-windows-msvc": ["windows", "amd64", ".exe"],
  "aarch64-pc-windows-msvc": ["windows", "arm64", ".exe"],
};
const target = targets[triple];
if (!target) throw new Error(`Unsupported desktop target ${triple}; supported targets: ${Object.keys(targets).join(", ")}`);
const [goos, goarch, extension] = target;
const output = resolve(root, `src-tauri/binaries/herdrwatch-host-${triple}${extension}`);
await mkdir(dirname(output), { recursive: true });
await new Promise((ok, fail) => {
  const child = spawn("go", ["build", "-trimpath", "-o", output, "./cmd/herdrwatch-host"], {
    cwd: hostRoot,
    stdio: "inherit",
    env: { ...process.env, GOOS: goos, GOARCH: goarch, CGO_ENABLED: "0" },
  });
  child.on("error", fail);
  child.on("exit", (code) => code === 0 ? ok() : fail(new Error(`Go sidecar build exited with status ${code}`)));
});
console.log(`Built ${output}`);

async function rustHost() {
  return await new Promise((ok, fail) => {
    const child = spawn("rustc", ["--print", "host-tuple"], { stdio: ["ignore", "pipe", "inherit"] });
    let output = "";
    child.stdout.setEncoding("utf8").on("data", (chunk) => output += chunk);
    child.on("error", fail);
    child.on("exit", (code) => code === 0 ? ok(output.trim()) : fail(new Error("Could not determine Rust host target")));
  });
}
