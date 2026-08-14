/**
 * ompup omp extension.
 *
 * Adds a /ompup slash command so you can push the current project to your
 * remote box without leaving the session:
 *
 *   /ompup sync     rsync this project up (refuses if the remote is dirty)
 *   /ompup pull     bring uncommitted remote work back to this checkout
 *   /ompup status   remote git status + tmux session state
 *
 * The interactive jump (tmux attach + omp launch) stays in the standalone
 * `ompup` CLI; a TUI session cannot hand its terminal to a remote tmux.
 * Configuration comes from the same environment variables as the CLI
 * (OMPUP_HOST and friends).
 */
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const SUBCOMMANDS: Record<string, true> = { sync: true, pull: true, status: true };

function cliPath(): string {
  // Prefer the CLI bundled beside this module (plugin/link installs keep
  // the repo layout); fall back to `ompup` on PATH.
  const bundled = fileURLToPath(new URL("../bin/ompup", import.meta.url));
  return existsSync(bundled) ? bundled : "ompup";
}

function run(
  bin: string,
  args: string[],
  cwd: string,
): Promise<{ ok: boolean; output: string }> {
  const { promise, resolve } = Promise.withResolvers<{ ok: boolean; output: string }>();
  execFile(bin, args, { cwd, timeout: 120_000 }, (error, stdout, stderr) => {
    const output = `${stdout}${stderr}`.trim();
    resolve({ ok: error === null, output });
  });
  return promise;
}

export default function ompup(pi: ExtensionAPI) {
  pi.setLabel("ompup");

  pi.registerCommand("ompup", {
    description: "Sync this project with your remote box (sync|pull|status)",
    handler: async (args, ctx) => {
      const sub = args.trim() || "status";
      if (!SUBCOMMANDS[sub]) {
        ctx.ui.notify(`/ompup takes one of: ${Object.keys(SUBCOMMANDS).join(", ")}`, "error");
        return;
      }
      if (!process.env.OMPUP_HOST) {
        ctx.ui.notify("Set OMPUP_HOST to your remote SSH host or alias", "error");
        return;
      }
      const { ok, output } = await run(cliPath(), [sub], ctx.cwd);
      const summary = output.length > 400 ? `${output.slice(0, 400)}...` : output;
      ctx.ui.notify(
        summary || (ok ? `ompup ${sub}: done` : `ompup ${sub}: failed`),
        ok ? "info" : "error",
      );
    },
  });
}
