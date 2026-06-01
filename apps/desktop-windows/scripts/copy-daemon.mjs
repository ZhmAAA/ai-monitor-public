import { copyFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, "../../..");
const source = resolve(repoRoot, "target/debug/ai-monitor-daemon.exe");
const destination = resolve(
  scriptDir,
  "../src-tauri/resources/ai-monitor-daemon.exe",
);

if (!existsSync(source)) {
  throw new Error(`Daemon executable not found: ${source}`);
}

mkdirSync(dirname(destination), { recursive: true });
copyFileSync(source, destination);
console.log(`Copied daemon sidecar to ${destination}`);
