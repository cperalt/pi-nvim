import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import * as net from "node:net";
import * as fs from "node:fs";
import * as path from "node:path";
import * as crypto from "node:crypto";

/**
 * pi-nvim: Exposes a unix socket so external tools (like a neovim plugin)
 * can send prompts/context into a running interactive pi session.
 *
 * Repo: https://github.com/carderne/pi-nvim
 *
 * Protocol: newline-delimited JSON over a unix socket.
 *
 * Commands:
 *   { "type": "prompt", "message": "..." }
 *   { "type": "prompt", "message": "...", "images": [...] }
 *   { "type": "ping" }
 *
 * Responses:
 *   { "ok": true }
 *   { "ok": true, "type": "pong" }
 *   { "ok": false, "error": "..." }
 *
 * Socket path: /tmp/pi-nvim-<hash-of-cwd>.sock
 * A symlink at /tmp/pi-nvim-latest.sock always points to the most recently
 * started session, so neovim can just connect there if there's only one.
 *
 * The socket path for a given cwd is also written to /tmp/pi-nvim-sockets/<hash>
 * as a plain text file containing the cwd, so neovim can list all running sessions.
 */

function cwdHash(cwd: string): string {
  return crypto.createHash("md5").update(cwd).digest("hex").slice(0, 12);
}

function getSocketPath(cwd: string): string {
  return path.join(SOCKETS_DIR, `${cwdHash(cwd)}-${process.pid}.sock`);
}

const SOCKETS_DIR = "/tmp/pi-nvim-sockets";
const LATEST_LINK = "/tmp/pi-nvim-latest.sock";

type EditorSelection = {
  startLine: number;
  endLine: number;
  text?: string;
  truncated?: boolean;
};

type EditorState = {
  cwd?: string;
  file?: string;
  absFile?: string;
  filetype?: string;
  modified?: boolean;
  buftype?: string;
  cursor?: { line: number; col: number };
  selection?: EditorSelection | null;
  bufferText?: string;
  bufferTruncated?: boolean;
  updatedAt?: string;
};

function getDisplayName(state: EditorState): string {
  const target = state.file || state.absFile;
  if (target && target !== "") return path.basename(target);
  if (state.buftype && state.buftype !== "") return `[${state.buftype}]`;
  return "[no file]";
}

function formatEditorState(state: EditorState): string {
  const lines: string[] = ["[NEOVIM LIVE CONTEXT]"];
  lines.push(`Focused file: ${getDisplayName(state)}`);

  if (state.filetype) lines.push(`Filetype: ${state.filetype}`);
  if (state.cursor) lines.push(`Cursor: L${state.cursor.line}:C${state.cursor.col}`);

  if (state.selection) {
    lines.push(`Selection: lines ${state.selection.startLine}-${state.selection.endLine}`);
    if (state.selection.text) {
      lines.push("Selected text:");
      lines.push("```" + (state.filetype || ""));
      lines.push(state.selection.text);
      lines.push("```");
      if (state.selection.truncated) {
        lines.push("(selection truncated)");
      }
    }
  }

  if (state.bufferText) {
    lines.push("Current in-memory buffer contents:");
    lines.push("```" + (state.filetype || ""));
    lines.push(state.bufferText);
    lines.push("```");
    if (state.bufferTruncated) {
      lines.push("(buffer snapshot truncated)");
    }
  } else if (state.file || state.absFile) {
    lines.push(`Reference: @${state.file || state.absFile}`);
  }

  return lines.join("\n");
}

function formatStatus(state: EditorState | null): string {
  if (!state) return "nvim: --";

  const parts = [`nvim: ${getDisplayName(state)}`];
  if (state.selection) parts.push(`sel ${state.selection.startLine}-${state.selection.endLine}`);
  else if (state.cursor) parts.push(`L${state.cursor.line}`);

  return parts.join(" ");
}

export default function (pi: ExtensionAPI) {
  let server: net.Server | null = null;
  let socketPath: string | null = null;
  let latestEditorState: EditorState | null = null;
  let sessionCtx: any = null;

  function updateStatus() {
    if (!sessionCtx?.hasUI) return;
    const theme = sessionCtx.ui.theme;
    sessionCtx.ui.setStatus("pi-nvim", theme.fg("accent", formatStatus(latestEditorState)));
  }

  pi.on("session_start", async (_event, ctx) => {
    const cwd = ctx.cwd;
    sessionCtx = ctx;
    latestEditorState = null;
    updateStatus();
    // Ensure sockets directory exists
    try {
      fs.mkdirSync(SOCKETS_DIR, { recursive: true });
    } catch {}

    socketPath = getSocketPath(cwd);

    // Clean up stale socket
    try {
      fs.unlinkSync(socketPath);
    } catch {}

    server = net.createServer((conn) => {
      let buffer = "";
      conn.on("data", (data) => {
        buffer += data.toString();
        let newlineIdx: number;
        while ((newlineIdx = buffer.indexOf("\n")) !== -1) {
          const line = buffer.slice(0, newlineIdx).trim();
          buffer = buffer.slice(newlineIdx + 1);
          if (!line) continue;
          handleMessage(line, conn, cwd);
        }
      });
      conn.on("error", () => {});
    });

    server.listen(socketPath, () => {
      // Update latest symlink
      try {
        fs.unlinkSync(LATEST_LINK);
      } catch {}
      try {
        fs.symlinkSync(socketPath!, LATEST_LINK);
      } catch {}

      // Register in sockets directory for discovery
      try {
        fs.mkdirSync(SOCKETS_DIR, { recursive: true });
        // Write a manifest file alongside the socket for discovery
        fs.writeFileSync(
          socketPath + ".info",
          JSON.stringify({
            cwd,
            pid: process.pid,
            startedAt: new Date().toISOString(),
          }),
        );
      } catch {}
    });

    server.on("error", (err) => {
      ctx.ui.notify(`pi-nvim error: ${err.message}`, "error");
    });
  });

  function handleMessage(raw: string, conn: net.Socket, _cwd: string) {
    try {
      const msg = JSON.parse(raw);

      if (msg.type === "ping") {
        respond(conn, { ok: true, type: "pong" });
        return;
      }

      if (msg.type === "editor_state" && msg.state && typeof msg.state === "object") {
        latestEditorState = {
          ...msg.state,
          updatedAt: new Date().toISOString(),
        };
        updateStatus();
        respond(conn, { ok: true });
        return;
      }

      if (msg.type === "prompt" && typeof msg.message === "string") {
        // Exit kitty's scrollback viewer by switching to private screen mode
        // and back. This snaps to the bottom without clearing scrollback history.
        process.stdout.write("\x1b[?1049h\x1b[?1049l");
        pi.sendUserMessage(msg.message);
        respond(conn, { ok: true });
        return;
      }

      respond(conn, { ok: false, error: `Unknown command type: ${msg.type}` });
    } catch (e: any) {
      respond(conn, { ok: false, error: `Parse error: ${e.message}` });
    }
  }

  function respond(conn: net.Socket, obj: any) {
    try {
      conn.write(JSON.stringify(obj) + "\n");
    } catch {}
  }

  function cleanup() {
    if (server) {
      server.close();
      server = null;
    }
    try {
      fs.unlinkSync(socketPath!);
    } catch {}
    try {
      // Clean up latest symlink if it points to us
      const target = fs.readlinkSync(LATEST_LINK);
      if (target === socketPath) fs.unlinkSync(LATEST_LINK);
    } catch {}
    try {
      fs.unlinkSync(socketPath + ".info");
    } catch {}
  }

  pi.on("before_agent_start", async () => {
    if (!latestEditorState) return;

    return {
      message: {
        customType: "pi-nvim-live-context",
        content: formatEditorState(latestEditorState),
        display: false,
        details: latestEditorState,
      },
    };
  });

  pi.on("session_shutdown", async () => {
    if (sessionCtx?.hasUI) {
      sessionCtx.ui.setStatus("pi-nvim", undefined);
    }
    sessionCtx = null;
    cleanup();
  });

  // Also clean up on process exit
  process.on("exit", cleanup);

  pi.registerCommand("pi-nvim-info", {
    description: "Show pi-nvim socket path",
    handler: async (_args, ctx) => {
      if (socketPath) {
        const file = latestEditorState ? getDisplayName(latestEditorState) : "--";
        ctx.ui.notify(`Socket: ${socketPath}\nFocused nvim target: ${file}`, "info");
      } else {
        ctx.ui.notify("pi-nvim not active", "warning");
      }
    },
  });
}
