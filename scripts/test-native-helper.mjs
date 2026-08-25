import { spawn, spawnSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { nativeHelperResponseSchema } from "../packages/protocol/dist/index.js";

const root = await mkdtemp(path.join(os.tmpdir(), "agent-visor-helper-"));
const socketPath = path.join(root, "helper.sock");
const bin = spawnSync(
  "swift",
  ["build", "--package-path", "AgentVisorCore", "--show-bin-path"],
  { encoding: "utf8" },
).stdout.trim();
const helperApp = path.join(root, "Helper Host.app");
const helperExecutable = path.join(helperApp, "Contents/MacOS/AgentVisorNativeHelper");
await mkdir(path.dirname(helperExecutable), { recursive: true });
await copyFile(path.join(bin, "AgentVisorNativeHelper"), helperExecutable);
await writeFile(path.join(helperApp, "Contents/Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AgentVisorNativeHelper</string>
<key>CFBundleIdentifier</key><string>com.824zzy.AgentVisor.HelperTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>`);
const signed = spawnSync("codesign", ["--force", "--sign", "-", helperApp], { encoding: "utf8" });
if (signed.status !== 0) throw new Error(signed.stderr);
const helper = spawn(helperExecutable, ["--socket", socketPath], {
  stdio: ["ignore", "ignore", "pipe"],
});
let stderr = "";
helper.stderr.on("data", (data) => { stderr += data.toString(); });

try {
  await waitForSocket(socketPath);
  const mode = (await stat(socketPath)).mode & 0o777;
  if (mode !== 0o600) throw new Error(`native helper socket mode is ${mode.toString(8)}`);

  const responses = await exchange(socketPath, [
    { version: 1, id: "screens", method: "screen_topology" },
    { version: 1, id: "access", method: "accessibility_status" },
    { version: 1, id: "notifications", method: "notification_status" },
    {
      version: 1,
      id: "notice",
      method: "reconcile_notifications",
      params: { notifications: [], presentNew: false },
    },
    {
      version: 1,
      id: "pills",
      method: "present_pills",
      params: {
        pills: [{
          id: "session-1",
          title: "Review migration",
          subtitle: "Ready to continue",
          source: "Pi",
          project: "agent-visor",
          owner: "Ghostty",
          inspector: {
            status: "Ready",
            runtimeItems: ["Pi · Ghostty"],
            detailRows: [],
            projectPath: "~/Codes/agent-visor",
            activityAt: "2026-08-22T21:02:18.000Z",
          },
          phase: "ready",
          priority: 1,
          accessibilityLabel: "Review migration, ready",
        }],
        hotkeyTrigger: "shift",
        customHotkeyCombo: null,
        usageGlances: [{
          id: "codex",
          label: "5h 82%",
          detail: "Codex usage",
          tone: "normal",
          priority: 100,
          accessibilityLabel: "Codex usage",
        }],
      },
    },
    { version: 1, id: "bad", method: "parse_provider" },
  ]);

  if (
    responses[0]?.ok !== true
    || responses[0].result.type !== "screen_topology"
    || responses[0].result.screens.length === 0
  ) {
    throw new Error("screen topology response is missing");
  }
  if (responses[1]?.ok !== true || responses[1].result.type !== "accessibility_status") {
    throw new Error("Accessibility response is missing");
  }
  if (responses[2]?.ok !== true || responses[2].result.type !== "notification_status") {
    throw new Error("notification status is missing");
  }
  if (responses[3]?.ok !== true || responses[3].result.type !== "accepted") {
    throw new Error("notification reconciliation was not accepted");
  }
  if (responses[4]?.ok !== true || responses[4].result.type !== "accepted") {
    throw new Error("pill presentation was not accepted");
  }
  if (responses[5]?.ok !== false || responses[5].error.code !== "invalid_request") {
    throw new Error("invalid helper request was accepted");
  }

  console.log("Native helper wire PASS: secure socket, framing, topology, Accessibility, menu pills, and validation.");
} finally {
  if (helper.exitCode === null && helper.signalCode === null) {
    helper.kill("SIGTERM");
    await new Promise((resolve) => helper.once("exit", resolve));
  }
  if (helper.exitCode) process.stderr.write(stderr);
}

const { NativeHelperProcess } = await import("../packages/server/dist/native-helper.js");
const adapter = await NativeHelperProcess.start(helperExecutable, () => undefined);
try {
  if ((await adapter.screenTopology()).length === 0) {
    throw new Error("production helper adapter received no screens");
  }
  await adapter.notificationStatus();
  await adapter.reconcileNotifications([], false);
  await adapter.presentPills([{
    id: "adapter-session",
    title: "Adapter session",
    subtitle: "Agent is working",
    source: "Pi",
    project: "agent-visor",
    owner: "Ghostty",
    phase: "working",
    priority: 0,
    accessibilityLabel: "Adapter session, in progress",
  }], [], "controlCommand", "shift", null);
} finally {
  await adapter.close();
  await rm(root, { recursive: true, force: true });
}
console.log("Native helper adapter PASS: lifecycle, framed requests, menu updates, and cleanup.");

async function waitForSocket(socket) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      await stat(socket);
      return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  }
  throw new Error(`native helper did not create its socket: ${stderr}`);
}

async function exchange(socketPath, messages) {
  const socket = net.createConnection(socketPath);
  let buffer = Buffer.alloc(0);
  const responses = [];

  socket.on("data", (data) => {
    buffer = Buffer.concat([buffer, data]);
    while (buffer.length >= 4) {
      const size = buffer.readUInt32BE(0);
      if (buffer.length < size + 4) return;
      const value = JSON.parse(buffer.subarray(4, size + 4).toString("utf8"));
      responses.push(nativeHelperResponseSchema.parse(value));
      buffer = buffer.subarray(size + 4);
    }
  });

  await new Promise((resolve, reject) => {
    socket.once("connect", resolve);
    socket.once("error", reject);
  });
  for (const message of messages) socket.write(frame(message));

  for (let attempt = 0; responses.length < messages.length && attempt < 100; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  socket.end();
  if (responses.length !== messages.length) {
    throw new Error(`expected ${messages.length} responses, received ${responses.length}`);
  }
  return responses;
}

function frame(value) {
  const body = Buffer.from(JSON.stringify(value));
  const header = Buffer.alloc(4);
  header.writeUInt32BE(body.length);
  return Buffer.concat([header, body]);
}
