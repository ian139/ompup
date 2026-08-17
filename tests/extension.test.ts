import { afterEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type { ExtensionAPI, ExtensionCommandContext } from "@oh-my-pi/pi-coding-agent";
import ompup, {
  createHandler,
  defaultRunner,
  getArgumentCompletions,
  parseTimeout,
  resolveCliPath,
  summarize,
  type CapturedOutput,
  type RunOutcome,
  type Runner,
} from "../extension/index.ts";

const cleanupPaths = new Set<string>();
const EMPTY_OUTPUT: CapturedOutput = {
  outputTail: "",
  stdoutTail: "",
  stderrTail: "",
  outputTruncated: false,
  stdoutBytes: 0,
  stderrBytes: 0,
};

afterEach(() => {
  for (const path of cleanupPaths) rmSync(path, { recursive: true, force: true });
  cleanupPaths.clear();
});

function fixtureDirectory(): string {
  const path = mkdtempSync(join(tmpdir(), "ompup-extension-test-"));
  cleanupPaths.add(path);
  return path;
}

function executable(root: string, name: string, body: string): string {
  const path = join(root, name);
  writeFileSync(path, `#!/bin/sh\nset -eu\n${body}\n`, { mode: 0o755 });
  chmodSync(path, 0o755);
  return path;
}

function retainArtifact(outcome: RunOutcome): string {
  expect(outcome.artifactPath).toBeDefined();
  const path = outcome.artifactPath as string;
  cleanupPaths.add(dirname(path));
  return path;
}

function context(hasUI = true, cwd = "/tmp") {
  const notifications: Array<{ message: string; severity: string | undefined }> = [];
  const statuses: Array<string | undefined> = [];
  const working: Array<string | undefined> = [];
  const ctx = {
    hasUI,
    cwd,
    ui: {
      notify: (message: string, severity?: string) => notifications.push({ message, severity }),
      setStatus: (_key: string, value: string | undefined) => statuses.push(value),
      setWorkingMessage: (value?: string) => working.push(value),
    },
  };
  return { ctx: ctx as unknown as ExtensionCommandContext, notifications, statuses, working };
}

describe("ompup extension registration", () => {
  test("registers the default factory label and user command with exact completions and no tool", () => {
    let label: string | undefined;
    let commandName: string | undefined;
    let command: {
      description: string;
      getArgumentCompletions?: (prefix: string) => unknown;
      handler: unknown;
    } | undefined;
    let toolRegistrations = 0;
    const api = {
      setLabel: (value: string) => { label = value; },
      registerCommand: (name: string, value: typeof command) => { commandName = name; command = value; },
      registerTool: () => { toolRegistrations += 1; },
    } as unknown as ExtensionAPI;

    ompup(api);

    expect(label).toBe("ompup");
    expect(commandName).toBe("ompup");
    expect(command?.description).toBe("Sync, pull, or inspect this project (sync|pull|status)");
    expect(command?.handler).toBeFunction();
    expect(command?.getArgumentCompletions?.("")).toEqual([
      { label: "sync", value: "sync" },
      { label: "pull", value: "pull" },
      { label: "status", value: "status" },
    ]);
    expect(command?.getArgumentCompletions?.("s")).toEqual([
      { label: "sync", value: "sync" },
      { label: "status", value: "status" },
    ]);
    expect(command?.getArgumentCompletions?.("P")).toEqual([{ label: "pull", value: "pull" }]);
    expect(command?.getArgumentCompletions?.("status ")).toBeNull();
    expect(command?.getArgumentCompletions?.("unknown")).toBeNull();
    expect(getArgumentCompletions("sy")).toEqual([{ label: "sync", value: "sync" }]);
    expect(toolRegistrations).toBe(0);
  });
});

describe("extension helpers and handler", () => {
  test("resolves the bundled binary deterministically and uses an explicit PATH fallback", () => {
    const bundled = "/private/package/bin/ompup";
    expect(resolveCliPath((path) => path === bundled, bundled)).toBe(bundled);
    expect(resolveCliPath(() => false, bundled)).toBe("ompup");
  });

  test("accepts only safe positive integer timer values", () => {
    expect(parseTimeout("4500", 30_000)).toBe(4_500);
    for (const value of [undefined, "", "0", "-1", "1.5", "1e3", " 10", "2147483648", "9007199254740992"]) {
      expect(parseTimeout(value, 30_000)).toBe(30_000);
    }
  });

  test("passes exact binary, verb, cwd, and status timeout while allowing status headless", async () => {
    const calls: Parameters<Runner>[] = [];
    const c = context(false, "/project with spaces");
    await createHandler({
      runner: async (...args) => {
        calls.push(args);
        return { kind: "exit", code: 0, ...EMPTY_OUTPUT };
      },
      resolveBinary: () => "/chosen/bin/ompup",
      environment: { OMPUP_STATUS_TIMEOUT_MS: "4321" },
    })("", c.ctx);

    expect(calls).toEqual([["/chosen/bin/ompup", "status", "/project with spaces", 4_321]]);
    expect(c.notifications).toEqual([{ message: "ompup status: succeeded", severity: "info" }]);
    expect(c.statuses).toEqual(["status…", undefined]);
    expect(c.working).toEqual(["ompup status…", undefined]);
  });

  test("uses operation timeout overrides and safe fallbacks", async () => {
    const observed: number[] = [];
    const runner: Runner = async (_bin, _verb, _cwd, timeout) => {
      observed.push(timeout);
      return { kind: "exit", code: 0, ...EMPTY_OUTPUT };
    };
    for (const value of ["8765", "invalid", "2147483648"]) {
      const c = context();
      await createHandler({
        runner,
        resolveBinary: () => "ompup",
        environment: { OMPUP_OPERATION_TIMEOUT_MS: value },
      })("sync", c.ctx);
    }
    expect(observed).toEqual([8_765, 120_000, 120_000]);
  });

  test("refuses both mutating verbs without UI before resolution or spawn", async () => {
    for (const verb of ["sync", "pull"] as const) {
      let resolved = false;
      let spawned = false;
      const c = context(false);
      await createHandler({
        resolveBinary: () => { resolved = true; return "ompup"; },
        runner: async () => { spawned = true; return { kind: "exit", code: 0, ...EMPTY_OUTPUT }; },
      })(verb, c.ctx);
      expect(resolved).toBe(false);
      expect(spawned).toBe(false);
      expect(c.notifications).toEqual([{ message: `ompup ${verb} requires an interactive UI`, severity: "error" }]);
      expect(c.statuses).toEqual([]);
      expect(c.working).toEqual([]);
    }
  });

  test("rejects invalid arguments without progress and reports every outcome at the correct severity", async () => {
    const invalid = context();
    await createHandler()("status extra", invalid.ctx);
    expect(invalid.notifications).toEqual([{ message: "Usage: /ompup [sync|pull|status]", severity: "error" }]);
    expect(invalid.statuses).toEqual([]);

    const outcomes: RunOutcome[] = [
      { ...EMPTY_OUTPUT, kind: "exit", code: 3, outputTail: "bad" },
      { ...EMPTY_OUTPUT, kind: "timeout", outputTail: "waiting" },
      { ...EMPTY_OUTPUT, kind: "signal", signal: "SIGTERM", outputTail: "killed" },
      { ...EMPTY_OUTPUT, kind: "enoent", error: new Error("missing") },
      { ...EMPTY_OUTPUT, kind: "spawn-error", error: new Error("broken") },
    ];
    for (const outcome of outcomes) {
      const c = context();
      await createHandler({ runner: async () => outcome, resolveBinary: () => "ompup" })("status", c.ctx);
      expect(c.notifications[0]?.severity).toBe("error");
      expect(c.notifications[0]?.message).toMatch(/ompup status: (exited|timed out|terminated|executable not found|failed to start)/);
      expect(c.statuses.at(-1)).toBeUndefined();
      expect(c.working.at(-1)).toBeUndefined();
    }
  });

  test("catches runner rejection and always clears both progress surfaces", async () => {
    const c = context();
    await createHandler({
      runner: async () => { throw new Error("adapter exploded"); },
      resolveBinary: () => "ompup",
    })("status", c.ctx);
    expect(c.notifications).toEqual([{ message: "ompup status: runner failed (adapter exploded)", severity: "error" }]);
    expect(c.statuses).toEqual(["status…", undefined]);
    expect(c.working).toEqual(["ompup status…", undefined]);
  });
});

describe("defaultRunner", () => {
  test("uses shell false with exact cwd and one argv, captures both streams, and deletes a short success artifact", async () => {
    const root = fixtureDirectory();
    const script = executable(root, "runner with spaces", "printf 'cwd=%s\\n' \"$PWD\"\nprintf 'argc=%s arg=%s\\n' \"$#\" \"$1\"\nprintf 'stderr-line\\n' >&2");
    const outcome = await defaultRunner(script, "status", root, 2_000);

    expect(outcome.kind).toBe("exit");
    if (outcome.kind !== "exit") return;
    expect(outcome.code).toBe(0);
    expect(outcome.stdoutTail).toContain(`cwd=${realpathSync(root)}`);
    expect(outcome.stdoutTail).toContain("argc=1 arg=status");
    expect(outcome.stderrTail).toContain("stderr-line");
    expect(outcome.outputTail).toContain("[stdout]");
    expect(outcome.outputTail).toContain("[stderr]");
    expect(outcome.artifactPath).toBeUndefined();
  });

  test("classifies nonzero, ENOENT, spawn errors, and real signals distinctly", async () => {
    const root = fixtureDirectory();
    const nonzero = executable(root, "nonzero", "printf 'bad-output\\n'\nprintf 'bad-error\\n' >&2\nexit 7");
    const nonzeroOutcome = await defaultRunner(nonzero, "sync", root, 2_000);
    expect(nonzeroOutcome.kind).toBe("exit");
    if (nonzeroOutcome.kind === "exit") expect(nonzeroOutcome.code).toBe(7);
    const nonzeroArtifact = retainArtifact(nonzeroOutcome);
    expect(statSync(nonzeroArtifact).mode & 0o777).toBe(0o600);
    const nonzeroContent = readFileSync(nonzeroArtifact, "utf8");
    expect(nonzeroContent).toContain("[stdout");
    expect(nonzeroContent).toContain("bad-output");
    expect(nonzeroContent).toContain("[stderr");
    expect(nonzeroContent).toContain("bad-error");

    const missingOutcome = await defaultRunner(join(root, "does-not-exist"), "status", root, 2_000);
    expect(missingOutcome.kind).toBe("enoent");
    retainArtifact(missingOutcome);

    const denied = join(root, "not-executable");
    writeFileSync(denied, "#!/bin/sh\nexit 0\n", { mode: 0o600 });
    const deniedOutcome = await defaultRunner(denied, "status", root, 2_000);
    expect(deniedOutcome.kind).toBe("spawn-error");
    retainArtifact(deniedOutcome);

    const signaled = executable(root, "signaled", "kill -TERM $$");
    const signalOutcome = await defaultRunner(signaled, "pull", root, 2_000);
    expect(signalOutcome.kind).toBe("signal");
    if (signalOutcome.kind === "signal") expect(signalOutcome.signal).toBe("SIGTERM");
    retainArtifact(signalOutcome);
  });

  test("retains private complete artifacts whenever success or failure display is truncated", async () => {
    const root = fixtureDirectory();
    const longSuccess = executable(root, "long-success", "i=0\nwhile [ \"$i\" -lt 2400 ]; do printf x; i=$((i + 1)); done\nprintf '\\nACTIONABLE-SUCCESS\\n'\nprintf 'success-stderr\\n' >&2");
    const success = await defaultRunner(longSuccess, "status", root, 2_000);
    expect(success.kind).toBe("exit");
    expect(success.outputTruncated).toBe(true);
    expect(success.outputTail.length).toBeLessThanOrEqual(1_600);
    expect(success.outputTail).toContain("ACTIONABLE-SUCCESS");
    const successArtifact = retainArtifact(success);
    expect(statSync(dirname(successArtifact)).mode & 0o777).toBe(0o700);
    expect(statSync(successArtifact).mode & 0o777).toBe(0o600);
    const successContent = readFileSync(successArtifact, "utf8");
    expect(successContent).toContain("ompup-output-v1");
    expect(successContent).toContain("ACTIONABLE-SUCCESS");
    expect(successContent).toContain("success-stderr");
    const successSummary = summarize("status", success);
    expect(successSummary.severity).toBe("info");
    expect(successSummary.message).toContain("ACTIONABLE-SUCCESS");
    expect(successSummary.message).toContain(`Full output: ${successArtifact}`);

    const longFailure = executable(root, "long-failure", "i=0\nwhile [ \"$i\" -lt 2400 ]; do printf y >&2; i=$((i + 1)); done\nprintf '\\nACTIONABLE-FAILURE\\n' >&2\nexit 9");
    const failure = await defaultRunner(longFailure, "sync", root, 2_000);
    expect(failure.kind).toBe("exit");
    expect(failure.outputTruncated).toBe(true);
    expect(failure.outputTail).toContain("ACTIONABLE-FAILURE");
    const failureArtifact = retainArtifact(failure);
    expect(statSync(failureArtifact).mode & 0o777).toBe(0o600);
    expect(readFileSync(failureArtifact, "utf8")).toContain("ACTIONABLE-FAILURE");
    const failureSummary = summarize("sync", failure);
    expect(failureSummary.severity).toBe("error");
    expect(failureSummary.message).toContain(`Full output: ${failureArtifact}`);
  });

  test("times out a dedicated child and grandchild process group only after cleanup and tree exit", async () => {
    const root = fixtureDirectory();
    const grandchild = join(root, "grandchild.ts");
    writeFileSync(grandchild, "#!/usr/bin/env bun\nsetInterval(() => {}, 1_000);\n", { mode: 0o755 });
    chmodSync(grandchild, 0o755);
    const child = join(root, "child.ts");
    writeFileSync(
      child,
      "#!/usr/bin/env bun\nimport { spawn } from \"node:child_process\";\nimport { writeFileSync } from \"node:fs\";\nimport { join } from \"node:path\";\nconst grandchild = spawn(join(process.cwd(), \"grandchild.ts\"), [], { stdio: \"inherit\" });\nwriteFileSync(join(process.cwd(), \"grandchild.pid\"), String(grandchild.pid));\nsetInterval(() => {}, 1_000);\n",
      { mode: 0o755 },
    );
    chmodSync(child, 0o755);
    const parent = join(root, "parent.ts");
    writeFileSync(
      parent,
      "#!/usr/bin/env bun\nimport { spawn } from \"node:child_process\";\nimport { writeFileSync } from \"node:fs\";\nimport { join } from \"node:path\";\nconst child = spawn(join(process.cwd(), \"child.ts\"), [], { stdio: \"inherit\" });\nwriteFileSync(join(process.cwd(), \"child.pid\"), String(child.pid));\nlet terminating = false;\nprocess.on(\"SIGTERM\", () => {\n  if (terminating) return;\n  terminating = true;\n  setTimeout(() => {\n    writeFileSync(join(process.cwd(), \"cleanup\"), \"cleaned\");\n    process.exit(0);\n  }, 150);\n});\nsetInterval(() => {}, 1_000);\n",
      { mode: 0o755 },
    );
    chmodSync(parent, 0o755);

    // This platform integration must exercise actual POSIX timers and signals; fake timers cannot drive child processes.
    const outcome = await defaultRunner(parent, "sync", root, 1_500, { terminationGraceMs: 1_000 });

    expect(outcome.kind).toBe("timeout");
    retainArtifact(outcome);
    expect(readFileSync(join(root, "cleanup"), "utf8")).toBe("cleaned");
    for (const file of ["child.pid", "grandchild.pid"]) {
      const pid = Number(readFileSync(join(root, file), "utf8"));
      expect(Number.isInteger(pid)).toBe(true);
      expect(() => process.kill(pid, 0)).toThrow();
    }
    expect(existsSync(join(root, "cleanup"))).toBe(true);
  });
});
