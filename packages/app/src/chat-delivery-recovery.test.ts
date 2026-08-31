import { describe, expect, it } from "vitest";
import type { ChatImage } from "@agent-visor/protocol";
import {
  createChatDeliveryRecoveryStore,
  type ChatComposerSnapshot,
  type ChatDeliveryRecoveryInput,
} from "./chat-delivery-recovery.js";

const image = (name: string): ChatImage => ({
  name,
  mimeType: "image/png",
  byteLength: 8,
  data: "iVBORw0KGgo=",
});

const draft = (text = "Fix it", withImage = true) => ({
  text,
  images: withImage ? [image("diagram.png")] : [],
});

const composer = (value: ReturnType<typeof draft>, revision = 1): ChatComposerSnapshot => ({
  draft: value,
  revision,
});

function failure(overrides: Partial<ChatDeliveryRecoveryInput> = {}): ChatDeliveryRecoveryInput {
  return {
    sessionId: "session",
    generation: 1,
    requestId: "request-1",
    deliveryId: "delivery-1",
    draft: draft(),
    error: "Provider rejected the message.",
    cause: "send-failed",
    currentComposer: composer({ text: "", images: [] }),
    ...overrides,
  };
}

describe("chat delivery recovery store", () => {
  it("restores an immutable submitted text and attachment snapshot when the composer is empty", () => {
    const store = createChatDeliveryRecoveryStore({
      clock: { now: () => 1_700_000_000_000 },
      createRequestId: () => "retry-request-1",
      createDeliveryId: () => "retry-delivery-1",
    });
    store.activate("session", 1);
    const submitted = failure();
    const result = store.recordFailure(submitted)!;

    expect(result.record).toMatchObject({
      id: "session:1:delivery-1",
      status: "failed",
      cause: "send-failed",
      draft: draft(),
    });
    expect(result.restore).toMatchObject({
      status: "restored",
      draft: draft(),
      expectedRevision: 1,
    });

    submitted.draft.text = "mutated outside";
    submitted.draft.images[0]!.name = "mutated.png";
    expect(store.list("session", 1)[0]?.draft).toEqual(draft());
  });

  it("accounts for UTF-8/base64 bytes and preserves the oldest actionable snapshot", () => {
    const store = createChatDeliveryRecoveryStore({ maxSnapshotBytesPerScope: 220 });
    store.activate("session", 1);
    const first = store.recordFailure(failure({
      draft: { text: "é", images: [image("first.png")] },
    }))!.record;
    const second = store.recordFailure(failure({
      requestId: "request-2",
      deliveryId: "delivery-2",
      draft: { text: "新", images: [image("second.png")] },
    }));

    expect(second).toBeUndefined();
    expect(store.list("session", 1)).toEqual([first]);
  });

  it("preserves newer text or attachments while keeping the failed recovery available", () => {
    const store = createChatDeliveryRecoveryStore({
      createRequestId: () => "retry-request-1",
      createDeliveryId: () => "retry-delivery-1",
    });
    store.activate("session", 1);
    const result = store.recordFailure(failure({
      currentComposer: composer({ text: "newer text", images: [image("newer.png")] }, 2),
    }))!;

    expect(result.restore).toMatchObject({
      status: "preserved",
      reason: "newer-composer-content",
    });
    expect(store.list("session", 1)).toHaveLength(1);
    expect(store.list("session", 1)[0]?.draft).toEqual(draft());
  });

  it("does not restore after a newer revision intentionally clears the composer", () => {
    const store = createChatDeliveryRecoveryStore();
    store.activate("session", 1);
    const result = store.recordFailure(failure({
      currentComposer: composer({ text: "", images: [] }, 9),
      allowedEmptyRevisions: [2],
    }))!;

    expect(result.restore).toMatchObject({
      status: "preserved",
      reason: "newer-composer-content",
    });
  });

  it("creates one new retry identity and makes a repeated retry idempotent", () => {
    const store = createChatDeliveryRecoveryStore({
      createRequestId: () => "retry-request-1",
      createDeliveryId: () => "retry-delivery-1",
    });
    store.activate("session", 1);
    const failed = store.recordFailure(failure())!.record;
    const first = store.retry({
      sessionId: "session",
      generation: 1,
      recoveryId: failed.id,
      currentComposer: composer(draft()),
    });
    const second = store.retry({
      sessionId: "session",
      generation: 1,
      recoveryId: failed.id,
      currentComposer: composer(draft()),
    });

    expect(first).toMatchObject({
      recoveryId: failed.id,
      requestId: "retry-request-1",
      deliveryId: "retry-delivery-1",
      draft: draft(),
      clearComposer: true,
      isNew: true,
    });
    expect(second).toMatchObject({
      requestId: "retry-request-1",
      deliveryId: "retry-delivery-1",
      isNew: false,
    });
    expect(store.list("session", 1)).toMatchObject([{ status: "retrying" }]);
  });

  it("allocates retry identities away from every reserved request and delivery ID", () => {
    const store = createChatDeliveryRecoveryStore({
      createRequestId: () => "delivery-2",
      createDeliveryId: () => "request-2",
    });
    store.activate("session", 1);
    const first = store.recordFailure(failure())!.record;
    store.recordFailure(failure({ requestId: "request-2", deliveryId: "delivery-2" }));

    const retry = store.retry({
      sessionId: "session", generation: 1, recoveryId: first.id, currentComposer: composer(draft()),
    });
    expect(retry).toMatchObject({ isNew: true });
    expect(retry?.requestId).not.toBe("request-2");
    expect(retry?.requestId).not.toBe("delivery-2");
    expect(retry?.deliveryId).not.toBe("request-2");
    expect(retry?.deliveryId).not.toBe("delivery-2");
  });

  it("rejects a second actionable recovery at the record cap without evicting the first", () => {
    const store = createChatDeliveryRecoveryStore({ maxRecordsPerScope: 1 });
    store.activate("session", 1);
    const first = store.recordFailure(failure())!.record;
    expect(store.recordFailure(failure({ requestId: "request-2", deliveryId: "delivery-2" }))).toBeUndefined();
    expect(store.list("session", 1)).toEqual([first]);
  });

  it("reconciles an exact late canonical identity and retains ambiguity for content-only lineage", () => {
    const store = createChatDeliveryRecoveryStore();
    store.activate("session", 1);
    const original = store.recordFailure(failure())!.record;
    const retry = store.retry({
      sessionId: "session", generation: 1, recoveryId: original.id, currentComposer: composer(draft()),
    })!;
    expect(store.list("session", 1)[0]).toMatchObject({
      retryRequestId: retry.requestId, retryDeliveryId: retry.deliveryId,
    });
    // A recovery ledger never guesses whether an unlabelled canonical belongs
    // to the original or replacement; the caller's delivery store resolves
    // that ambiguity before invoking this exact-identity cleanup.
    expect(store.reconcileCanonical({
      sessionId: "session", generation: 1,
      requestId: "unrelated", deliveryId: "unrelated",
    })).toBe(false);
    expect(store.reconcileCanonical({
      sessionId: "session", generation: 1,
      requestId: retry.requestId, deliveryId: retry.deliveryId,
    })).toBe(true);
    expect(store.list("session", 1)).toEqual([]);
  });

  it("keeps newer composer content and does not clear it when retrying", () => {
    const store = createChatDeliveryRecoveryStore({
      createRequestId: () => "retry-request-1",
      createDeliveryId: () => "retry-delivery-1",
    });
    store.activate("session", 1);
    const failed = store.recordFailure(failure())!.record;
    const retry = store.retry({
      sessionId: "session",
      generation: 1,
      recoveryId: failed.id,
      currentComposer: composer({ text: "newer", images: [] }, 2),
    });

    expect(retry).toMatchObject({
      clearComposer: false,
      draft: draft(),
    });
  });

  it("dismisses only the selected failed delivery", () => {
    const store = createChatDeliveryRecoveryStore();
    store.activate("session", 1);
    const first = store.recordFailure(failure())!.record;
    const second = store.recordFailure(failure({
      requestId: "request-2",
      deliveryId: "delivery-2",
      draft: draft("second", false),
    }))!.record;

    expect(store.dismiss({ sessionId: "session", generation: 1, recoveryId: first.id })).toEqual(first);
    expect(store.list("session", 1)).toMatchObject([{ id: second.id, draft: draft("second", false) }]);
  });

  it("uses the same restore policy for confirmed cancel and creates no recovery for failed cancel", () => {
    const store = createChatDeliveryRecoveryStore();
    store.activate("session", 1);
    expect(store.recordCancellation({
      sessionId: "session",
      generation: 1,
      requestId: "request-1",
      deliveryId: "delivery-1",
      draft: draft(),
      error: "Message canceled.",
      cause: "canceled",
      currentComposer: composer({ text: "", images: [] }),
      confirmed: false,
    })).toBeUndefined();
    const result = store.recordCancellation({
      sessionId: "session",
      generation: 1,
      requestId: "request-1",
      deliveryId: "delivery-1",
      draft: draft(),
      error: "Message canceled.",
      cause: "canceled",
      currentComposer: composer({ text: "", images: [] }),
      confirmed: true,
    })!;

    expect(result?.record).toMatchObject({ status: "canceled", cause: "canceled" });
    expect(result?.restore).toMatchObject({ status: "restored", draft: draft() });
  });

  it("preserves inactive actionable recovery scopes at the explicit scope bound", () => {
    const store = createChatDeliveryRecoveryStore({ maxScopes: 2 });
    store.activate("first", 1);
    store.recordFailure(failure({ sessionId: "first", generation: 1 }));
    store.activate("second", 2);
    store.recordFailure(failure({ sessionId: "second", generation: 2, deliveryId: "delivery-2" }));
    store.activate("third", 3);

    store.activate("first", 1);
    expect(store.list("first", 1)).toMatchObject([{ deliveryId: "delivery-1" }]);
    store.activate("second", 2);
    expect(store.list("second", 2)).toMatchObject([{ deliveryId: "delivery-2" }]);
    expect(store.list("third", 3)).toEqual([]);
  });

  it("rejects stale session or generation operations", () => {
    const store = createChatDeliveryRecoveryStore();
    store.activate("first", 1);
    const first = store.recordFailure(failure({ sessionId: "first" }))!.record;
    store.activate("second", 2);

    expect(store.retry({
      sessionId: "first",
      generation: 1,
      recoveryId: first.id,
      currentComposer: composer({ text: "", images: [] }),
    })).toBeUndefined();
    expect(store.dismiss({ sessionId: "first", generation: 1, recoveryId: first.id })).toBeUndefined();
    expect(store.list("second", 2)).toEqual([]);
  });
});
