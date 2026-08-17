import { describe, expect, test } from "bun:test";
import { createHandler, type RunOutcome } from "../extension/index.ts";
import type { ExtensionCommandContext } from "@oh-my-pi/pi-coding-agent";
function context(hasUI = true) {
  const notes: string[] = [];
  const statuses: Array<string | undefined> = [];
  const working: Array<string | undefined> = [];
  const ctx = { hasUI, cwd: "/tmp", ui: { notify: (m: string) => notes.push(m), setStatus: (_k: string, v: string | undefined) => statuses.push(v), setWorkingMessage: (v?: string) => working.push(v) } };
  return {
    ctx: ctx as unknown as ExtensionCommandContext,
    notes, statuses, working,
  };
}

describe("ompup extension", () => {
  test("defaults to status, completes verbs, and cleans progress", async () => {
    let call: unknown;
    const c = context();
    await createHandler(async (...args) => { call = args; return { kind: "exit", code: 0, stdout: "ok", stderr: "" }; })("", c.ctx);
    expect((call as unknown[])[1]).toBe("status");
    expect(c.notes[0]).toContain("succeeded");
    expect(c.statuses.at(-1)).toBeUndefined();
    expect(c.working.at(-1)).toBeUndefined();
  });

  test("rejects mutation before spawn without UI and rejects extra args", async () => {
    let spawned = false;
    const c = context(false);
    await createHandler(async () => { spawned = true; return { kind: "exit", code: 0, stdout: "", stderr: "" }; })("sync", c.ctx);
    expect(spawned).toBe(false);
    expect(c.notes[0]).toContain("require");
    const d = context();
    await createHandler(async () => ({ kind: "exit", code: 0, stdout: "", stderr: "" })) ("status extra", d.ctx);
    expect(d.notes[0]).toContain("Usage");
  });

  test("summarizes nonzero, timeout, signal, ENOENT and spawn error", async () => {
    const outcomes: RunOutcome[] = [
      { kind: "exit", code: 3, stdout: "bad", stderr: "err" },
      { kind: "timeout", stdout: "waiting", stderr: "" },
      { kind: "signal", signal: "SIGTERM", stdout: "", stderr: "killed" },
      { kind: "enoent", error: new Error("missing"), stdout: "", stderr: "" },
      { kind: "spawn-error", error: new Error("broken"), stdout: "", stderr: "" },
    ];
    for (const outcome of outcomes) {
      const c = context();
      await createHandler(async () => outcome)("status", c.ctx);
      expect(c.notes[0]).toMatch(/ompup status: (exited|timed out|terminated|executable not found|failed to start)/);
      expect(c.statuses.at(-1)).toBeUndefined();
    }
  });
});
