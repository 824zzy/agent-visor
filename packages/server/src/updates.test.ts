import { describe, expect, it } from "vitest";
import { updateFromAppcast } from "./updates.js";

function appcast(version: string, signature = Buffer.alloc(64, 7).toString("base64")) {
  return `<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><title>Version ${version}</title><sparkle:shortVersionString>${version}</sparkle:shortVersionString><enclosure url="https://github.com/824zzy/agent-visor/releases/download/v${version}/Agent.Visor-${version}.zip" sparkle:edSignature="${signature}" /></item></channel></rss>`;
}

describe("update appcast policy", () => {
  it("accepts only a newer signed public release", () => {
    expect(updateFromAppcast(appcast("2.7.1"), "2.7.0")).toEqual({
      status: "available",
      currentVersion: "2.7.0",
      availableVersion: "2.7.1",
      releaseUrl: "https://github.com/824zzy/agent-visor/releases/tag/v2.7.1",
    });
  });

  it("refuses rollback and unsigned update entries", () => {
    expect(updateFromAppcast(appcast("2.6.1"), "2.7.0")).toEqual({
      status: "up_to_date",
      currentVersion: "2.7.0",
    });
    expect(updateFromAppcast(appcast("2.7.1", ""), "2.7.0")).toMatchObject({
      status: "error",
      currentVersion: "2.7.0",
    });
  });
});
