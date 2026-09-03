/**
 * Pure scroll decisions for the Chat transcript.
 *
 * The renderer supplies the current distance from the document bottom. This
 * module does not know about ScrollView, DOM nodes, or React state, so the
 * same contract can be exercised without mounting the app.
 */

// ponytail: if the Swift forgiveness band changes, update this exact 80 px
// threshold and the near-boundary tests together; do not tune one renderer.
export const CHAT_NEAR_BOTTOM_THRESHOLD = 80;
export const defaultNearBottomThreshold = CHAT_NEAR_BOTTOM_THRESHOLD;

export type ChatTailScrollAction = "pin-to-tail" | "preserve";

export type ChatTailEvent =
  | { type: "initial" }
  | { type: "head-prepend"; distanceFromBottom: number }
  | { type: "tail-insert"; distanceFromBottom: number; threshold?: number }
  | { type: "stream-growth"; distanceFromBottom: number; threshold?: number }
  | { type: "content-resize"; distanceFromBottom: number; threshold?: number }
  | { type: "composer-resize"; distanceFromBottom: number; threshold?: number }
  | { type: "local-send"; distanceFromBottom?: number };

export type ChatItemsChange = "initial" | "head-prepend" | "tail-insert" | "stream-growth" | "unchanged";

export function classifyChatItemsChange({
  previousIDs,
  nextIDs,
  contentChanged,
}: {
  previousIDs: readonly string[];
  nextIDs: readonly string[];
  contentChanged: boolean;
}): ChatItemsChange {
  if (!previousIDs.length) return nextIDs.length ? "initial" : "unchanged";
  const sameLength = previousIDs.length === nextIDs.length;
  const sameRows = sameLength && previousIDs.every((id, index) => nextIDs[index] === id);
  if (sameRows) return contentChanged ? "stream-growth" : "unchanged";
  // ponytail: keep this classification linear in the retained history. The
  // Set is intentionally built once so a long tail insert cannot turn each
  // appended-row check into a nested scan.
  const previousIDSet = new Set(previousIDs);
  const isTailInsert = nextIDs.length > previousIDs.length
    && previousIDs.every((id, index) => nextIDs[index] === id);
  if (isTailInsert) return "tail-insert";
  // A bounded latest page can slide its first row out as a new tail row
  // arrives. The previous tail remains the immediate predecessor of the new
  // tail, which is enough identity evidence for the same tail-insert policy.
  const previousTail = previousIDs[previousIDs.length - 1];
  const previousTailIndex = previousTail === undefined ? -1 : nextIDs.indexOf(previousTail);
  if (previousTailIndex >= 0 && previousTailIndex < nextIDs.length - 1) {
    const appended = nextIDs.slice(previousTailIndex + 1);
    if (appended.some((id) => !previousIDSet.has(id))) return "tail-insert";
  }
  const offset = nextIDs.length - previousIDs.length;
  const isHeadPrepend = offset > 0
    && previousIDs.every((id, index) => nextIDs[index + offset] === id);
  return isHeadPrepend ? "head-prepend" : "unchanged";
}

/** Match Swift's `distanceFromBottom <= threshold` predicate. */
export function isNearChatBottom(
  distanceFromBottom: number,
  threshold: number = CHAT_NEAR_BOTTOM_THRESHOLD,
): boolean {
  return distanceFromBottom <= threshold;
}

type InsertOptions = {
  distanceFromBottom: number;
  threshold?: number;
  insertedAtTail: boolean;
  localUserSend?: boolean;
};

/**
 * Decide whether a row insertion may move the reader to the tail.
 *
 * `localUserSend` is an explicit user command and therefore has priority over
 * the ordinary near-bottom rule. Head/earlier-page inserts must pass false.
 */
export function shouldAutoPinOnInsert(options: InsertOptions): boolean;
export function shouldAutoPinOnInsert(
  distanceFromBottom: number,
  threshold: number,
  insertedAtTail: boolean,
): boolean;
export function shouldAutoPinOnInsert(
  optionsOrDistance: InsertOptions | number,
  threshold?: number,
  insertedAtTail?: boolean,
): boolean {
  const options: InsertOptions = typeof optionsOrDistance === "number"
    ? {
      distanceFromBottom: optionsOrDistance,
      threshold,
      insertedAtTail: insertedAtTail === true,
    }
    : optionsOrDistance;
  if (options.localUserSend) return true;
  if (!options.insertedAtTail) return false;
  return isNearChatBottom(options.distanceFromBottom, options.threshold);
}

/** Stream growth changes the last row, so it shares Swift's near-bottom rule. */
export function shouldStreamPin(
  distanceFromBottom: number,
  threshold: number = CHAT_NEAR_BOTTOM_THRESHOLD,
): boolean {
  return isNearChatBottom(distanceFromBottom, threshold);
}

/** Composer growth may reduce the viewport, but only a near-tail reader follows it. */
export function shouldAutoPinOnComposerResize(
  distanceFromBottom: number,
  threshold: number = CHAT_NEAR_BOTTOM_THRESHOLD,
): boolean {
  return isNearChatBottom(distanceFromBottom, threshold);
}

/** Resolve one transcript/viewport event into a renderer-neutral action. */
export function chatTailAction(event: ChatTailEvent): ChatTailScrollAction {
  switch (event.type) {
    case "local-send":
      return "pin-to-tail";
    case "head-prepend":
    case "initial":
      return "preserve";
    case "tail-insert":
      return shouldAutoPinOnInsert({
        distanceFromBottom: event.distanceFromBottom,
        threshold: event.threshold,
        insertedAtTail: true,
      }) ? "pin-to-tail" : "preserve";
    case "stream-growth":
      return shouldStreamPin(event.distanceFromBottom, event.threshold)
        ? "pin-to-tail"
        : "preserve";
    case "content-resize":
      return shouldStreamPin(event.distanceFromBottom, event.threshold)
        ? "pin-to-tail"
        : "preserve";
    case "composer-resize":
      return shouldAutoPinOnComposerResize(event.distanceFromBottom, event.threshold)
        ? "pin-to-tail"
        : "preserve";
  }
}
