import path from "node:path";
import type { ProviderEnvironment } from "./environment.js";
import { isRecord } from "./shared.js";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const sessionFile = /^local_([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.json$/;

type DesktopSession = { cliSessionId: string; title?: string; url: string };

/** Desktop owns the UI session ID and title; neither can be inferred from a worker PID. */
export class ClaudeDesktopSessions {
  private readonly files = new Map<string, { stamp: string; session?: DesktopSession }>();

  constructor(private readonly environment: ProviderEnvironment) {}

  async read(profile: "Claude" | "Claude-3p"): Promise<Map<string, DesktopSession>> {
    const root = path.join(this.environment.home, "Library", "Application Support", profile, "claude-code-sessions");
    const seen = new Set<string>();
    const sessions = new Map<string, DesktopSession>();
    const ambiguous = new Set<string>();
    for (const account of await this.environment.directory(root)) {
      if (!uuid.test(account)) continue;
      const accountDirectory = path.join(root, account);
      for (const org of await this.environment.directory(accountDirectory)) {
        if (!uuid.test(org)) continue;
        const directory = path.join(accountDirectory, org);
        for (const name of await this.environment.directory(directory)) {
          if (!sessionFile.test(name)) continue;
          const file = path.join(directory, name);
          seen.add(file);
          const session = await this.readSession(file, name.slice(0, -5));
          if (!session || ambiguous.has(session.cliSessionId)) continue;
          const previous = sessions.get(session.cliSessionId);
          if (previous && previous.url !== session.url) {
            sessions.delete(session.cliSessionId);
            ambiguous.add(session.cliSessionId);
          } else {
            sessions.set(session.cliSessionId, session);
          }
        }
      }
    }
    for (const file of this.files.keys()) {
      if (file.startsWith(root + path.sep) && !seen.has(file)) this.files.delete(file);
    }
    return sessions;
  }

  private async readSession(file: string, expectedId: string): Promise<DesktopSession | undefined> {
    const stamp = await this.environment.stamp(file);
    if (!stamp) { this.files.delete(file); return undefined; }
    const key = `${stamp.size}:${stamp.modifiedAt.valueOf()}`;
    const cached = this.files.get(file);
    if (cached?.stamp === key) return cached.session;
    const raw = await this.environment.read(file, 1_048_576);
    if (!raw) { this.files.delete(file); return undefined; }
    let session: DesktopSession | undefined;
    try {
      const value: unknown = JSON.parse(raw);
      if (isRecord(value) && value.sessionId === expectedId
        && typeof value.cliSessionId === "string" && uuid.test(value.cliSessionId)
        && (value.isArchived === undefined || value.isArchived === false)) {
        session = {
          cliSessionId: value.cliSessionId,
          ...(typeof value.title === "string" && value.title.trim()
            ? { title: value.title.trim().slice(0, 256) } : {}),
          // This is Desktop's existing-conversation route. code/continue is unavailable
          // in third-party mode; resume imports a CLI session instead of selecting it.
          url: `claude://claude.ai/epitaxy/${expectedId}`,
        };
      }
    } catch { /* A partial Desktop metadata write is not a navigation target. */ }
    this.files.set(file, { stamp: key, session });
    return session;
  }
}
