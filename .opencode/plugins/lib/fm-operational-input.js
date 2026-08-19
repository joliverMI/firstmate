import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const adapterRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

// Cross-language adapter only. bin/fm-operational-input.sh owns the protocol,
// accepted kinds, marker bytes, and serialization grammar.
export function encodeFirstmateOperationalInput(root, kind, content) {
  return new Promise((resolveResult, reject) => {
    const requested = `${root}/bin/fm-operational-input.sh`;
    const script = existsSync(requested)
      ? requested
      : `${adapterRoot}/bin/fm-operational-input.sh`;
    const child = spawn(script, ["encode", kind], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0 && stdout) {
        resolveResult(stdout);
        return;
      }
      reject(new Error(stderr.trim() || `operational-input encoder exited ${code ?? "unknown"}`));
    });
    // A child that exits before this write lands makes the write fail with
    // EPIPE, which node raises on the stdin stream rather than on the child.
    // Unhandled, that stream error throws and takes the whole process down.
    // The child's own error/close handlers already settle this promise, so a
    // child that no longer wants its input needs nothing further here.
    child.stdin.on("error", () => {});
    child.stdin.end(content);
  });
}
