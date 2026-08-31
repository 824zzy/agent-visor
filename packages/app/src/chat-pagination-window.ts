/**
 * Pure, renderer-independent windowing for Chat history.
 *
 * The daemon still owns its protocol page limit. This policy bounds the
 * renderer's retained suffix as users ask for earlier pages, so a large
 * transcript cannot turn one React render into an unbounded list.
 */

// ponytail: if the daemon page contract changes, update this ceiling with the
// protocol schema; never request or retain a page larger than that contract.
export const CHAT_PAGE_MAX_ITEMS = 1_000;

// ponytail: if initial history becomes too expensive, change this request and
// the visible-window tests together; keep it at or below the protocol cap.
export const CHAT_INITIAL_PAGE_LIMIT = 100;

export type ChatPaginationRange = {
  start: number;
  end: number;
};

export type BoundedChatItems<T> = {
  items: T[];
  hiddenCount: number;
  atSafetyCap: boolean;
};

export class ChatPaginationWindow {
  // ponytail: raising this first render count needs a measured renderer cost
  // review; use earlier-page expansion for an intentional larger view.
  static readonly defaultVisible = 100;
  // ponytail: keep each expansion bounded to one initial-sized page so a
  // single click cannot materialize an unexpectedly large transcript.
  static readonly increment = 100;
  // ponytail: if this renderer cap is reached, add a cursor/window contract
  // before increasing it; callers must keep the visible warning truthful.
  static readonly safetyCap = 4_000;

  readonly visibleLimit: number;

  constructor(visibleLimit = ChatPaginationWindow.defaultVisible) {
    this.visibleLimit = Math.min(
      ChatPaginationWindow.safetyCap,
      Math.max(0, Math.trunc(visibleLimit)),
    );
  }

  /** Return the newest bounded suffix of a source list. */
  slice(totalItems: number): ChatPaginationRange {
    const total = Math.max(0, Math.trunc(totalItems));
    const visible = Math.min(total, this.visibleLimit);
    return { start: total - visible, end: total };
  }

  hasMore(totalItems: number): boolean {
    return this.slice(totalItems).start > 0;
  }

  hiddenCount(totalItems: number): number {
    return this.slice(totalItems).start;
  }

  expanded(totalItems: number): ChatPaginationWindow {
    const total = Math.max(0, Math.trunc(totalItems));
    const next = Math.min(
      ChatPaginationWindow.safetyCap,
      this.visibleLimit + ChatPaginationWindow.increment,
      Math.max(total, this.visibleLimit),
    );
    return new ChatPaginationWindow(next);
  }

  /**
   * Retain a complete bounded page when the daemon had to extend a turn.
   * Unlike `expanded`, this jumps to the required source size so a page-local
   * prefix is not discarded merely because the request asked for 100 rows.
   */
  expandedTo(totalItems: number): ChatPaginationWindow {
    const total = Math.max(0, Math.trunc(totalItems));
    return new ChatPaginationWindow(Math.min(
      ChatPaginationWindow.safetyCap,
      Math.max(this.visibleLimit, total),
    ));
  }

  isFullyExpanded(totalItems: number): boolean {
    return this.visibleLimit >= Math.max(0, Math.trunc(totalItems));
  }

  isAtSafetyCap(totalItems: number): boolean {
    const total = Math.max(0, Math.trunc(totalItems));
    return Math.min(total, this.visibleLimit) >= ChatPaginationWindow.safetyCap;
  }
}

/** Apply the suffix window without allocating a second unbounded list. */
export function boundChatItems<T>(
  source: readonly T[],
  window: ChatPaginationWindow,
): BoundedChatItems<T> {
  const range = window.slice(source.length);
  const items = source.slice(range.start, range.end);
  return {
    items,
    hiddenCount: range.start,
    atSafetyCap: window.isAtSafetyCap(source.length),
  };
}
