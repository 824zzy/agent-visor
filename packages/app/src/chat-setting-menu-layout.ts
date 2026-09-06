type Anchor = { left: number; right: number; top: number; bottom: number };

/** Keep the popup independent of the trigger's label width and inside the window. */
export function chatSettingMenuLayout(
  anchor: Anchor,
  viewport: { width: number; height: number },
  align: "left" | "right",
  scale = 1,
): { left: number; width: number; maxHeight: number; top?: number; bottom?: number } {
  const margin = 12;
  const gap = 6;
  const width = Math.min(336 * scale, Math.max(0, viewport.width - margin * 2));
  const left = Math.max(margin, Math.min(
    align === "left" ? anchor.left : anchor.right - width,
    viewport.width - margin - width,
  ));
  const above = Math.max(0, anchor.top - gap - margin);
  const below = Math.max(0, viewport.height - anchor.bottom - gap - margin);
  const opensAbove = above >= Math.min(400 * scale, below);
  return {
    left,
    width,
    maxHeight: Math.min(520 * scale, opensAbove ? above : below),
    ...(opensAbove
      ? { bottom: viewport.height - anchor.top + gap }
      : { top: anchor.bottom + gap }),
  };
}
