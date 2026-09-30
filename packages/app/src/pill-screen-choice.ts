import type { AppSettings, NativeServicesState } from "@agent-visor/protocol";

type PillScreen = AppSettings["pillScreen"];
type PillScreenOption = NativeServicesState["pillScreens"][number];

const unavailable = "unavailable";

function fallbackScreen(screens: readonly PillScreenOption[]): PillScreenOption | undefined {
  return screens.find((screen) => !screen.isBuiltIn && screen.isMain)
    ?? screens.find((screen) => !screen.isBuiltIn)
    ?? screens.find((screen) => screen.isBuiltIn)
    ?? screens.find((screen) => screen.isMain)
    ?? screens[0];
}

/**
 * Settings chooser model for the pill screen. The match rule mirrors
 * NativeMenuScreenSelectionPolicy in the helper, so the chip names the monitor
 * the pills are on. macOS reuses display IDs across monitors, so a saved
 * UUID never falls back to a display ID match.
 */
export function pillScreenChoices(preference: PillScreen, screens: readonly PillScreenOption[]) {
  const keyFor = (screen: PillScreenOption) => `screen:${screen.displayId}`;
  const matched = preference.mode === "specific" ? matchScreen(preference, screens) : undefined;
  const fallback = preference.mode === "specific" && !matched ? fallbackScreen(screens) : undefined;
  const selected = preference.mode === "automatic" ? "automatic"
    : matched ? keyFor(matched) : fallback ? keyFor(fallback) : unavailable;
  const values = ["automatic", ...screens.map(keyFor)];
  if (preference.mode === "specific" && !matched) values.push(unavailable);
  const screenFor = (value: string) => screens.find((screen) => keyFor(screen) === value);

  return {
    values,
    selected,
    labelFor(value: string): string {
      if (value === "automatic") return "Automatic";
      if (value === unavailable && preference.mode === "specific") {
        return `${preference.name} (Unavailable)`;
      }
      const screen = screenFor(value);
      return screen && screen === fallback ? `${screen.name} (Fallback)` : screen?.name ?? value;
    },
    preferenceFor(value: string): PillScreen | undefined {
      if (value === "automatic") return { mode: "automatic" };
      const screen = screenFor(value);
      return screen ? {
        mode: "specific",
        displayId: screen.displayId,
        name: screen.name,
        ...(screen.displayUuid ? { displayUuid: screen.displayUuid } : {}),
      } : undefined;
    },
  };
}

function matchScreen(
  preference: Extract<PillScreen, { mode: "specific" }>,
  screens: readonly PillScreenOption[],
): PillScreenOption | undefined {
  if (preference.displayUuid) {
    return screens.find(({ displayUuid }) => displayUuid === preference.displayUuid);
  }
  return screens.find(({ displayId, name }) =>
    displayId === preference.displayId && name === preference.name)
    ?? screens.find(({ name }) => name === preference.name);
}
