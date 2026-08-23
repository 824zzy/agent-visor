import { describe, expect, it } from "vitest";
import { palettes } from "./theme.js";

describe("surface palettes", () => {
  it("matches the released accessible Catppuccin colors", () => {
    expect(palettes.light).toMatchObject({
      background: "#eff1f5",
      border: "#bcc0cc",
      card: "#ccd0da",
      settingsCard: "#eff1f5",
      foreground: "#4c4f69",
      muted: "#5c5f77",
      tertiary: "#62657a",
      accent: "#1854c4",
      attention: "#a05a00",
      ready: "#2f7d20",
      working: "#b84200",
      history: "#7c7f93",
      error: "#d20f39",
    });
    expect(palettes.dark).toMatchObject({
      background: "#1e1e2e",
      card: "#313244",
      settingsCard: "#313244",
      foreground: "#cdd6f4",
      attention: "#f4c114",
      ready: "#a6e3a1",
      working: "#d97857",
      error: "#f38ba8",
    });
  });
});
