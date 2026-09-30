import os from "node:os";
import type { ProviderAdapter } from "../sessions.js";
import { AuggieProvider } from "./auggie.js";
import { ClaudeProvider } from "./claude.js";
import { CodexProvider } from "./codex.js";
import { CursorProvider } from "./cursor.js";
import { LiveProviderEnvironment } from "./environment.js";
import type { CodexHome } from "./codex-instances.js";
import { PiProvider } from "./pi.js";
import { ZedProvider } from "./zed.js";

export function liveProviders(
  home = os.homedir(),
  observedWindowMs?: number | (() => number),
  codexHomes: () => CodexHome[] = () => [],
  saveDiscoveredCodexHome?: (home: CodexHome) => Promise<void>,
  ignoredCodexHomes: () => string[] = () => [],
): ProviderAdapter[] {
  const environment = new LiveProviderEnvironment(home, { observedWindowMs });
  return [
    new ClaudeProvider(environment),
    new CodexProvider(environment, codexHomes, saveDiscoveredCodexHome, ignoredCodexHomes),
    new PiProvider(environment),
    new CursorProvider(environment),
    new ZedProvider(environment),
    new AuggieProvider(environment),
  ];
}
