import { describe, expect, it } from "vitest";
import type { ChatPage } from "@agent-visor/protocol";
import {
  CHAT_DELIVERY_TTL_MS,
  createPendingChatDeliveryStore,
  type DeliveryClock,
  type SubmittedChatDraft,
} from "./chat-delivery.js";
import { createChatDeliveryRecoveryStore } from "./chat-delivery-recovery.js";
import { createChatSessionController } from "./chat-session-controller.js";

class TestClock implements DeliveryClock {
  constructor(private current = 1_700_000_000_000) {}

  now(): number { return this.current; }

  advance(milliseconds: number): void { this.current += milliseconds; }
}

const image = (name: string) => ({
  name,
  mimeType: "image/png" as const,
  byteLength: 8,
  data: "iVBORw0KGgo=",
});

const submittedDraft = (text = "hello"): SubmittedChatDraft => ({
  text,
  images: [image("diagram.png")],
});

const emptyPage = (sessionId: string, canCancel = false): ChatPage => ({
  type: "chat_page",
  sessionId,
  items: [],
  hasMoreBefore: false,
  capabilities: {
    canSendText: true,
    canSendImages: true,
    canCancel,
    canApprove: false,
    canAnswer: false,
  },
  pendingAction: null,
});

const transport = {
  close: () => undefined,
  send: () => true,
};

function controllerWith(clock = new TestClock()) {
  let requestIndex = 0;
  let deliveryIndex = 0;
  return createChatSessionController({
    onState: () => undefined,
    onSlashCommands: () => undefined,
    onOpenLatest: () => undefined,
  }, {
    deliveryClock: clock,
    deliveryStore: undefined,
    recoveryStore: createChatDeliveryRecoveryStore({
      clock,
      createRequestId: () => `request-${++requestIndex}`,
      createDeliveryId: () => `delivery-${++deliveryIndex}`,
    }),
    createRequestId: () => `request-${++requestIndex}`,
    createDeliveryId: () => `delivery-${++deliveryIndex}`,
  });
}

function sendAck(
  requestId: string,
  deliveryId: string,
  generation: number,
  ok = false,
): string {
  return JSON.stringify({
    type: "chat_action_result",
    id: requestId,
    action: "send",
    sessionId: "session",
    generation,
    deliveryId,
    ok,
    ...(ok ? {} : { error: "Provider rejected the message." }),
  });
}

function setup(
  controller: ReturnType<typeof createChatSessionController>,
  section: "working" | "ready" = "working",
  canCancel = false,
): number {
  const generation = controller.activate("session", section);
  controller.receive(generation, JSON.stringify(emptyPage("session", canCancel)), transport);
  return generation;
}

describe("Chat session recovery integration", () => {
  it("surfaces one failed delivery, restores its exact attachment snapshot, and retries once", () => {
    const controller = controllerWith();
    const generation = setup(controller);
    const draft = submittedDraft();
    controller.noteComposerDraft(generation, { text: "", images: [] });
    const delivery = controller.beginDelivery(generation, draft)!;

    controller.receive(generation, sendAck(delivery.requestId, delivery.deliveryId, generation), transport);
    const state = controller.currentState();
    expect(state.page?.items).toMatchObject([{ id: delivery.optimisticRowId, text: "hello" }]);
    expect(state.recovery).toMatchObject([{
      id: `session:${generation}:${delivery.deliveryId}`,
      status: "failed",
      draft,
    }]);
    expect(state.recoveryCommand).toMatchObject({
      type: "restore",
      draft,
      expectedRevision: 1,
    });

    controller.noteComposerDraft(generation, draft);
    const recoveryId = state.recovery![0]!.id;
    const retry = controller.retryRecovery(generation, recoveryId)!;
    expect(retry).toMatchObject({
      isNew: true,
      send: true,
      draft,
      requestId: "request-2",
      deliveryId: "delivery-2",
    });
    const duplicate = controller.retryRecovery(generation, recoveryId)!;
    expect(duplicate).toMatchObject({
      isNew: false,
      send: false,
      requestId: "request-2",
      deliveryId: "delivery-2",
    });

    controller.receive(generation, sendAck("request-2", "delivery-2", generation, true), transport);
    expect(controller.currentState().recovery).toMatchObject([{
      status: "awaiting-canonical",
      retryRequestId: "request-2",
      retryDeliveryId: "delivery-2",
    }]);
  });

  it("restores the snapshot when a retried send fails after its guarded clear", () => {
    const controller = controllerWith();
    const generation = setup(controller);
    const draft = submittedDraft("retry again");
    controller.noteComposerDraft(generation, { text: "", images: [] });
    const initial = controller.beginDelivery(generation, draft)!;
    controller.receive(generation, sendAck(initial.requestId, initial.deliveryId, generation), transport);

    const firstRecovery = controller.currentState().recovery![0]!;
    controller.noteComposerDraft(generation, draft);
    const retry = controller.retryRecovery(generation, firstRecovery.id)!;
    expect(retry.clearComposer).toBe(true);
    // The Chat component applies the guarded clear command before the retry's
    // action result arrives, advancing the controller's revision by one.
    controller.noteComposerDraft(generation, { text: "", images: [] });
    controller.receive(generation, sendAck(retry.requestId, retry.deliveryId, generation), transport);

    expect(controller.currentState().recovery).toMatchObject([{
      status: "failed",
      draft,
    }]);
    expect(controller.currentState().recoveryCommand).toMatchObject({
      type: "restore",
      draft,
    });
  });

  it("preserves newer text and attachments instead of restoring over it", () => {
    const controller = controllerWith();
    const generation = setup(controller);
    const newer = { text: "newer", images: [image("newer.png")] };
    controller.noteComposerDraft(generation, newer);
    const delivery = controller.beginDelivery(generation, submittedDraft())!;
    controller.receive(generation, sendAck(delivery.requestId, delivery.deliveryId, generation), transport);

    expect(controller.currentState().recoveryCommand).toBeUndefined();
    expect(controller.currentState().recovery).toMatchObject([{ status: "failed" }]);
    controller.noteComposerDraft(generation, newer);
    const recoveryId = controller.currentState().recovery![0]!.id;
    expect(controller.retryRecovery(generation, recoveryId)).toMatchObject({ clearComposer: false });
  });

  it("expires a pending delivery into a recoverable failure and keeps dismissal scoped", () => {
    const clock = new TestClock();
    const controller = controllerWith(clock);
    const generation = setup(controller);
    controller.noteComposerDraft(generation, { text: "", images: [] });
    const first = controller.beginDelivery(generation, submittedDraft("first"))!;
    const second = controller.beginDelivery(generation, submittedDraft("second"))!;
    clock.advance(CHAT_DELIVERY_TTL_MS);
    controller.expireDeliveries(generation);

    expect(controller.currentState().recovery).toHaveLength(2);
    const firstRecovery = controller.currentState().recovery!.find((item) => item.deliveryId === first.deliveryId)!;
    expect(controller.dismissRecovery(generation, firstRecovery.id)).toBe(true);
    expect(controller.currentState().recovery).toMatchObject([{ deliveryId: second.deliveryId }]);
    expect(controller.currentState().page?.items).toMatchObject([{ text: "second" }]);
  });

  it("does not expire or restore a prior session delivery after switching A to B", () => {
    const clock = new TestClock();
    const controller = controllerWith(clock);
    const firstGeneration = controller.activate("first", "working");
    controller.receive(firstGeneration, JSON.stringify(emptyPage("first")), transport);
    controller.noteComposerDraft(firstGeneration, { text: "", images: [] });
    const firstDraft = submittedDraft("first session");
    const firstDelivery = controller.beginDelivery(firstGeneration, firstDraft)!;

    const secondGeneration = controller.activate("second", "working");
    controller.receive(secondGeneration, JSON.stringify(emptyPage("second")), transport);
    controller.noteComposerDraft(secondGeneration, { text: "", images: [] });
    clock.advance(CHAT_DELIVERY_TTL_MS);

    expect(controller.expireDeliveries(secondGeneration)).toEqual([]);
    expect(controller.currentState().sessionId).toBe("second");
    expect(controller.currentState().recovery).toBeUndefined();
    expect(controller.currentState().recoveryCommand).toBeUndefined();
    expect(firstDelivery.draft).toEqual(firstDraft);

    const firstAgainGeneration = controller.activate("first", "working");
    controller.receive(firstAgainGeneration, JSON.stringify(emptyPage("first")), transport);
    expect(controller.currentState().page?.items).toMatchObject([{
      id: firstDelivery.optimisticRowId,
      text: firstDraft.text,
      images: firstDraft.images,
    }]);
    expect(controller.expireDeliveries(firstAgainGeneration)).toMatchObject([{
      deliveryId: firstDelivery.deliveryId,
      status: "failed",
    }]);
    expect(controller.currentState().recovery).toMatchObject([{
      deliveryId: firstDelivery.deliveryId,
      status: "failed",
    }]);

    controller.noteComposerDraft(firstAgainGeneration, { text: "", images: [] });
    const currentDraft = submittedDraft("current first session");
    const currentDelivery = controller.beginDelivery(firstAgainGeneration, currentDraft)!;
    clock.advance(CHAT_DELIVERY_TTL_MS);

    expect(controller.expireDeliveries(firstAgainGeneration)).toMatchObject([{
        sessionId: "first",
        generation: firstAgainGeneration,
        deliveryId: currentDelivery.deliveryId,
        draft: currentDraft,
        status: "failed",
      }]);
    expect(controller.currentState().recovery).toMatchObject([
      { draft: firstDraft, deliveryId: firstDelivery.deliveryId },
      { draft: currentDraft, deliveryId: currentDelivery.deliveryId },
    ]);
  });

  it("restores only after confirmed cancel and never after cancel failure", () => {
    const controller = controllerWith();
    const generation = setup(controller, "working", true);
    controller.noteComposerDraft(generation, { text: "", images: [] });
    const delivery = controller.beginDelivery(generation, submittedDraft())!;
    controller.receive(generation, JSON.stringify({
      ...emptyPage("session", true),
      capabilities: { ...emptyPage("session", true).capabilities, cancelDeliveryId: delivery.deliveryId },
    }), transport);
    expect(controller.requestCancel(generation, transport)).toBe(true);
    controller.receive(generation, JSON.stringify({
      type: "chat_action_result",
      id: "request-2",
      action: "cancel",
      sessionId: "session",
      generation,
      deliveryId: delivery.deliveryId,
      ok: true,
    }), transport);
    expect(controller.currentState().recovery).toMatchObject([{ status: "canceled" }]);
    expect(controller.currentState().page?.items).toEqual([]);

    const next = controller.activate("session", "working");
    controller.receive(next, JSON.stringify(emptyPage("session", true)), transport);
    controller.noteComposerDraft(next, { text: "", images: [] });
    const failedCancelDelivery = controller.beginDelivery(next, submittedDraft("failed cancel"))!;
    controller.receive(next, JSON.stringify({
      ...emptyPage("session", true),
      capabilities: { ...emptyPage("session", true).capabilities, cancelDeliveryId: failedCancelDelivery.deliveryId },
    }), transport);
    expect(controller.requestCancel(next, transport)).toBe(true);
    controller.receive(next, JSON.stringify({
      type: "chat_action_result",
      id: "request-5",
      action: "cancel",
      sessionId: "session",
      generation: next,
      deliveryId: failedCancelDelivery.deliveryId,
      ok: false,
      error: "The turn could not be cancelled.",
    }), transport);
    // Canceled content is session-owned and is rehydrated when the renderer
    // returns under a new generation; a failed later cancel adds no record.
    expect(controller.currentState().recovery).toMatchObject([{
      deliveryId: "delivery-1",
      status: "canceled",
    }]);
    expect(controller.currentState().error).toBe("The turn could not be cancelled.");
  });

  it("ignores stale recovery operations after a session generation switch", () => {
    const controller = controllerWith();
    const first = setup(controller);
    const delivery = controller.beginDelivery(first, submittedDraft())!;
    controller.receive(first, sendAck(delivery.requestId, delivery.deliveryId, first), transport);
    const recoveryId = controller.currentState().recovery![0]!.id;
    const second = controller.activate("other", "ready");
    controller.receive(second, JSON.stringify(emptyPage("other")), transport);

    expect(controller.retryRecovery(first, recoveryId)).toBeUndefined();
    expect(controller.dismissRecovery(first, recoveryId)).toBe(false);
    controller.receive(first, sendAck(delivery.requestId, delivery.deliveryId, first), transport);
    expect(controller.currentState().sessionId).toBe("other");
    expect(controller.currentState().recovery).toBeUndefined();
  });

  it("rehydrates a retry across A to B to A and settles its exact acknowledgement", () => {
    const controller = controllerWith();
    const firstGeneration = setup(controller);
    const draft = submittedDraft("retry while away");
    controller.noteComposerDraft(firstGeneration, draft);
    const original = controller.beginDelivery(firstGeneration, draft)!;
    controller.receive(firstGeneration, sendAck(original.requestId, original.deliveryId, firstGeneration), transport);
    const recoveryId = controller.currentState().recovery![0]!.id;
    controller.noteComposerDraft(firstGeneration, draft);
    const retry = controller.retryRecovery(firstGeneration, recoveryId)!;

    const secondGeneration = controller.activate("other", "working");
    controller.receive(secondGeneration, JSON.stringify(emptyPage("other")), transport);
    // An acknowledgement that arrives on the retired A generation while B is
    // active must not settle the retry or mutate B's recovery state.
    controller.receive(firstGeneration, sendAck(retry.requestId, retry.deliveryId, firstGeneration, true), transport);
    const returnedGeneration = setup(controller);

    expect(controller.currentState().recovery).toMatchObject([{
      id: `session:${returnedGeneration}:${original.deliveryId}`,
      status: "retrying",
      retryRequestId: retry.requestId,
      retryDeliveryId: retry.deliveryId,
    }]);
    expect(controller.currentState().page?.items).toMatchObject([{
      deliveryId: retry.deliveryId,
      text: draft.text,
    }]);

    controller.receive(
      returnedGeneration,
      sendAck(retry.requestId, retry.deliveryId, returnedGeneration, true),
      transport,
    );
    expect(controller.currentState().recovery).toMatchObject([{
      status: "awaiting-canonical",
      retryRequestId: retry.requestId,
      retryDeliveryId: retry.deliveryId,
    }]);
  });

  it("settles a retry from an exact canonical page on the first page after A to B to A", () => {
    const controller = controllerWith();
    const firstGeneration = setup(controller);
    const draft = submittedDraft("canonical while away");
    controller.noteComposerDraft(firstGeneration, draft);
    const original = controller.beginDelivery(firstGeneration, draft)!;
    controller.receive(firstGeneration, sendAck(original.requestId, original.deliveryId, firstGeneration), transport);
    const recoveryId = controller.currentState().recovery![0]!.id;
    controller.noteComposerDraft(firstGeneration, draft);
    const retry = controller.retryRecovery(firstGeneration, recoveryId)!;

    const secondGeneration = controller.activate("other", "working");
    controller.receive(secondGeneration, JSON.stringify(emptyPage("other")), transport);
    const returnedGeneration = controller.activate("session", "working");
    controller.requestLatest(returnedGeneration, "return-latest");
    controller.receive(returnedGeneration, JSON.stringify({
      ...emptyPage("session"),
      requestId: "return-latest",
      mode: "latest",
      items: [{
        id: "canonical-while-away",
        kind: "user",
        text: draft.text,
        images: draft.images,
        requestId: retry.requestId,
        deliveryId: retry.deliveryId,
        timestamp: new Date().toISOString(),
      }],
    }), transport);

    expect(controller.currentState().recovery).toBeUndefined();
    expect(controller.currentState().page?.items).toMatchObject([{
      id: "canonical-while-away",
      requestId: retry.requestId,
      deliveryId: retry.deliveryId,
    }]);
  });

  it("expires an acknowledged retry as uncertain and only exact canonical proof clears it", () => {
    const clock = new TestClock();
    const controller = controllerWith(clock);
    const generation = setup(controller);
    const draft = submittedDraft("canonical deadline");
    controller.noteComposerDraft(generation, draft);
    const original = controller.beginDelivery(generation, draft)!;
    controller.receive(generation, sendAck(original.requestId, original.deliveryId, generation), transport);
    const recoveryId = controller.currentState().recovery![0]!.id;
    controller.noteComposerDraft(generation, draft);
    const retry = controller.retryRecovery(generation, recoveryId)!;
    controller.receive(generation, sendAck(retry.requestId, retry.deliveryId, generation, true), transport);

    expect(controller.currentState().recovery).toMatchObject([{ status: "awaiting-canonical" }]);
    clock.advance(CHAT_DELIVERY_TTL_MS);
    expect(controller.expireDeliveries(generation)).toMatchObject([{
      deliveryId: retry.deliveryId,
      status: "uncertain",
    }]);
    expect(controller.currentState().recovery).toMatchObject([{
      id: recoveryId,
      status: "uncertain",
    }]);
    expect(controller.currentState().canCancelForActiveDelivery).toBeUndefined();

    controller.receive(generation, JSON.stringify({
      ...emptyPage("session"),
      requestId: "request-3",
      mode: "latest",
      items: [{
        id: "canonical-after-deadline",
        kind: "user",
        text: draft.text,
        images: draft.images,
        requestId: retry.requestId,
        deliveryId: retry.deliveryId,
        timestamp: new Date(clock.now() + 1).toISOString(),
      }],
    }), transport);
    expect(controller.currentState().recovery).toBeUndefined();
  });

  it("rehydrates session-owned recovery with attachments across A to B to A", () => {
    const controller = controllerWith();
    const first = setup(controller);
    const draft = submittedDraft("keep this attachment");
    controller.noteComposerDraft(first, { text: "", images: [] });
    const delivery = controller.beginDelivery(first, draft)!;
    controller.receive(first, sendAck(delivery.requestId, delivery.deliveryId, first, false), transport);
    const recoveryId = controller.currentState().recovery?.[0]?.id;
    expect(recoveryId).toBeDefined();

    const second = controller.activate("other", "working");
    expect(controller.currentState().sessionId).toBe("other");
    expect(controller.currentState().recovery).toBeUndefined();
    controller.receive(second, JSON.stringify(emptyPage("other")), transport);

    const returned = controller.activate("session", "working");
    controller.receive(returned, JSON.stringify(emptyPage("session")), transport);
    expect(controller.currentState().recovery).toMatchObject([{
      id: `session:${returned}:${delivery.deliveryId}`,
      draft,
    }]);
    expect(controller.currentState().recovery?.[0]?.id).not.toBe(recoveryId);
    expect(controller.currentState().recovery?.every((item) => item.sessionId === "session")).toBe(true);
  });

  it("preserves a failed recovery when replacement cannot begin at the delivery cap", () => {
    const clock = new TestClock();
    const deliveryStore = createPendingChatDeliveryStore({
      clock,
      maxDeliveriesPerScope: 1,
    });
    const controller = createChatSessionController({
      onState: () => undefined,
      onSlashCommands: () => undefined,
      onOpenLatest: () => undefined,
    }, {
      deliveryClock: clock,
      deliveryStore,
      recoveryStore: createChatDeliveryRecoveryStore({
        clock,
        createRequestId: () => "retry-request",
        createDeliveryId: () => "retry-delivery",
      }),
      createRequestId: (() => {
        let serial = 0;
        return () => `request-${++serial}`;
      })(),
      createDeliveryId: (() => {
        let serial = 0;
        return () => `delivery-${++serial}`;
      })(),
    });
    const generation = setup(controller);
    controller.noteComposerDraft(generation, { text: "", images: [] });
    const first = controller.beginDelivery(generation, submittedDraft("first"))!;
    controller.receive(generation, sendAck(first.requestId, first.deliveryId, generation), transport);
    const recoveryId = controller.currentState().recovery![0]!.id;
    controller.noteComposerDraft(generation, submittedDraft("first"));
    // Simulate the bounded delivery store rejecting replacement (for example,
    // because a live record filled its cap between the policy decision and
    // begin). The recovery source must remain actionable.
    deliveryStore.begin = () => undefined;

    expect(controller.retryRecovery(generation, recoveryId)).toBeUndefined();
    expect(controller.currentState().recovery).toMatchObject([{
      id: recoveryId,
      status: "failed",
    }]);
    expect(deliveryStore.get("session", generation)).toMatchObject([{
      deliveryId: first.deliveryId,
      status: "failed",
    }]);
  });

  it("dismisses a recovery record when a late canonical row proves delivery", () => {
    const controller = controllerWith();
    const generation = setup(controller);
    controller.noteComposerDraft(generation, { text: "", images: [] });
    const delivery = controller.beginDelivery(generation, submittedDraft("late"))!;
    controller.receive(generation, sendAck(delivery.requestId, delivery.deliveryId, generation), transport);
    expect(controller.currentState().recovery).toHaveLength(1);

    controller.receive(generation, JSON.stringify({
      ...emptyPage("session"),
      items: [{
        id: "canonical-late",
        kind: "user",
        text: "late",
        images: [],
        requestId: delivery.requestId,
        deliveryId: delivery.deliveryId,
      }],
    }), transport);

    expect(controller.currentState().recovery).toBeUndefined();
    expect(controller.currentState().page?.items).toMatchObject([{
      id: "canonical-late",
      requestId: delivery.requestId,
      deliveryId: delivery.deliveryId,
    }]);
  });

  it("keeps retry lineage fail-closed for an ambiguous content-only canonical row", () => {
    const clock = new TestClock();
    const controller = controllerWith(clock);
    const generation = setup(controller);
    controller.noteComposerDraft(generation, { text: "lineage", images: [] });
    const original = controller.beginDelivery(generation, submittedDraft("lineage"))!;
    controller.receive(generation, sendAck(original.requestId, original.deliveryId, generation), transport);
    const recoveryId = controller.currentState().recovery![0]!.id;
    controller.noteComposerDraft(generation, submittedDraft("lineage"));
    const retry = controller.retryRecovery(generation, recoveryId)!;

    controller.receive(generation, JSON.stringify({
      ...emptyPage("session"),
      items: [{ id: "ambiguous-canonical", kind: "user", text: "lineage", images: [] }],
    }), transport);

    expect(controller.currentState().recovery).toMatchObject([{
      id: recoveryId,
      status: "retrying",
      retryRequestId: retry.requestId,
      retryDeliveryId: retry.deliveryId,
    }]);
    expect(controller.currentState().page?.items.filter((item) => item.kind === "user")).toHaveLength(2);
  });

  it("settles only the exact original or exact retry canonical in retry lineage", () => {
    const originalController = controllerWith();
    const originalGeneration = setup(originalController);
    originalController.noteComposerDraft(originalGeneration, { text: "", images: [] });
    const original = originalController.beginDelivery(originalGeneration, submittedDraft("same"))!;
    originalController.receive(originalGeneration, sendAck(original.requestId, original.deliveryId, originalGeneration), transport);
    const originalRecovery = originalController.currentState().recovery![0]!.id;
    originalController.noteComposerDraft(originalGeneration, submittedDraft("same"));
    const replacement = originalController.retryRecovery(originalGeneration, originalRecovery)!;

    originalController.receive(originalGeneration, JSON.stringify({
      ...emptyPage("session"),
      items: [{
        id: "canonical-original",
        kind: "user",
        text: "same",
        images: [],
        requestId: original.requestId,
        deliveryId: original.deliveryId,
      }],
    }), transport);
    expect(originalController.currentState().recovery).toBeUndefined();
    expect(originalController.currentState().page?.items).toMatchObject([
      { id: "canonical-original", requestId: original.requestId },
      { id: replacement.delivery.optimisticRowId, requestId: replacement.requestId },
    ]);

    const retryController = controllerWith();
    const retryGeneration = setup(retryController);
    retryController.noteComposerDraft(retryGeneration, { text: "", images: [] });
    const retryOriginal = retryController.beginDelivery(retryGeneration, submittedDraft("same"))!;
    retryController.receive(retryGeneration, sendAck(retryOriginal.requestId, retryOriginal.deliveryId, retryGeneration), transport);
    const retryRecovery = retryController.currentState().recovery![0]!.id;
    retryController.noteComposerDraft(retryGeneration, submittedDraft("same"));
    const retried = retryController.retryRecovery(retryGeneration, retryRecovery)!;
    retryController.receive(retryGeneration, JSON.stringify({
      ...emptyPage("session"),
      items: [{
        id: "canonical-retry",
        kind: "user",
        text: "same",
        images: [],
        requestId: retried.requestId,
        deliveryId: retried.deliveryId,
      }],
    }), transport);
    expect(retryController.currentState().recovery).toBeUndefined();
    expect(retryController.currentState().page?.items).toMatchObject([
      { id: "canonical-retry", requestId: retried.requestId },
    ]);
  });

  it("does not consume either identical canonical row without lineage identity, then expires the retry once", () => {
    const clock = new TestClock();
    const controller = controllerWith(clock);
    const generation = setup(controller);
    controller.noteComposerDraft(generation, { text: "", images: [] });
    const original = controller.beginDelivery(generation, submittedDraft("same"))!;
    controller.receive(generation, sendAck(original.requestId, original.deliveryId, generation), transport);
    const recoveryId = controller.currentState().recovery![0]!.id;
    controller.noteComposerDraft(generation, submittedDraft("same"));
    const retry = controller.retryRecovery(generation, recoveryId)!;
    controller.receive(generation, JSON.stringify({
      ...emptyPage("session"),
      items: [
        { id: "canonical-one", kind: "user", text: "same", images: [] },
        { id: "canonical-two", kind: "user", text: "same", images: [] },
      ],
    }), transport);
    expect(controller.currentState().recovery).toMatchObject([{ id: recoveryId, status: "retrying" }]);

    clock.advance(CHAT_DELIVERY_TTL_MS);
    expect(controller.expireDeliveries(generation)).toMatchObject([{
      requestId: retry.requestId,
      deliveryId: retry.deliveryId,
      status: "failed",
    }]);
    expect(controller.currentState().recovery).toMatchObject([{
      requestId: retry.requestId,
      deliveryId: retry.deliveryId,
      status: "failed",
    }]);
  });
});
