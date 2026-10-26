import { mkdir, mkdtemp, rm, unlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { WebSocketServer } from "ws";
import { afterEach, expect, it } from "vitest";
import { PaseoClient } from "./paseo-client.js";
import { liveProviders } from "./index.js";
import { nativeHelperRequestSchema, sessionSnapshotSchema } from "@agent-visor/protocol";
import { SessionRepository } from "../sessions.js";
import { menuPresentation } from "../menu.js";

const roots: string[] = [];
const servers: WebSocketServer[] = [];
afterEach(async () => {
  for (const server of servers.splice(0)) {
    for (const socket of server.clients) socket.terminate();
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

async function fixture() {
  const home = await mkdtemp(path.join(os.tmpdir(), "visor-paseo-")); roots.push(home);
  const root = path.join(home, ".paseo"); await mkdir(root);
  const server = new WebSocketServer({ host: "127.0.0.1", port: 0 }); servers.push(server);
  await new Promise<void>(resolve => server.once("listening", resolve));
  const address = server.address(); if (typeof address === "string" || !address) throw new Error("No address");
  const instance = {
    pid: process.pid, listen: `127.0.0.1:${address.port}`, serverId: "srv_fixture",
  };
  await writeFile(path.join(root, "paseo.pid"), JSON.stringify(instance));
  await writeFile(path.join(root, "local-credential"), "fixture-local-token", { mode: 0o600 });
  await writeFile(path.join(root, "config.json"), JSON.stringify({
    agents: { providers: { "claude-copilot": { extends: "claude" } } },
  }));
  const requests: string[] = [];
  let serverId = "srv_fixture";
  let secondPage = false;
  let customProvidersAccepted = false;
  let rows = [{ id: "agent_one", provider: "claude-copilot", title: "Work",
    cwd: "/Users/me/Codes", status: "idle", updatedAt: "2026-10-12T21:00:00.000Z",
    pendingPermissions: [], archivedAt: null }];
  server.on("connection", socket => socket.on("message", data => {
    const frame = JSON.parse(data.toString()); const message = frame.message ?? frame;
    requests.push(message.type);
    if (message.type === "hello") {
      // Paseo's published capability gates provider IDs outside the original built-in set.
      customProvidersAccepted = message.capabilities?.all_providers === true;
      expect(message.auth).toEqual({ kind: "localCredential", token: "fixture-local-token" });
      socket.send(JSON.stringify({ type: "session", message: {
        type: "status", payload: { status: "server_info", serverId },
      } }));
    } else if (message.type === "fetch_agents_request") {
      const more = secondPage && !message.page?.cursor;
      socket.send(JSON.stringify({ type: "session", message: {
        type: "fetch_agents_response", payload: { requestId: message.requestId,
          entries: (customProvidersAccepted ? rows : []).map(agent => ({ agent: more ? agent : secondPage ? { ...agent, id: "agent_two" } : agent })),
          pageInfo: { hasMore: more, nextCursor: more ? "page_two" : null } },
      } }));
    }
  }));
  return { home, root, instance, requests, setRows(next: typeof rows) { rows = next; },
    setServerId(value: string) { serverId = value; }, useTwoPages() { secondPage = true; } };
}

it("reads the live authenticated directory and custom Claude profile without any session-control request", async () => {
  const f = await fixture();
  expect(await new PaseoClient(f.home).read()).toMatchObject({
    serverId: "srv_fixture", providers: { "claude-copilot": "claude" },
    agents: [{ id: "agent_one", title: "Work" }],
  });
  expect(f.requests).toEqual(["hello", "fetch_agents_request"]);
});

it("shows the confirmed Claude profile in hover details without changing the Paseo pill title", async () => {
  const f = await fixture();
  const now = new Date("2026-10-12T21:00:00.000Z");
  const provider = liveProviders(f.home).find(provider => provider.id === "paseo")!;
  const repository = new SessionRepository([provider], { now: () => now });
  const snapshot = sessionSnapshotSchema.parse(await repository.refresh());
  const presentation = menuPresentation(snapshot, [], now.valueOf());

  expect(presentation.navigatorPills[0]).toMatchObject({
    title: "Work", source: "Paseo", owner: "Paseo", phase: "history",
    inspector: {
      runtimeItems: ["Claude Code · Paseo"],
      detailRows: [
        { label: "Profile", value: "claude-copilot" },
        { label: "Presence", value: "Status unavailable: Agent Visor could not verify whether this conversation is open." },
      ],
    },
  });
  expect(nativeHelperRequestSchema.safeParse({
    version: 1, id: "hover-source", method: "present_pills", params: presentation,
  }).success).toBe(true);
  expect(f.requests).toEqual(["hello", "fetch_agents_request"]);
});

it("rejects a replaced daemon instead of publishing links for a different server", async () => {
  const f = await fixture(); f.setServerId("srv_replacement");
  expect(await new PaseoClient(f.home).read()).toBeUndefined();
  expect(f.requests).toEqual(["hello"]);
});

it("reads every directory page rather than silently omitting later conversations", async () => {
  const f = await fixture(); f.useTwoPages();
  expect((await new PaseoClient(f.home).read())?.agents.map(agent => agent.id))
    .toEqual(["agent_one", "agent_two"]);
});

it.each([
  { id: "agent/other" }, { cwd: "relative" }, { updatedAt: "invalid" },
])("rejects an invalid directory snapshot (%j)", async invalid => {
  const f = await fixture();
  f.setRows([{ id: "agent_one", provider: "claude-copilot", title: "Work",
    cwd: "/Users/me/Codes", status: "idle", updatedAt: "2026-10-12T21:00:00.000Z",
    pendingPermissions: [], archivedAt: null, ...invalid }]);
  expect(await new PaseoClient(f.home).read()).toBeUndefined();
});

it("uses a short ambient cache but rechecks clicks and discards unavailable daemon state", async () => {
  const f = await fixture(); const client = new PaseoClient(f.home);
  expect((await client.read())?.agents).toHaveLength(1);
  expect((await client.read())?.agents).toHaveLength(1);
  expect(f.requests).toEqual(["hello", "fetch_agents_request"]);
  await unlink(path.join(f.root, "paseo.pid"));
  expect(await client.read(true)).toBeUndefined();
  expect(await client.read()).toBeUndefined();
  // A ready daemon can be read again after it recovers; the failure is not permanent.
  await writeFile(path.join(f.root, "paseo.pid"), JSON.stringify(f.instance));
  expect((await client.read(true))?.agents).toHaveLength(1);
});

it("includes the Paseo adapter in normal live discovery", async () => {
  const f = await fixture();
  const provider = liveProviders(f.home).find(provider => provider.id === "paseo");
  expect(await provider?.discover()).toMatchObject([{ title: "Work", owner: "Paseo" }]);
});
