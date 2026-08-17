import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync, mkdirSync, openSync, closeSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { AutocompleteItem } from "@oh-my-pi/pi-tui";
import type { ExtensionAPI, ExtensionCommandContext } from "@oh-my-pi/pi-coding-agent";

const VERBS = ["sync", "pull", "status"] as const;
type Verb = (typeof VERBS)[number];
const TAIL_LIMIT = 1600;
const LONG_OUTPUT_LIMIT = 6000;

export type RunOutcome =
  | { kind: "exit"; code: number; stdout: string; stderr: string }
  | { kind: "timeout"; stdout: string; stderr: string }
  | { kind: "signal"; signal: NodeJS.Signals | null; stdout: string; stderr: string }
  | { kind: "enoent"; error: Error; stdout: string; stderr: string }
  | { kind: "spawn-error"; error: Error; stdout: string; stderr: string };

export type Runner = (bin: string, verb: Verb, cwd: string, timeoutMs: number) => Promise<RunOutcome>;

function cliPath(): string {
  const bundled = fileURLToPath(new URL("../bin/ompup", import.meta.url));
  return existsSync(bundled) ? bundled : "ompup";
}

function envTimeout(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

export const defaultRunner: Runner = (bin, verb, cwd, timeoutMs) =>
  new Promise((resolve) => {
    let child: ChildProcessWithoutNullStreams;
    try {
      child = spawn(bin, [verb], { cwd, shell: false });
    } catch (error) {
      resolve({ kind: "spawn-error", error: error as Error, stdout: "", stderr: "" });
      return;
    }
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => { stdout += chunk.toString(); });
    child.stderr.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
    let settled = false;
    const finish = (outcome: RunOutcome) => { if (!settled) { settled = true; clearTimeout(timer); resolve(outcome); } };
    const timer = setTimeout(() => { child.kill("SIGTERM"); finish({ kind: "timeout", stdout, stderr }); }, timeoutMs);
    child.once("error", (error: NodeJS.ErrnoException) => finish({ kind: error.code === "ENOENT" ? "enoent" : "spawn-error", error, stdout, stderr }));
    child.once("close", (code, signal) => {
      if (signal) finish({ kind: "signal", signal, stdout, stderr });
      else finish({ kind: "exit", code: code ?? 1, stdout, stderr });
    });
  });

function tail(text: string): string {
  const trimmed = text.trim();
  return trimmed.length > TAIL_LIMIT ? `…${trimmed.slice(-TAIL_LIMIT)}` : trimmed;
}

function failureLog(output: string): string | undefined {
  if (output.length <= LONG_OUTPUT_LIMIT) return undefined;
  const dir = join(tmpdir(), "ompup");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const path = join(dir, `failure-${Date.now()}-${process.pid}.log`);
  const fd = openSync(path, "w", 0o600);
  try { writeFileSync(fd, output, { encoding: "utf8" }); } finally { closeSync(fd); }
  return path;
}

function summarize(verb: Verb, outcome: RunOutcome): { message: string; ok: boolean } {
  const output = `${outcome.stdout}${outcome.stderr}`;
  const detail = tail(output);
  const log = outcome.kind === "exit" && outcome.code === 0 ? undefined : failureLog(output);
  const suffix = log ? ` Full output: ${log}` : "";
  if (outcome.kind === "exit") return { ok: outcome.code === 0, message: `ompup ${verb}: ${outcome.code === 0 ? "succeeded" : `exited with code ${outcome.code}`}${detail ? `\n${detail}` : ""}${suffix}` };
  if (outcome.kind === "timeout") return { ok: false, message: `ompup ${verb}: timed out${detail ? `\n${detail}` : ""}${suffix}` };
  if (outcome.kind === "signal") return { ok: false, message: `ompup ${verb}: terminated by ${outcome.signal ?? "signal"}${detail ? `\n${detail}` : ""}${suffix}` };
  if (outcome.kind === "enoent") return { ok: false, message: `ompup ${verb}: executable not found (${outcome.error.message})${suffix}` };
  return { ok: false, message: `ompup ${verb}: failed to start (${outcome.error.message})${suffix}` };
}

function parse(args: string): Verb | "invalid" {
  const tokens = args.trim() ? args.trim().split(/\s+/) : ["status"];
  return tokens.length === 1 && (VERBS as readonly string[]).includes(tokens[0]) ? tokens[0] as Verb : "invalid";
}

export function createHandler(runner: Runner = defaultRunner) {
  return async (args: string, ctx: ExtensionCommandContext): Promise<void> => {
    const verb = parse(args);
    if (verb === "invalid") { ctx.ui.notify("Usage: /ompup [sync|pull|status]", "error"); return; }
    if (verb !== "status" && !ctx.hasUI) { ctx.ui.notify("ompup sync/pull require an interactive UI", "error"); return; }
    const timeout = envTimeout(verb === "status" ? "OMPUP_STATUS_TIMEOUT_MS" : "OMPUP_OPERATION_TIMEOUT_MS", verb === "status" ? 30_000 : 120_000);
    ctx.ui.setStatus("ompup", `${verb}…`);
    ctx.ui.setWorkingMessage(`ompup ${verb}…`);
    try {
      const result = summarize(verb, await runner(cliPath(), verb, ctx.cwd, timeout));
      ctx.ui.notify(result.message, result.ok ? "info" : "error");
    } finally {
      ctx.ui.setStatus("ompup", undefined);
      ctx.ui.setWorkingMessage();
    }
  };
}

export default function ompup(pi: ExtensionAPI) {
  pi.setLabel("ompup");
  pi.registerCommand("ompup", {
    description: "Sync, pull, or inspect this project (sync|pull|status)",
    getArgumentCompletions(prefix: string): AutocompleteItem[] | null {
      if (prefix.includes(" ")) return null;
      const q = prefix.trim().toLowerCase();
      const items = VERBS.filter((verb) => verb.startsWith(q)).map((verb) => ({ label: verb, value: verb }));
      return items.length ? items : null;
    },
    handler: createHandler(),
  });
}
