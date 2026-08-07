#!/usr/bin/env node
/** Block API-key patterns in Bash, Write, and Edit tool inputs. */

import { chmodSync, existsSync, mkdirSync, writeFileSync } from "fs";
import { join, resolve } from "path";

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

function resolveScratchDir() {
  if (process.env.CK_SCRATCH_DIR) {
    return { scratchDir: resolve(process.env.CK_SCRATCH_DIR), isDefault: false };
  }

  if (process.env.HOME) {
    return {
      scratchDir: resolve(
        join(
          process.env.HOME,
          ".claude",
          "scratch",
          process.env.CK_AGENT || "agent",
          "memory"
        )
      ),
      isDefault: true,
    };
  }

  return {
    scratchDir: resolve(join(process.env.TMPDIR || "/tmp", "context-kit-scratch")),
    isDefault: true,
  };
}

// (pattern, name, description)
const API_KEY_PATTERNS = [
  { pattern: /sk-ant-[A-Za-z0-9\-_]{20,}/, name: "Anthropic API Key", prefix: "sk-ant-" },
  { pattern: /sk-[A-Za-z0-9]{20,}/, name: "OpenAI API Key", prefix: "sk-" },
  { pattern: /AIza[0-9A-Za-z_\-]{35}/, name: "Google API Key", prefix: "AIza" },
  { pattern: /AKIA[0-9A-Z]{16}/, name: "AWS Access Key ID", prefix: "AKIA" },
  { pattern: /glpat-[A-Za-z0-9_\-]{20,}/, name: "GitLab PAT", prefix: "glpat-" },
  { pattern: /gh[pousr]_[A-Za-z0-9]{36,}/, name: "GitHub Token", prefix: "gh[pousr]_" },
  { pattern: /xox[bpoars]-[A-Za-z0-9\-]{10,}/, name: "Slack Token", prefix: "xox[bpoars]-" },
];

function scanForKeys(text) {
  if (!text || typeof text !== "string") return [];
  const detections = [];
  for (const { pattern, name } of API_KEY_PATTERNS) {
    const match = pattern.exec(text);
    if (match) {
      const raw = match[0];
      const redacted = raw.length > 8 ? raw.slice(0, 8) + "***[REDACTED]" : "***[REDACTED]";
      detections.push({ name, redacted });
    }
  }
  return detections;
}

function writeScratchReport(toolName, filePath, detections) {
  try {
    const { scratchDir, isDefault } = resolveScratchDir();
    if (!existsSync(scratchDir)) {
      mkdirSync(scratchDir, {
        recursive: true,
        ...(isDefault ? { mode: 0o700 } : {}),
      });
    }
    if (isDefault) {
      chmodSync(scratchDir, 0o700);
    }

    const ts = new Date().toISOString().replace(/[:.]/g, "-");
    const scratchPath = join(scratchDir, `api-key-leak-${ts}.md`);
    const lines = [
      "# API Key Leak Detection Report",
      "",
      `- **Detected at**: ${new Date().toISOString()}`,
      `- **Tool**: ${toolName}`,
      filePath ? `- **File**: ${filePath}` : null,
      "",
      "## Detected Patterns",
      "",
      ...detections.map((detection) => `- **${detection.name}**: \`${detection.redacted}\``),
      "",
      "## Action Required",
      "",
      "1. Remove the API key from the content immediately.",
      "2. If the key may have been exposed, rotate it from the provider dashboard.",
      "3. If this is a false positive, set `CK_API_KEY_DETECT_DISABLED=1` in the hook environment.",
    ].filter((line) => line !== null);
    writeFileSync(scratchPath, lines.join("\n") + "\n", {
      encoding: "utf8",
      flag: "wx",
      mode: 0o600,
    });
    return scratchPath;
  } catch {
    return null;
  }
}

async function main() {
  const safetyTimeout = setTimeout(() => {
    try { process.exit(0); } catch { /* ignore */ }
  }, 8000);

  try {
    if (process.env.CK_API_KEY_DETECT_DISABLED === "1") {
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

    const toolName = data.tool_name || "";
    const toolInput = data.tool_input || {};

    if (toolName !== "Write" && toolName !== "Edit" && toolName !== "Bash") {
      clearTimeout(safetyTimeout);
      process.exit(0);
    }

    if (toolName === "Bash") {
      const cmd = toolInput.command || "";
      if (/(?:^|[\s;])CK_API_KEY_DETECT_DISABLED=1\b/.test(cmd)) {
        clearTimeout(safetyTimeout);
        process.exit(0);
      }
    }

    let textToScan = "";
    let filePath = "";

    if (toolName === "Write") {
      textToScan = toolInput.content || "";
      filePath = toolInput.file_path || toolInput.path || "";
    } else if (toolName === "Edit") {
      textToScan = toolInput.new_string || "";
      filePath = toolInput.file_path || toolInput.path || "";
    } else if (toolName === "Bash") {
      textToScan = toolInput.command || "";
    }

    if (filePath && /\/(\.env|\.env\.[a-z]+|secrets?\.json)$/.test(filePath)) {
      clearTimeout(safetyTimeout);
      process.exit(0);
    }

    const detections = scanForKeys(textToScan);
    if (detections.length === 0) {
      clearTimeout(safetyTimeout);
      process.exit(0);
    }

    const scratchPath = writeScratchReport(toolName, filePath, detections);
    const detectionList = detections.map((detection) => `  - ${detection.name}: ${detection.redacted}`).join("\n");

    process.stderr.write(
      "[api-key-leak-detector] Blocked a possible API-key leak.\n"
      + `  Detected patterns:\n${detectionList}\n`
      + (scratchPath ? `  Local rotation evidence (mode 0600): ${scratchPath}\n` : "")
      + "  Remove the API key from the content before trying again.\n"
      + (toolName === "Bash"
        ? "  For a false positive, prefix the same Bash command with CK_API_KEY_DETECT_DISABLED=1.\n"
        : "  For a false positive, set CK_API_KEY_DETECT_DISABLED=1 in the hook environment and restart Claude Code.\n")
    );

    clearTimeout(safetyTimeout);
    process.exit(2);
  } catch (err) {
    try { process.stderr.write(`[api-key-leak-detector] Error: ${err?.message || err}\n`); } catch { /* ignore */ }
  }

  clearTimeout(safetyTimeout);
  process.exit(0);
}

process.on("uncaughtException", (err) => {
  try { process.stderr.write(`[api-key-leak-detector] Uncaught: ${err?.message || err}\n`); } catch { /* ignore */ }
  process.exit(0);
});

process.on("unhandledRejection", (err) => {
  try { process.stderr.write(`[api-key-leak-detector] Rejection: ${err?.message || err}\n`); } catch { /* ignore */ }
  process.exit(0);
});

main();
