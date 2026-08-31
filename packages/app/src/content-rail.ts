// ponytail: If Swift changes the shared Sessions and Chat rail contract, update these values together and retest wide and minimum windows.
export const CONTENT_RAIL_MAX_WIDTH = 980;
export const CONTENT_RAIL_INSET = 28;

export function contentRailStyle() {
  return {
    alignSelf: "center" as const,
    maxWidth: CONTENT_RAIL_MAX_WIDTH,
    width: "100%" as const,
  };
}
