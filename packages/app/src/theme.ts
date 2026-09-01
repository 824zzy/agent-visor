export const palettes = {
  light: {
    background: "#eff1f5", border: "#bcc0cc", card: "#ccd0da", settingsCard: "#eff1f5", foreground: "#4c4f69",
    muted: "#5c5f77", tertiary: "#62657a", accent: "#1854c4", accentWash: "#1854c414",
    attention: "#a05a00", ready: "#2f7d20", working: "#b84200", history: "#7c7f93", error: "#d20f39",
  },
  dark: {
    background: "#1e1e2e", border: "#45475a", card: "#313244", settingsCard: "#313244", foreground: "#cdd6f4",
    muted: "#a6adc8", tertiary: "#7f849c", accent: "#89b4fa", accentWash: "#89b4fa18",
    attention: "#f4c114", ready: "#a6e3a1", working: "#d97857", history: "#9399b2", error: "#f38ba8",
  },
};

export type Palette = typeof palettes.light;

// ponytail: Chat may tune content layers, but its root canvas must stay equal
// to Sessions so navigating between the two surfaces does not flash or drift.
export function createChatPalette(palette: Palette): Palette {
  const isDark = hexLuminance(palette.background) < 0.2;
  return {
    ...palette,
    background: palette.background,
    border: isDark ? "#3b3d43" : "#e7e7e3",
    card: isDark ? "#2b2d31" : "#f7f7f5",
    settingsCard: isDark ? "#2b2d31" : "#f7f7f5",
    foreground: isDark ? "#ecece8" : "#2d2d2b",
    muted: isDark ? "#b7b7b1" : "#6c6c68",
    tertiary: isDark ? "#92928d" : "#70706b",
    accentWash: isDark ? "#ffffff10" : "#00000008",
  };
}

function hexLuminance(value: string): number {
  const match = /^#([0-9a-f]{6})$/i.exec(value);
  if (!match) return 1;
  const channels = [0, 2, 4].map((start) => Number.parseInt(match[1]!.slice(start, start + 2), 16) / 255);
  const linear = channels.map((channel) => channel <= 0.03928
    ? channel / 12.92
    : ((channel + 0.055) / 1.055) ** 2.4);
  return 0.2126 * linear[0]! + 0.7152 * linear[1]! + 0.0722 * linear[2]!;
}
