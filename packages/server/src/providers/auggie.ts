import type { DiscoveredProviderSession, ProviderAdapter } from "../sessions.js";
import type { ProviderEnvironment } from "./environment.js";

export class AuggieProvider implements ProviderAdapter {
  readonly id = "auggie" as const;

  constructor(_environment: ProviderEnvironment) {}

  async discover(): Promise<DiscoveredProviderSession[]> {
    // Auggie's released integration is hook-only. It has no verified transcript layout.
    return [];
  }
}
