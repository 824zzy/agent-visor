const fallbackVersion = "0.0.0";

/** Return the version injected by the packaged Electron shell for provider clients. */
export function agentVisorVersion(): string {
  return process.env.AGENT_VISOR_VERSION?.trim() || fallbackVersion;
}
