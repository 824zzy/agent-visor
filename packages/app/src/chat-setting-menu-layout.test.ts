import { describe, expect, it } from "vitest";
import { chatSettingMenuLayout } from "./chat-setting-menu-layout";

describe("composer popup placement", () => {
  it("keeps a readable menu inside the window even with the short Xhigh trigger", () => {
    const layout = chatSettingMenuLayout({ left: 90, right: 139, top: 702, bottom: 746 },
      { width: 1040, height: 760 }, "left");
    expect(layout.left).toBe(90);
    expect(layout.width).toBe(336);
    expect(layout.bottom).toBe(64);
    expect(layout.maxHeight).toBe(520);
  });

  it.each([320, 520, 1040])("clamps both menus at %ipx wide with enlarged text", (width) => {
    for (const align of ["left", "right"] as const) {
      const layout = chatSettingMenuLayout({ left: width - 150, right: width - 18, top: 302, bottom: 346 },
        { width, height: 360 }, align, 1.4);
      expect(layout.left).toBeGreaterThanOrEqual(12);
      expect(layout.left + layout.width).toBeLessThanOrEqual(width - 12);
      expect(layout.maxHeight + (layout.bottom ?? 0)).toBeLessThanOrEqual(348);
    }
  });

  it("opens below a trigger when the space above is too short", () => {
    const layout = chatSettingMenuLayout({ left: 28, right: 200, top: 35, bottom: 79 },
      { width: 520, height: 600 }, "left");
    expect(layout.top).toBe(85);
    expect(layout.maxHeight + layout.top!).toBe(588);
    expect(layout.bottom).toBeUndefined();
  });
});
