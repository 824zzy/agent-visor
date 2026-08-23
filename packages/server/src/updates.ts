import type { NativeServicesState } from "@agent-visor/protocol";

export type UpdateState = NativeServicesState["update"];

export function updateFromAppcast(xml: string, currentVersion: string): UpdateState {
  const item = xml.match(/<item\b[\s\S]*?<\/item>/i)?.[0];
  const version = item?.match(/<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/i)?.[1]?.trim();
  const enclosure = item?.match(/<enclosure\b([^>]*)\/?\s*>/i)?.[1];
  const url = enclosure && attribute(enclosure, "url");
  const signature = enclosure && attribute(enclosure, "sparkle:edSignature");
  if (!version || !validVersion(version) || !url || !validReleaseURL(url, version)
    || !signature || !validSignature(signature)) {
    return {
      status: "error",
      currentVersion,
      error: "The update feed did not contain a valid signed public release.",
    };
  }
  if (compareVersions(version, currentVersion) <= 0) {
    return { status: "up_to_date", currentVersion };
  }
  return {
    status: "available",
    currentVersion,
    availableVersion: version,
    releaseUrl: `https://github.com/824zzy/agent-visor/releases/tag/v${version}`,
  };
}

export async function checkForUpdates(currentVersion: string): Promise<UpdateState> {
  try {
    const response = await fetch("https://824zzy.github.io/agent-visor/appcast.xml", {
      signal: AbortSignal.timeout(15_000),
      headers: { accept: "application/xml", "user-agent": "AgentVisor/2.6.2" },
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return updateFromAppcast(await response.text(), currentVersion);
  } catch (error) {
    return {
      status: "error",
      currentVersion,
      error: `Update check failed: ${String(error)}`.slice(0, 1_024),
    };
  }
}

function attribute(value: string, name: string): string | undefined {
  return value.match(new RegExp(`\\b${name.replace(":", "\\:")}=["']([^"']+)["']`, "i"))?.[1];
}

function validSignature(value: string): boolean {
  try {
    return /^[A-Za-z0-9+/]{86}==$/.test(value)
      && Buffer.from(value, "base64").length === 64;
  } catch {
    return false;
  }
}

function validVersion(value: string): boolean {
  return /^\d+\.\d+\.\d+$/.test(value);
}

function validReleaseURL(value: string, version: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "https:"
      && url.hostname === "github.com"
      && url.pathname.startsWith(`/824zzy/agent-visor/releases/download/v${version}/`)
      && url.pathname.endsWith(".zip");
  } catch {
    return false;
  }
}

function compareVersions(left: string, right: string): number {
  const a = left.split(".").map(Number);
  const b = right.split(".").map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return (a[index] ?? 0) - (b[index] ?? 0);
  }
  return 0;
}
