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
