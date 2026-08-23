export const palettes = {
  light: {
    background: "#f7f7fa", border: "#d8dae5", card: "#e9eaf0", foreground: "#343746",
    muted: "#70758a", tertiary: "#8b8fa1", accent: "#416fe5", accentWash: "#416fe514",
    attention: "#c59316", ready: "#278d50", working: "#c04b1c", history: "#73778a",
  },
  dark: {
    background: "#1e1e2e", border: "#45475a", card: "#313244", foreground: "#cdd6f4",
    muted: "#a6adc8", tertiary: "#7f849c", accent: "#89b4fa", accentWash: "#89b4fa18",
    attention: "#f9e2af", ready: "#a6e3a1", working: "#fab387", history: "#9399b2",
  },
};

export type Palette = typeof palettes.light;
