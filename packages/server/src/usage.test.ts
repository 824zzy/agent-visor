import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { chatUsageGlanceFromNative, codexUsageGlance, readCodexUsage } from "./usage.js";

const roots: string[] = [];
const originalBinary = process.env.CODEX_BINARY;
const originalLog = process.env.AGENT_VISOR_USAGE_TEST_LOG;
const originalVersion = process.env.AGENT_VISOR_VERSION;

afterEach(async () => {
  if (originalBinary === undefined) delete process.env.CODEX_BINARY;
  else process.env.CODEX_BINARY = originalBinary;
  if (originalLog === undefined) delete process.env.AGENT_VISOR_USAGE_TEST_LOG;
  else process.env.AGENT_VISOR_USAGE_TEST_LOG = originalLog;
  if (originalVersion === undefined) delete process.env.AGENT_VISOR_VERSION;
  else process.env.AGENT_VISOR_VERSION = originalVersion;
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("Codex usage glance", () => {
  it("passes the packaged version to the Codex usage client", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-usage-client-"));
    roots.push(root);
    const log = path.join(root, "requests.jsonl");
    const executable = path.join(root, "codex.cjs");
    await writeFile(executable, `#!/usr/bin/env node
const fs=require('node:fs'),readline=require('node:readline');
const log=process.env.AGENT_VISOR_USAGE_TEST_LOG;
readline.createInterface({input:process.stdin}).on('line',line=>{
  fs.appendFileSync(log,line+'\\n');
  const m=JSON.parse(line);
  if(m.id===1) process.stdout.write(JSON.stringify({id:1,result:{}})+'\\n');
  if(m.id===2) process.stdout.write(JSON.stringify({id:2,result:{rateLimits:{primary:{usedPercent:18,windowDurationMins:300}}}})+'\\n');
});
`, { mode: 0o700 });
    await chmod(executable, 0o700);
    process.env.CODEX_BINARY = executable;
    process.env.AGENT_VISOR_USAGE_TEST_LOG = log;
    process.env.AGENT_VISOR_VERSION = "2.7.0";

    await expect(readCodexUsage()).resolves.toMatchObject({ id: "codex" });
    const messages = (await readFile(log, "utf8")).trim().split("\n")
      .map((line) => JSON.parse(line));
    expect(messages[0].params.clientInfo).toEqual({ name: "agent-visor", version: "2.7.0" });
  });

  it("presents five-hour and weekly remaining limits with the strongest tone", () => {
    expect(codexUsageGlance({
      rateLimits: {
        primary: { usedPercent: 18, windowDurationMins: 300 },
        secondary: { usedPercent: 89, windowDurationMins: 10_080 },
      },
    }, new Date("2026-08-24T12:00:00.000Z"))).toEqual({
      id: "codex",
      heading: "Codex Usage",
      width: 114,
      label: "5h 82% | 7d 11%",
      detail: "Codex usage, 5 hour 82 percent remaining, weekly 11 percent remaining",
      tone: "warning",
      priority: 100,
      accessibilityLabel: "Codex usage, 5 hour 82 percent remaining, weekly 11 percent remaining",
      observedAt: "2026-08-24T12:00:00.000Z",
      windows: [
        {
          title: "5 hour limit", remainingPercent: 82, tone: "normal",
        },
        {
          title: "Weekly limit", remainingPercent: 11, tone: "warning",
        },
      ],
    });
  });

  it("retains authoritative reset details for the usage popover", () => {
    expect(codexUsageGlance({
      rateLimits: {
        primary: {
          usedPercent: 18,
          windowDurationMins: 300,
          resetsAt: 1_700_001_800,
        },
        secondary: {
          usedPercent: 39,
          windowDurationMins: 10_080,
          resetsAt: 1_700_604_800,
        },
      },
      rateLimitResetCredits: { availableCount: 3 },
    }, new Date("2026-08-24T12:00:00.000Z"))).toMatchObject({
      heading: "Codex Usage",
      width: 114,
      observedAt: "2026-08-24T12:00:00.000Z",
      windows: [
        {
          title: "5 hour limit",
          remainingPercent: 82,
          tone: "normal",
          resetsAt: "2023-11-14T22:43:20.000Z",
        },
        {
          title: "Weekly limit",
          remainingPercent: 61,
          tone: "normal",
          resetsAt: "2023-11-21T22:13:20.000Z",
        },
      ],
      resetCreditsAvailable: 3,
    });
  });

  it("does not invent a five-hour limit when Codex reports only a weekly window", () => {
    expect(codexUsageGlance({
      rateLimits: {
        primary: { usedPercent: 2, windowDurationMins: 10_080 },
        secondary: null,
      },
    }, new Date("2026-08-24T12:00:00.000Z"))).toEqual({
      id: "codex",
      heading: "Codex Usage",
      width: 64,
      label: "7d 98%",
      detail: "Codex usage, weekly 98 percent remaining",
      tone: "normal",
      priority: 100,
      accessibilityLabel: "Codex usage, weekly 98 percent remaining",
      observedAt: "2026-08-24T12:00:00.000Z",
      windows: [{
        title: "Weekly limit", remainingPercent: 98, tone: "normal",
      }],
    });
  });

  it("omits malformed reset times without losing valid usage", () => {
    expect(codexUsageGlance({
      rateLimits: {
        primary: {
          usedPercent: 18,
          windowDurationMins: 300,
          resetsAt: Number.MAX_VALUE,
        },
      },
    }, new Date("2026-08-24T12:00:00.000Z"))?.windows).toEqual([
      {
        title: "5 hour limit", remainingPercent: 82, tone: "normal",
      },
    ]);
  });

  it("omits unrecognized payloads instead of fabricating usage", () => {
    expect(codexUsageGlance({ rateLimits: {} })).toBeUndefined();
    expect(codexUsageGlance({ rateLimits: { primary: { usedPercent: "18" } } }))
      .toBeUndefined();
    expect(codexUsageGlance({
      rateLimits: {
        primary: { usedPercent: 18, windowDurationMins: 60 },
        secondary: { usedPercent: 39, windowDurationMins: 1_440 },
      },
    })).toBeUndefined();
  });

  it("projects only complete Codex usage into Chat metadata", () => {
    const native = codexUsageGlance({
      rateLimits: {
        primary: { usedPercent: 18, windowDurationMins: 300 },
        secondary: { usedPercent: 39, windowDurationMins: 10_080 },
      },
    }, new Date("2026-08-24T12:00:00.000Z"));
    expect(chatUsageGlanceFromNative(native)).toEqual({
      provider: "codex",
      percentUsed: 39,
      label: "5h 82% | 7d 61%",
      detail: "Codex usage, 5 hour 82 percent remaining, weekly 61 percent remaining",
      observedAt: "2026-08-24T12:00:00.000Z",
    });
    expect(chatUsageGlanceFromNative({
      id: "codex", label: "unknown", detail: "unknown", tone: "normal", priority: 1,
      accessibilityLabel: "unknown",
    })).toBeUndefined();
  });
});
