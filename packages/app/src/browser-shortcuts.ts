export type BrowserKeyInput = {
  key: string;
  metaKey?: boolean;
  shiftKey?: boolean;
  altKey?: boolean;
  ctrlKey?: boolean;
};

export type BrowserCommand =
  | { type: "move"; offset: -1 | 1 }
  | { type: "activate"; alternate: boolean }
  | { type: "hotkey"; position: number }
  | { type: "focus_search" }
  | { type: "clear_search" }
  | { type: "open_settings" }
  | { type: "back" }
  | { type: "scale"; delta: -0.1 | 0 | 0.1 };

export function browserCommand(input: BrowserKeyInput): BrowserCommand | undefined {
  const commandOnly = input.metaKey && !input.altKey && !input.ctrlKey;
  if (commandOnly && input.key.toLocaleLowerCase() === "f") return { type: "focus_search" };
  if (commandOnly && input.key === ",") return { type: "open_settings" };
  if (commandOnly && input.key === "[") return { type: "back" };
  if (commandOnly && /^[1-9]$/.test(input.key)) {
    return { type: "hotkey", position: Number(input.key) - 1 };
  }
  if (commandOnly && ["+", "="].includes(input.key)) return { type: "scale", delta: 0.1 };
  if (commandOnly && ["-", "_"].includes(input.key)) return { type: "scale", delta: -0.1 };
  if (commandOnly && input.key === "0") return { type: "scale", delta: 0 };
  if (!input.metaKey && !input.altKey && !input.ctrlKey) {
    if (input.key === "ArrowDown") return { type: "move", offset: 1 };
    if (input.key === "ArrowUp") return { type: "move", offset: -1 };
    if (input.key === "Enter") return { type: "activate", alternate: Boolean(input.shiftKey) };
    if (input.key === "Escape") return { type: "clear_search" };
  }
  return undefined;
}

export function sessionShortcutEducation(
  family: "off" | "controlCommand" | "optionCommand" | "controlOptionCommand",
): { hints: { keys: string; label: string }[]; disabledMessage?: string } {
  const modifiers = {
    off: undefined,
    controlCommand: "⌃⌘",
    optionCommand: "⌥⌘",
    controlOptionCommand: "⌃⌥⌘",
  }[family];
  return modifiers ? {
    hints: [
      { keys: `${modifiers}1–9`, label: "Switch sessions" },
      { keys: `${modifiers}0`, label: "Session menu" },
    ],
  } : { hints: [], disabledMessage: "Global shortcuts off · Configure in Settings" };
}

export function changeContentScale(current: number, delta: -0.1 | 0 | 0.1): number {
  if (delta === 0) return 1;
  return Math.min(2.5, Math.max(0.8, Math.round((current + delta) * 10) / 10));
}
