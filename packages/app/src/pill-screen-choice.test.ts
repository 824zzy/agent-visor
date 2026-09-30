import { describe, expect, it } from "vitest";
import { pillScreenChoices } from "./pill-screen-choice.js";

const homeUuid = "8D1C3A42-0000-4000-8000-000000000001";
const officeUuid = "1A108786-48D9-48F8-9611-48282BDABE1F";
const builtIn = { displayId: 1, name: "Built-in Retina Display", isBuiltIn: true, isMain: false };
const office = { displayId: 5, displayUuid: officeUuid, name: "DELL P3424WEB", isBuiltIn: false, isMain: true };

describe("pill screen choices", () => {
  it("selects automatic and lists every live screen", () => {
    const choices = pillScreenChoices({ mode: "automatic" }, [builtIn, office]);

    expect(choices.selected).toBe("automatic");
    expect(choices.values.map(choices.labelFor))
      .toEqual(["Automatic", "Built-in Retina Display", "DELL P3424WEB"]);
  });

  it("saves the display UUID when the user chooses a screen", () => {
    const choices = pillScreenChoices({ mode: "automatic" }, [builtIn, office]);

    expect(choices.preferenceFor(choices.values[2]!)).toEqual({
      mode: "specific", displayId: 5, name: "DELL P3424WEB", displayUuid: officeUuid,
    });
    expect(choices.preferenceFor(choices.values[1]!)).toEqual({
      mode: "specific", displayId: 1, name: "Built-in Retina Display",
    });
    expect(choices.preferenceFor("automatic")).toEqual({ mode: "automatic" });
  });

  it("labels another monitor with a reused display ID as a fallback, not the saved screen", () => {
    const choices = pillScreenChoices(
      { mode: "specific", displayId: 5, name: "XZ322QU V3", displayUuid: homeUuid },
      [builtIn, office],
    );

    expect(choices.labelFor(choices.selected)).toBe("DELL P3424WEB (Fallback)");
    expect(choices.values.map(choices.labelFor)).toContain("XZ322QU V3 (Unavailable)");
  });

  it("matches a legacy preference by display ID and name, then by name", () => {
    const reusedId = pillScreenChoices(
      { mode: "specific", displayId: 5, name: "XZ322QU V3" },
      [builtIn, office],
    );
    expect(reusedId.labelFor(reusedId.selected)).toBe("DELL P3424WEB (Fallback)");

    const byName = pillScreenChoices(
      { mode: "specific", displayId: 9, name: "DELL P3424WEB" },
      [builtIn, office],
    );
    expect(byName.labelFor(byName.selected)).toBe("DELL P3424WEB");
  });

  it("follows the saved monitor when macOS gives it a new display ID", () => {
    const choices = pillScreenChoices(
      { mode: "specific", displayId: 5, name: "DELL P3424WEB", displayUuid: officeUuid },
      [builtIn, { ...office, displayId: 7 }],
    );

    expect(choices.labelFor(choices.selected)).toBe("DELL P3424WEB");
    expect(choices.preferenceFor(choices.selected)).toMatchObject({ displayId: 7 });
  });

  it("shows the active home monitor while the saved office monitor is away", () => {
    const home = { displayId: 5, displayUuid: homeUuid, name: "XZ322QU V3", isBuiltIn: false, isMain: true };
    const choices = pillScreenChoices(
      { mode: "specific", displayId: 5, name: "DELL P3424WEB", displayUuid: officeUuid },
      [builtIn, home],
    );

    expect(choices.labelFor(choices.selected)).toBe("XZ322QU V3 (Fallback)");
    expect(choices.values.map(choices.labelFor)).toContain("DELL P3424WEB (Unavailable)");
  });

  it("prefers an external fallback and keeps the saved choice for reconnection", () => {
    const selected = { mode: "specific" as const, displayId: 5, name: "DELL P3424WEB", displayUuid: officeUuid };
    const secondary = { displayId: 7, displayUuid: homeUuid, name: "Secondary", isBuiltIn: false, isMain: false };
    const home = { displayId: 9, name: "Main External", isBuiltIn: false, isMain: true };

    const mainChoice = pillScreenChoices(selected, [builtIn, secondary, home]);
    expect(mainChoice.labelFor(mainChoice.selected)).toBe("Main External (Fallback)");
    const secondaryChoice = pillScreenChoices(selected, [builtIn, secondary]);
    expect(secondaryChoice.labelFor(secondaryChoice.selected)).toBe("Secondary (Fallback)");
    const laptopOnly = pillScreenChoices(selected, [builtIn]);
    expect(laptopOnly.labelFor(laptopOnly.selected)).toBe("Built-in Retina Display (Fallback)");
    const reconnected = pillScreenChoices(selected, [builtIn, office]);
    expect(reconnected.labelFor(reconnected.selected)).toBe("DELL P3424WEB");
    expect(selected.displayUuid).toBe(officeUuid);
  });
});
