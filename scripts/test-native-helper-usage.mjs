import { execFileSync, spawn, spawnSync } from "node:child_process";
import { mkdtemp, rm, stat } from "node:fs/promises";
import net from "node:net";
import path from "node:path";

const root = await mkdtemp(path.join("/tmp", "agent-visor-usage-ui-"));
const socketPath = path.join(root, "helper.sock");
const input = path.join(root, "input");
const bin = spawnSync(
  "swift",
  ["build", "--package-path", "AgentVisorCore", "--show-bin-path"],
  { encoding: "utf8" },
).stdout.trim();
execFileSync("swiftc", ["scripts/native-helper-ui-input.swift", "-o", input]);
const helperExecutable = process.argv[2] ?? path.join(bin, "AgentVisorNativeHelper");
const helper = spawn(helperExecutable, ["--socket", socketPath], {
  stdio: ["ignore", "ignore", "pipe"],
});
let stderr = "";
helper.stderr.on("data", (data) => { stderr += data.toString(); });
const messages = [];
const codexGlance = {
  id: "codex",
  heading: "Codex Usage",
  width: 114,
  label: "5h 82% | 7d 61%",
  detail: "Codex usage, 5 hour 82 percent remaining, weekly 61 percent remaining",
  tone: "normal",
  priority: 100,
  accessibilityLabel: "Codex usage, 5 hour 82 percent remaining, weekly 61 percent remaining",
  observedAt: "2026-08-24T12:00:00.000Z",
  windows: [
    {
      title: "5 hour limit",
      remainingPercent: 82,
      tone: "normal",
      resetsAt: "2026-08-24T13:00:00.000Z",
    },
    { title: "Weekly limit", remainingPercent: 61, tone: "normal" },
  ],
  resetCreditsAvailable: 3,
};
const claudeGlance = {
  id: "claude",
  heading: "Claude Usage",
  width: 68,
  label: "CC $582",
  detail: "Claude usage, 18 dollars used of 600 dollars",
  tone: "normal",
  priority: 90,
  accessibilityLabel: "Claude usage, 18 dollars used of 600 dollars",
  observedAt: "2026-08-24T12:00:00.000Z",
};

try {
  await waitForSocket();
  const socket = net.createConnection(socketPath);
  let buffer = Buffer.alloc(0);
  socket.on("data", (data) => {
    buffer = Buffer.concat([buffer, data]);
    while (buffer.length >= 4) {
      const size = buffer.readUInt32BE(0);
      if (buffer.length < size + 4) return;
      messages.push(JSON.parse(buffer.subarray(4, size + 4).toString("utf8")));
      buffer = buffer.subarray(size + 4);
    }
  });
  await new Promise((resolve, reject) => {
    socket.once("connect", resolve);
    socket.once("error", reject);
  });
  send(socket, {
    version: 1,
    id: "usage",
    method: "present_pills",
    params: {
      pills: [],
      usageGlances: [claudeGlance, codexGlance],
    },
  });
  await waitFor(() => messages.find((message) => message.id === "usage"));
  await waitFor(() => Number(run("count-usage")) === 2);
  const usageWidths = run("usage-widths");

  const firstOpenCount = await toggleTo(1);
  const refreshEvent = await waitFor(() =>
    messages.find((message) => message.event === "refresh_usage"));
  send(socket, {
    version: 1,
    id: "stale",
    method: "present_pills",
    params: {
      pills: [],
      usageGlances: [
        { ...claudeGlance, stale: true },
        { ...codexGlance, label: "5h 9% | 7d 100%", stale: true },
      ],
    },
  });
  await waitFor(() => messages.find((message) => message.id === "stale"));
  await sleep(300);
  const updatedUsageWidths = run("usage-widths");
  const accessibility = run("labels");
  const after = run("frontmost");
  const secondClickCount = await toggleTo(0);
  run("double-click-usage");
  await sleep(500);
  const rapidSecondClickCount = Number(run("count-popovers"));
  run("press-usage");
  await sleep(500);
  const accessibilityOpenCount = Number(run("count-popovers"));
  run("press-usage");
  await sleep(300);
  const accessibilityCloseCount = Number(run("count-popovers"));

  const result = {
    accepted: messages.find((message) => message.id === "usage")?.ok === true,
    usageWidths,
    widthsStable: updatedUsageWidths === usageWidths,
    helperPid: String(helper.pid),
    firstOpenCount,
    secondClickCount,
    rapidSecondClickCount,
    accessibilityOpenCount,
    accessibilityCloseCount,
    stayedNonactivating: after !== String(helper.pid),
    hasTitle: accessibility.includes("Codex Usage"),
    hasSharedClaudeDetail: accessibility.includes("Claude Usage")
      && accessibility.includes("Claude usage, 18 dollars used of 600 dollars"),
    hasFiveHour: accessibility.split("\n").some((label) =>
      label.startsWith("5 hour limit, 82 percent remaining")),
    hasWeekly: accessibility.includes("Weekly limit, 61 percent remaining"),
    hasReset: accessibility.split("\n").some((label) => label.includes(", resets ")),
    hasCredits: accessibility.includes("3 usage reset credits available"),
    marksStale: accessibility.split("\n").some((label) =>
      label.startsWith("Refresh failed; updated ")),
    requestedRefresh: refreshEvent.event === "refresh_usage",
    emittedSessionsEvent: messages.some((message) => message.event === "open_sessions"),
  };
  console.log(JSON.stringify(result, null, 2));
  if (!result.accepted || !/^68,11[2-4]$/.test(result.usageWidths)
      || !result.widthsStable
      || result.firstOpenCount !== 1 || result.secondClickCount !== 0
      || result.rapidSecondClickCount !== 0 || result.accessibilityOpenCount !== 1
      || result.accessibilityCloseCount !== 0
      || !result.stayedNonactivating || !result.hasTitle || !result.hasSharedClaudeDetail
      || !result.hasFiveHour
      || !result.hasWeekly || !result.hasReset || !result.hasCredits
      || !result.marksStale || !result.requestedRefresh || result.emittedSessionsEvent) {
    process.exitCode = 1;
  }
  socket.end();
} finally {
  if (helper.exitCode === null && helper.signalCode === null) {
    helper.kill("SIGTERM");
    await new Promise((resolve) => helper.once("exit", resolve));
  }
  await rm(root, { recursive: true, force: true });
  if (helper.exitCode) process.stderr.write(stderr);
}

function run(command) {
  return execFileSync(input, [command, String(helper.pid)], { encoding: "utf8" }).trim();
}
function send(socket, value) {
  const body = Buffer.from(JSON.stringify(value));
  const header = Buffer.alloc(4);
  header.writeUInt32BE(body.length);
  socket.write(Buffer.concat([header, body]));
}
function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
async function toggleTo(expected) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    run("click-usage");
    await sleep(500);
    const count = Number(run("count-popovers"));
    if (count === expected) return count;
  }
  return Number(run("count-popovers"));
}
async function waitForSocket() {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try { await stat(socketPath); return; } catch { await sleep(20); }
  }
  throw new Error(`native helper did not create its socket: ${stderr}`);
}
async function waitFor(read, milliseconds = 3_000) {
  const started = Date.now();
  while (Date.now() - started < milliseconds) {
    const value = read();
    if (value) return value;
    await sleep(20);
  }
  throw new Error(`Timed out. Messages: ${JSON.stringify(messages)} stderr=${stderr}`);
}
