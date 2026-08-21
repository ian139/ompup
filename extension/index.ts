import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import {
  chmodSync,
  closeSync,
  constants,
  existsSync,
  fchmodSync,
  mkdtempSync,
  openSync,
  rmSync,
  writeSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { AutocompleteItem } from "@oh-my-pi/pi-tui";
import type { ExtensionAPI, ExtensionCommandContext } from "@oh-my-pi/pi-coding-agent";

const VERBS = ["sync", "pull", "status"] as const;
export type Verb = (typeof VERBS)[number];
const TAIL_LIMIT = 1_600;
const MAX_TIMER_MS = 2_147_483_647;
const DEFAULT_TERMINATION_GRACE_MS = 2_000;
const BUNDLED_CLI = fileURLToPath(new URL("../bin/ompup", import.meta.url));

type NotificationSeverity = "info" | "error";

export interface CapturedOutput {
  outputTail: string;
  stdoutTail: string;
  stderrTail: string;
  outputTruncated: boolean;
  stdoutBytes: number;
  stderrBytes: number;
  artifactPath?: string;
}

export type RunOutcome =
  | ({ kind: "exit"; code: number } & CapturedOutput)
  | ({ kind: "timeout" } & CapturedOutput)
  | ({ kind: "signal"; signal: NodeJS.Signals } & CapturedOutput)
  | ({ kind: "enoent"; error: Error } & CapturedOutput)
  | ({ kind: "spawn-error"; error: Error } & CapturedOutput);

export type Runner = (bin: string, verb: Verb, cwd: string, timeoutMs: number) => Promise<RunOutcome>;

export interface HandlerDependencies {
  runner?: Runner;
  resolveBinary?: () => string;
  environment?: Readonly<Record<string, string | undefined>>;
}

interface OutputSpool {
  readonly dir: string;
  readonly path: string;
  readonly fd: number;
  outputTail: string;
  stdoutTail: string;
  stderrTail: string;
  outputTruncated: boolean;
  stdoutBytes: number;
  stderrBytes: number;
}

interface RunnerOptions {
  terminationGraceMs?: number;
}

export function resolveCliPath(
  fileExists: (path: string) => boolean = existsSync,
  bundledPath = BUNDLED_CLI,
): string {
  return fileExists(bundledPath) ? bundledPath : "ompup";
}

export function parseTimeout(value: string | undefined, fallback: number): number {
  if (value === undefined || !/^\d+$/.test(value)) return fallback;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 && parsed <= MAX_TIMER_MS ? parsed : fallback;
}

export function getArgumentCompletions(prefix: string): AutocompleteItem[] | null {
  if (/\s/.test(prefix)) return null;
  const query = prefix.toLowerCase();
  const items = VERBS.filter((verb) => verb.startsWith(query)).map((verb) => ({ label: verb, value: verb }));
  return items.length === 0 ? null : items;
}

function createSpool(): OutputSpool {
  const dir = mkdtempSync(join(tmpdir(), "ompup-"));
  chmodSync(dir, 0o700);
  const path = join(dir, "output.log");
  const fd = openSync(
    path,
    constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
    0o600,
  );
  fchmodSync(fd, 0o600);
  writeAll(fd, Buffer.from("ompup-output-v1\n"));
  return {
    dir,
    path,
    fd,
    outputTail: "",
    stdoutTail: "",
    stderrTail: "",
    outputTruncated: false,
    stdoutBytes: 0,
    stderrBytes: 0,
  };
}

function writeAll(fd: number, bytes: Buffer): void {
  let offset = 0;
  while (offset < bytes.byteLength) offset += writeSync(fd, bytes, offset, bytes.byteLength - offset);
}

function boundedAppend(current: string, addition: string): { value: string; truncated: boolean } {
  if (addition.length >= TAIL_LIMIT) {
    return { value: addition.slice(-TAIL_LIMIT), truncated: current.length > 0 || addition.length > TAIL_LIMIT };
  }
  const combined = current + addition;
  return combined.length > TAIL_LIMIT
    ? { value: combined.slice(-TAIL_LIMIT), truncated: true }
    : { value: combined, truncated: false };
}
function sanitizeDisplay(text: string): string {
  let sanitized = "";
  for (const character of text) {
    const codePoint = character.codePointAt(0)!;
    if (codePoint === 0x09 || codePoint === 0x0a) {
      sanitized += character;
    } else if (codePoint < 0x20 || codePoint === 0x7f || (codePoint >= 0x80 && codePoint <= 0x9f)) {
      sanitized += `\\x${codePoint.toString(16).padStart(2, "0").toUpperCase()}`;
    } else {
      sanitized += character;
    }
  }
  return sanitized;
}

export function sanitizeNotificationText(text: string): string {
  return sanitizeDisplay(text);
}

function sanitizedErrorMessage(error: unknown): string {
  return sanitizeDisplay(errorMessage(error));
}

function summarizeDetail(outcome: RunOutcome): string {
  return sanitizeDisplay(outcome.outputTail.trim());
}

function summarizeError(outcome: Extract<RunOutcome, { kind: "enoent" | "spawn-error" }>): string {
  return sanitizedErrorMessage(outcome.error);
}

export function summarize(verb: Verb, outcome: RunOutcome): { message: string; severity: NotificationSeverity } {
  const detail = summarizeDetail(outcome);
  const displayed = detail ? `\n${outcome.outputTruncated ? "…" : ""}${detail}` : "";
  const artifact = outcome.artifactPath ? `\nFull output: ${sanitizeDisplay(outcome.artifactPath)}` : "";
  if (outcome.kind === "exit") {
    return {
      severity: outcome.code === 0 ? "info" : "error",
      message: `ompup ${verb}: ${outcome.code === 0 ? "succeeded" : `exited with code ${outcome.code}`}${displayed}${artifact}`,
    };
  }
  if (outcome.kind === "timeout") return { severity: "error", message: `ompup ${verb}: timed out${displayed}${artifact}` };
  if (outcome.kind === "signal") return { severity: "error", message: `ompup ${verb}: terminated by ${outcome.signal}${displayed}${artifact}` };
  if (outcome.kind === "enoent") return { severity: "error", message: `ompup ${verb}: executable not found (${summarizeError(outcome)})${displayed}${artifact}` };
  return { severity: "error", message: `ompup ${verb}: failed to start (${summarizeError(outcome)})${displayed}${artifact}` };
}

function capture(spool: OutputSpool, stream: "stdout" | "stderr", chunk: Buffer): void {
  const header = Buffer.from(`\n[${stream} ${chunk.byteLength} bytes]\n`);
  writeAll(spool.fd, header);
  writeAll(spool.fd, chunk);

  const text = chunk.toString("utf8");
  const ordered = boundedAppend(spool.outputTail, `\n[${stream}]\n${text}`);
  spool.outputTail = ordered.value;
  spool.outputTruncated ||= ordered.truncated;
  if (stream === "stdout") {
    spool.stdoutBytes += chunk.byteLength;
    spool.stdoutTail = boundedAppend(spool.stdoutTail, text).value;
  } else {
    spool.stderrBytes += chunk.byteLength;
    spool.stderrTail = boundedAppend(spool.stderrTail, text).value;
  }
}

function finishSpool(spool: OutputSpool, keep: boolean): CapturedOutput {
  closeSync(spool.fd);
  const output: CapturedOutput = {
    outputTail: spool.outputTail,
    stdoutTail: spool.stdoutTail,
    stderrTail: spool.stderrTail,
    outputTruncated: spool.outputTruncated,
    stdoutBytes: spool.stdoutBytes,
    stderrBytes: spool.stderrBytes,
  };
  if (keep) output.artifactPath = spool.path;
  else rmSync(spool.dir, { recursive: true, force: true });
  return output;
}

function signalProcessGroup(child: ChildProcessWithoutNullStreams, signal: NodeJS.Signals): void {
  if (child.pid === undefined) return;
  try {
    process.kill(-child.pid, signal);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ESRCH") child.kill(signal);
  }
}

export async function defaultRunner(
  bin: string,
  verb: Verb,
  cwd: string,
  timeoutMs: number,
  options: RunnerOptions = {},
): Promise<RunOutcome> {
  const spool = createSpool();
  const terminationGraceMs = options.terminationGraceMs ?? DEFAULT_TERMINATION_GRACE_MS;

  return await new Promise<RunOutcome>((resolve, reject) => {
    let child: ChildProcessWithoutNullStreams;
    try {
      child = spawn(bin, [verb], { cwd, detached: true, shell: false });
    } catch (error) {
      resolve({ kind: "spawn-error", error: error as Error, ...finishSpool(spool, true) });
      return;
    }

    child.stdout.on("data", (chunk: Buffer) => capture(spool, "stdout", chunk));
    child.stderr.on("data", (chunk: Buffer) => capture(spool, "stderr", chunk));

    let spawnError: NodeJS.ErrnoException | undefined;
    let timedOut = false;
    let settled = false;
    let escalation: NodeJS.Timeout | undefined;
    const timeout = setTimeout(() => {
      timedOut = true;
      signalProcessGroup(child, "SIGTERM");
      escalation = setTimeout(() => signalProcessGroup(child, "SIGKILL"), terminationGraceMs);
    }, timeoutMs);

    child.once("error", (error: NodeJS.ErrnoException) => {
      spawnError = error;
    });
    child.once("close", (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      clearTimeout(escalation);
      try {
        if (spawnError !== undefined) {
          const kind = spawnError.code === "ENOENT" ? "enoent" : "spawn-error";
          resolve({ kind, error: spawnError, ...finishSpool(spool, true) });
        } else if (timedOut) {
          resolve({ kind: "timeout", ...finishSpool(spool, true) });
        } else if (signal !== null) {
          resolve({ kind: "signal", signal, ...finishSpool(spool, true) });
        } else {
          const exitCode = code ?? 1;
          const keep = exitCode !== 0 || spool.outputTruncated;
          resolve({ kind: "exit", code: exitCode, ...finishSpool(spool, keep) });
        }
      } catch (error) {
        reject(error);
      }
    });
  });
}

 

function parseVerb(args: string): Verb | undefined {
  const tokens = args.trim() ? args.trim().split(/\s+/) : ["status"];
  return tokens.length === 1 && (VERBS as readonly string[]).includes(tokens[0]) ? tokens[0] as Verb : undefined;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function createHandler(dependencies: HandlerDependencies = {}) {
  const runner = dependencies.runner ?? defaultRunner;
  const resolveBinary = dependencies.resolveBinary ?? resolveCliPath;
  const environment = dependencies.environment ?? process.env;
  return async (args: string, ctx: ExtensionCommandContext): Promise<void> => {
    const verb = parseVerb(args);
    if (verb === undefined) {
      ctx.ui.notify("Usage: /ompup [sync|pull|status]", "error");
      return;
    }
    if (verb !== "status" && !ctx.hasUI) {
      ctx.ui.notify(`ompup ${verb} requires an interactive UI`, "error");
      return;
    }
    const timeoutName = verb === "status" ? "OMPUP_STATUS_TIMEOUT_MS" : "OMPUP_OPERATION_TIMEOUT_MS";
    const timeout = parseTimeout(environment[timeoutName], verb === "status" ? 30_000 : 120_000);
    ctx.ui.setStatus("ompup", `${verb}…`);
    ctx.ui.setWorkingMessage(`ompup ${verb}…`);
    try {
      const result = summarize(verb, await runner(resolveBinary(), verb, ctx.cwd, timeout));
      ctx.ui.notify(result.message, result.severity);
    } catch (error) {
      ctx.ui.notify(`ompup ${verb}: runner failed (${sanitizeDisplay(errorMessage(error))})`, "error");
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
    getArgumentCompletions,
    handler: createHandler(),
  });
}
