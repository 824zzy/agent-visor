import { execFileSync, spawn, spawnSync } from "node:child_process";
import { mkdir, mkdtemp, rm, stat } from "node:fs/promises";
import net from "node:net";
import path from "node:path";

const root = await mkdtemp(path.join("/tmp", "agent-visor-usage-ui-"));
const helperRoot = path.resolve("build/native-helper-usage-tests", String(process.pid));
await rm(helperRoot, { recursive: true, force: true });
await mkdir(helperRoot, { recursive: true });
const socketPath = path.join(root, "helper.sock");
const input = path.join(helperRoot, "input");
const fullScreenHostPath = path.join(helperRoot, "full-screen-host");
const bin = spawnSync(
  "swift",
  ["build", "--package-path", "AgentVisorCore", "--show-bin-path"],
  { encoding: "utf8" },
).stdout.trim();
execFileSync("swiftc", ["scripts/native-helper-ui-input.swift", "-o", input]);
execFileSync("swiftc", ["scripts/native-helper-full-screen-host.swift", "-o", fullScreenHostPath]);
const helperExecutable = process.argv[2] ?? path.join(bin, "AgentVisorNativeHelper");
const helper = spawn(helperExecutable, ["--socket", socketPath], {
  stdio: ["ignore", "ignore", "pipe"],
});
let stderr = "";
let fullScreenHost;
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
const overflowPills = Array.from({ length: 30 }, (_, index) => ({
  id: `session-${index}`,
  title: `Long full-screen session ${index}`,
  phase: "working",
  priority: index,
  accessibilityLabel: `Long full-screen session ${index}, in progress`,
}));
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
  send(socket, { version: 1, id: "access", method: "accessibility_status" });
  const accessibilityTrusted = (await waitFor(() =>
    messages.find((message) => message.id === "access"))).result.trusted;
  send(socket, { version: 1, id: "screens", method: "screen_topology" });
  const screens = (await waitFor(() => messages.find((message) => message.id === "screens")))
    .result.screens;
  send(socket, {
    version: 1,
    id: "usage",
    method: "present_pills",
    params: {
      pills: [],
      pillScreen: { mode: "automatic" },
      fullScreenPolicy: "alwaysShow",
      usageGlances: [claudeGlance, codexGlance],
    },
  });
  await waitFor(() => messages.find((message) => message.id === "usage"));
  await waitFor(() => Number(run("count-usage")) === 2);
  const usageWidths = run("usage-widths");
  const automaticDisplay = Number(run("usage-display-ids").split(",")[0]);
  const selectedScreen = screens.find((screen) => screen.displayId !== automaticDisplay)
    ?? screens[0];
  const presentSelected = (id, fullScreenPolicy, pills = [], shortcuts = false) => send(socket, {
    version: 1,
    id,
    method: "present_pills",
    params: {
      pills,
      pillScreen: {
        mode: "specific",
        displayId: selectedScreen.displayId,
        name: selectedScreen.name,
      },
      fullScreenPolicy,
      ...(shortcuts ? { shortcutModifierFamily: "optionCommand" } : {}),
      usageGlances: [claudeGlance, codexGlance],
    },
  });
  presentSelected("selected-screen", "alwaysShow");
  await waitFor(() => messages.find((message) => message.id === "selected-screen"));
  await waitFor(() => run("usage-display-ids").split(",").every(
    (displayId) => Number(displayId) === selectedScreen.displayId,
  ));
  const selectedDisplay = Number(run("usage-display-ids").split(",")[0]);

  fullScreenHost = await startFullScreenHost(selectedScreen.displayId);
  run("shortcut-up");
  run("move-away");
  presentSelected("on-demand", "onDemand", overflowPills, true);
  await waitFor(() => messages.find((message) => message.id === "on-demand"));
  await waitFor(() => run("usage-visible") === "false", 5_000);
  run("click-usage");
  await sleep(300);
  const hiddenClickCount = Number(run("count-popovers"));
  run("move-top");
  await waitFor(() => run("usage-visible") === "true");
  run("move-away");
  await waitFor(() => run("usage-visible") === "false");
  run("shortcut-down");
  await waitFor(() => run("usage-visible") === "true");
  run("shortcut-up");
  await waitFor(() => run("usage-visible") === "false");
  presentSelected("always-hide", "alwaysHide", [], true);
  await waitFor(() => messages.find((message) => message.id === "always-hide"));
  run("move-top");
  run("shortcut-down");
  await sleep(300);
  const alwaysHideStayedHidden = run("usage-visible") === "false";
  run("shortcut-up");
  presentSelected("always-show", "alwaysShow", [], true);
  await waitFor(() => messages.find((message) => message.id === "always-show"));
  await waitFor(() => run("usage-visible") === "true");
  presentSelected("on-demand-overflow", "onDemand", overflowPills, true);
  await waitFor(() => messages.find((message) => message.id === "on-demand-overflow"));
  run("shortcut-up");
  run("move-away");
  await waitFor(() => run("usage-visible") === "false");
  run("shortcut-one");
  await waitFor(() => messages.find((message) =>
    message.event === "activate_pill" && message.sessionId === "session-0"));
  const directShortcutStayedHidden = run("usage-visible") === "false";
  run("shortcut-zero");
  await waitFor(() => Number(run("count-popovers")) === 1);
  await waitFor(() => run("usage-visible") === "true");
  const overflowOpenCount = Number(run("count-popovers"));
  run("shortcut-zero");
  await waitFor(() => Number(run("count-popovers")) === 0);
  const overflowCloseCount = Number(run("count-popovers"));

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
  await stopFullScreenHost(fullScreenHost);
  fullScreenHost = undefined;
  presentSelected("windowed-always-hide", "alwaysHide");
  await waitFor(() => messages.find((message) => message.id === "windowed-always-hide"));
  await waitFor(() => run("usage-visible") === "true", 5_000);
  const windowedAlwaysVisible = run("usage-visible") === "true";

  const result = {
    accepted: messages.find((message) => message.id === "usage")?.ok === true,
    accessibilityTrusted,
    usageWidths,
    widthsStable: updatedUsageWidths === usageWidths,
    selectedDisplay: selectedDisplay === selectedScreen.displayId,
    hiddenClickCount,
    directShortcutStayedHidden,
    overflowOpenCount,
    overflowCloseCount,
    alwaysHideStayedHidden,
    windowedAlwaysVisible,
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
      || !result.widthsStable || !result.selectedDisplay
      || result.hiddenClickCount !== 0 || !result.directShortcutStayedHidden
      || result.overflowOpenCount !== 1 || result.overflowCloseCount !== 0
      || !result.alwaysHideStayedHidden || !result.windowedAlwaysVisible
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
  try {
    run("shortcut-up");
    run("move-away");
  } catch { /* helper may not have presented panels */ }
  if (fullScreenHost?.exitCode === null && fullScreenHost.signalCode === null) {
    fullScreenHost.kill("SIGTERM");
    await new Promise((resolve) => fullScreenHost.once("exit", resolve));
  }
  if (helper.exitCode === null && helper.signalCode === null) {
    helper.kill("SIGTERM");
    await new Promise((resolve) => helper.once("exit", resolve));
  }
  await rm(root, { recursive: true, force: true });
  await rm(helperRoot, { recursive: true, force: true });
  if (helper.exitCode) process.stderr.write(stderr);
}

async function startFullScreenHost(displayId) {
  let output = "";
  const child = spawn(fullScreenHostPath, [String(displayId)], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.on("data", (data) => { output += data.toString(); });
  child.stderr.on("data", (data) => { output += data.toString(); });
  await waitFor(() => output.includes("READY"), 10_000);
  return child;
}
async function stopFullScreenHost(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  child.kill("SIGTERM");
  await new Promise((resolve) => child.once("exit", resolve));
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
