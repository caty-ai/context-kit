#!/usr/bin/env node
/** Require explicit private/public intent and block public GitHub repositories. */

function readStdin(timeoutMs = 2000) {
  return new Promise((resolve) => {
    const chunks = [];
    let settled = false;

    const timeout = setTimeout(() => {
      if (!settled) {
        settled = true;
        process.stdin.removeAllListeners();
        process.stdin.destroy();
        resolve(Buffer.concat(chunks).toString("utf-8"));
      }
    }, timeoutMs);

    process.stdin.on("data", (chunk) => {
      chunks.push(chunk);
    });

    process.stdin.on("end", () => {
      if (!settled) {
        settled = true;
        clearTimeout(timeout);
        resolve(Buffer.concat(chunks).toString("utf-8"));
      }
    });

    process.stdin.on("error", () => {
      if (!settled) {
        settled = true;
        clearTimeout(timeout);
        resolve("");
      }
    });

    if (process.stdin.readableEnded && !settled) {
      settled = true;
      clearTimeout(timeout);
      resolve(Buffer.concat(chunks).toString("utf-8"));
    }
  });
}

async function main() {
  const safetyTimeout = setTimeout(() => {
    try { process.exit(0); } catch { /* ignore */ }
  }, 8000);

  try {
    if (process.env.CK_PUBLIC_REPO_OK === "1") {
      clearTimeout(safetyTimeout);
      process.exit(0);
    }

    const input = await readStdin();
    let data = {};
    try {
      data = JSON.parse(input);
    } catch {
      clearTimeout(safetyTimeout);
      process.exit(0);
    }

    if (data.tool_name !== "Bash") {
      clearTimeout(safetyTimeout);
      process.exit(0);
    }

    const cmd = (data.tool_input || {}).command || "";
    if (!cmd || typeof cmd !== "string") {
      clearTimeout(safetyTimeout);
      process.exit(0);
    }

    if (/(?:^|[\s;])CK_PUBLIC_REPO_OK=1\b/.test(cmd)) {
      clearTimeout(safetyTimeout);
      process.exit(0);
    }

    if (/\bgh\s+repo\s+create\b/.test(cmd) && /--public\b/.test(cmd)) {
      process.stderr.write(
        "[private-repo-enforcer] Blocked explicit public repository creation.\n"
        + "  This environment defaults to private repositories.\n"
        + "  If public creation is intentional, prefix the same Bash command with CK_PUBLIC_REPO_OK=1.\n"
        + `  Command: ${cmd}\n`
      );
      clearTimeout(safetyTimeout);
      process.exit(2);
    }

    if (/\bgh\s+repo\s+create\b/.test(cmd) && !/--private\b/.test(cmd) && !/--public\b/.test(cmd)) {
      process.stderr.write(
        "[private-repo-enforcer] Blocked repository creation without explicit visibility.\n"
        + "  Specify either `--private` or `--public`.\n"
        + "  This environment defaults to `--private`.\n"
        + `  Command: ${cmd}\n`
      );
      clearTimeout(safetyTimeout);
      process.exit(2);
    }

    if (/\bgh\s+repo\s+edit\b/.test(cmd) && /--visibility\s+public\b/.test(cmd)) {
      process.stderr.write(
        "[private-repo-enforcer] Blocked changing a repository to public.\n"
        + "  This environment defaults to private repositories.\n"
        + "  If this visibility change is intentional, prefix the same Bash command with CK_PUBLIC_REPO_OK=1.\n"
        + `  Command: ${cmd}\n`
      );
      clearTimeout(safetyTimeout);
      process.exit(2);
    }
  } catch (err) {
    try { process.stderr.write(`[private-repo-enforcer] Error: ${err?.message || err}\n`); } catch { /* ignore */ }
  }

  clearTimeout(safetyTimeout);
  process.exit(0);
}

process.on("uncaughtException", (err) => {
  try { process.stderr.write(`[private-repo-enforcer] Uncaught: ${err?.message || err}\n`); } catch { /* ignore */ }
  process.exit(0);
});

process.on("unhandledRejection", (err) => {
  try { process.stderr.write(`[private-repo-enforcer] Rejection: ${err?.message || err}\n`); } catch { /* ignore */ }
  process.exit(0);
});

main();
