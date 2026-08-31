import { createHash, randomUUID } from "node:crypto";
import os from "node:os";
import path from "node:path";
import {
  chatImageBase64Bytes,
  type ChatImage,
  type ChatPage,
  type NativeHelperTerminalTarget,
} from "@agent-visor/protocol";
import {
  activeCodexTurnDeliveryId,
  sendCodexTurn,
  stopCodexTurn,
  type CodexActionRegistrar,
} from "./codex-turn.js";
import type { NativeHelperAdapter } from "./native-helper.js";
import {
  ChatImageLeaseStore,
  type ChatDeliveryImageScope,
  type MaterializedChatImages,
} from "./chat-image-leases.js";
import type {
  ChatDeliveryEvidence,
  ChatSendCurrentness,
  DiscoveredProviderSession,
  SessionControls,
} from "./sessions.js";
import { normalizeChatText } from "./chat.js";
import { isVerifiableProcessInstanceToken } from "./providers/shared.js";

type ActiveTerminalDelivery = {
  sessionId: string;
  deliveryId: string;
  generation: number;
  targetFingerprint: string;
  baselineUserEntryIds: Set<string>;
  baselineComplete: boolean;
  submittedText: string;
  /** Immutable provider evidence for identity-less image reconciliation. */
  submittedImageFingerprints?: string[];
  /** Pi emits image paths in the canonical prompt instead of image blocks. */
  imageEvidenceMode: "canonical_images" | "prompt_paths";
  requestId?: string;
  authoritativeComplete?: boolean;
  submittedAt?: string;
  boundUserEntryId?: string;
  evidenceExpiresAt: number;
  expiryTimer?: ReturnType<typeof setTimeout>;
};

type ActionReservation = {
  epoch: number;
  active: boolean;
};

// ponytail: bound queued + running provider actions per session. Raise this
// only with a memory/latency review; rejection happens before image
// materialization so a saturated lane cannot retain unbounded user payloads.
export const MAX_NATIVE_SESSION_ACTIONS_PER_SESSION = 32;
// ponytail: baseline IDs and submitted text are bounded evidence metadata.
// Keep this ledger cap coordinated with the action cap and provider page cap;
// admission rejects when every retained record is still actionable.
export const MAX_TERMINAL_DELIVERY_RECORDS = 64;
const terminalEvidenceTTL = 5 * 60_000;

export class NativeSessionControls implements SessionControls {
  private focusSerial = 0;
  // Provider actions are serialized per session. A queued terminal send must
  // register its delivery immediately before its helper write; otherwise a
  // rapid A/B submission can let B replace the cancellation identity while A
  // is still waiting on the queue. Different sessions remain independent.
  private readonly actionQueueBySession = new Map<string, Promise<void>>();
  // An epoch invalidates work which was queued before repository removal. Keep
  // a bounded tombstone window so a removed session cannot retain unbounded
  // bookkeeping while still preventing an old queued action from reviving it.
  private readonly actionEpochBySession = new Map<string, number>();
  // Keep operation-owned reservations separate from the bounded tombstone
  // map. A delayed completion must remain invalid even if 512 unrelated
  // sessions evict the old session's numeric epoch and its ID is reused.
  // ponytail: reservations live only until their promise settles; add a
  // durable operation journal before allowing them to outlive an operation.
  private readonly actionReservationsBySession = new Map<string, Set<ActionReservation>>();
  // A terminal can have a queued follow-up while an earlier provider turn is
  // still the only confirmed cancellable turn. Keep every exact delivery
  // until its own evidence or failure settles; a singleton slot lets B steal
  // A's Stop identity before B has a canonical row.
  private readonly terminalDeliveriesBySession = new Map<string, Map<string, ActiveTerminalDelivery>>();
  private readonly terminalGenerationBySession = new Map<string, number>();
  private readonly knownTerminalTargetBySession = new Map<string, string>();
  private readonly codexDeliveryBySession = new Map<string, string>();
  // A canonical transcript ID is global evidence, not a per-page hint. Keep
  // a bounded insertion-ordered history so replaying an earlier page cannot
  // bind the same provider row to a later delivery.
  // ponytail: this 512-entry window must stay aligned with page/reconcile
  // limits; use a durable provider cursor before increasing it.
  private readonly consumedCanonicalUserIDsBySession = new Map<string, Map<string, string>>();
  private readonly imageLeases: ChatImageLeaseStore;

  constructor(
    private readonly helper: NativeHelperAdapter,
    private readonly imageRoot = path.join(os.tmpdir(), `agent-visor-images-${process.getuid?.() ?? 0}`),
    private readonly sendCodex = sendCodexTurn,
    private readonly openURL: (url: string) => Promise<void> = async () => {
      throw new Error("Exact application focus is unavailable.");
    },
    private readonly registerCodexAction?: CodexActionRegistrar,
    private readonly cancelCodex = stopCodexTurn,
  ) {
    this.imageLeases = new ChatImageLeaseStore({ root: imageRoot });
  }

  isAvailable(): boolean {
    return this.helper.isAvailable?.() !== false;
  }

  focus(session: DiscoveredProviderSession): Promise<void> {
    const serial = ++this.focusSerial;
    return this.queueAction(session.id, async () => {
      if (serial !== this.focusSerial) return;
      const control = session.controlTarget;
      if (!control) throw new Error("Exact session focus is unavailable.");
      if (control.kind === "url") await this.openURL(control.url);
      else if (control.kind === "terminal") await this.helper.focusTerminal(control.target);
      else await this.helper.focus(control.target);
    });
  }

  send(
    session: DiscoveredProviderSession,
    text: string,
    images: ChatImage[],
    deliveryId?: string,
    evidence?: ChatDeliveryEvidence,
    isCurrent: ChatSendCurrentness = () => true,
  ): Promise<void> {
    const terminalTarget = session.controlTarget?.kind === "terminal"
      ? session.controlTarget.target
      : undefined;
    const terminalDelivery = session.messageTransport === "terminal"
      && deliveryId
      && evidence
      ? {
        imageEvidenceMode: session.provider === "pi" && images.length > 0
          ? "prompt_paths" as const
          : "canonical_images" as const,
        sessionId: session.id,
        deliveryId,
        generation: evidence.generation ?? 0,
        targetFingerprint: terminalTarget ? terminalTargetFingerprint(terminalTarget) : "",
        baselineUserEntryIds: new Set(evidence.baselineUserEntryIds),
        baselineComplete: evidence.baselineComplete,
        submittedText: evidence.submittedText,
        ...(imageFingerprints(images) ? { submittedImageFingerprints: imageFingerprints(images) } : {}),
        ...(evidence.requestId ? { requestId: evidence.requestId } : {}),
        ...(evidence.authoritativeComplete !== undefined
          ? { authoritativeComplete: evidence.authoritativeComplete } : {}),
        ...(evidence.submittedAt ? { submittedAt: evidence.submittedAt } : {}),
        evidenceExpiresAt: Date.now() + terminalEvidenceTTL,
      }
      : undefined;
    const operation = this.queueAction(session.id, async (epoch, reservation) => {
      const isSendCurrent = () => isCurrent() && this.isActionCurrent(session.id, epoch, reservation);
      if (!isSendCurrent()) {
        throw new Error("The chat send is no longer current.");
      }
      const terminalGeneration = terminalDelivery
        ? this.beginTerminalSend(terminalDelivery)
        : undefined;
      try {
        await this.deliver(
          session, text, images, deliveryId, evidence,
          isSendCurrent,
        );
      } catch (error) {
        if (terminalGeneration !== undefined) {
          this.clear(session.id, deliveryId);
        }
        throw error;
      }
      if (!deliveryId) return;
      if (session.messageTransport === "codex_app_server") {
        // Injected transports are used by the public test seam and cannot
        // expose the Codex registry. The production transport is checked
        // against its concrete turn ID below before advertising cancellation.
        if (this.sendCodex !== sendCodexTurn) this.codexDeliveryBySession.set(session.id, deliveryId);
      }
      // Terminal sends remain pending until a later authoritative transcript
      // page proves the exact new user row. A successful paste is not itself
      // provider lifecycle evidence.
    });
    return operation;
  }

  canCancel(session: DiscoveredProviderSession, deliveryId?: string): boolean {
    const activeDeliveryId = this.activeCancelDeliveryId(session);
    return Boolean(activeDeliveryId && (!deliveryId || activeDeliveryId === deliveryId));
  }

  reconcile(session: DiscoveredProviderSession): void {
    if (session.section !== "working" || this.helper.isAvailable?.() === false) {
      this.clear(session.id);
      return;
    }
    if (session.provider === "codex" && session.messageTransport === "codex_app_server") {
      this.clearTerminal(session.id);
      return;
    }
    if (isTerminalCancellationRoute(session)
      && session.controlTarget?.kind === "terminal"
      && hasStableTerminalIdentity(session.controlTarget.target)) {
      this.codexDeliveryBySession.delete(session.id);
      const current = this.terminalRecords(session.id)[0];
      const controlTarget = session.controlTarget;
      if (controlTarget?.kind !== "terminal") return;
      const targetFingerprint = terminalTargetFingerprint(controlTarget.target);
      const knownTarget = this.knownTerminalTargetBySession.get(session.id);
      if (knownTarget && knownTarget !== targetFingerprint) {
        this.clearTerminal(session.id, current?.deliveryId);
      }
      this.knownTerminalTargetBySession.set(session.id, targetFingerprint);
      for (const delivery of this.terminalRecords(session.id)) {
        if (delivery.targetFingerprint !== targetFingerprint) {
          this.clearTerminal(session.id, delivery.deliveryId);
        }
      }
      return;
    }
    this.knownTerminalTargetBySession.delete(session.id);
    this.clear(session.id);
  }

  reconcileChatPage(
    session: DiscoveredProviderSession,
    page: ChatPage,
    authoritativeLatest = true,
  ): void {
    if (!authoritativeLatest) return;
    if (!isTerminalCancellationRoute(session)
      || session.controlTarget?.kind !== "terminal"
      || !hasStableTerminalIdentity(session.controlTarget.target)) return;
    const target = session.controlTarget?.kind === "terminal"
      ? terminalTargetFingerprint(session.controlTarget.target)
      : undefined;
    if (!target) return;
    const records = this.terminalRecords(session.id)
      .filter((delivery) => delivery.targetFingerprint === target);
    if (!records.length) {
      for (const delivery of this.terminalRecords(session.id)) {
        this.clearTerminal(session.id, delivery.deliveryId);
      }
      return;
    }
    const users = deduplicateUsers(page);
    const userIDs = new Set(users.map((item) => item.id));
    const latest = users.at(-1);
    const consumedOnPage = new Set<string>();
    const consumedHistory = this.consumedCanonicalUserIDsBySession.get(session.id) ?? new Map<string, string>();

    // Preserve an existing exact assignment across page replays, but never
    // allow two delivery records to retain the same canonical row.
    for (const delivery of records) {
      if (delivery.boundUserEntryId !== undefined) {
        const bound = users.find((item) => item.id === delivery.boundUserEntryId);
        if (!bound || latest?.id !== delivery.boundUserEntryId || consumedOnPage.has(bound.id)) {
          this.clearTerminal(session.id, delivery.deliveryId);
        } else {
          consumedOnPage.add(bound.id);
        }
        continue;
      }
      // A page with an authoritative complete transcript can prove a rewind
      // if a baseline ID vanished. Truncated pages cannot make that claim.
      if (delivery.baselineComplete
        && !page.hasMoreBefore
        && [...delivery.baselineUserEntryIds].some((id) => !userIDs.has(id))) {
        this.clearTerminal(session.id, delivery.deliveryId);
        continue;
      }
    }

    const unbound = this.terminalRecords(session.id)
      .filter((delivery) => delivery.targetFingerprint === target && delivery.boundUserEntryId === undefined);
    const fallbackCandidatesByDelivery = new Map<string, Array<Extract<ChatPage["items"][number], { kind: "user" }>>>();
    const fallbackDeliveriesByUserID = new Map<string, string[]>();
    for (const delivery of unbound) {
      const candidates = users.filter((item) =>
        !delivery.baselineUserEntryIds.has(item.id)
        && !consumedOnPage.has(item.id)
        && !consumedHistory.has(item.id)
        && matchesSubmittedTurn(item, delivery));
      const explicit = candidates.filter((item) => hasExplicitCanonicalIdentity(item));
      if (explicit.length) {
        // Provider/request identity is authoritative; content fallback is
        // never considered for a row carrying an explicit identity.
        if (explicit.length !== 1 || latest?.id !== explicit[0]!.id) {
          this.clearTerminal(session.id, delivery.deliveryId);
          continue;
        }
        this.bindCanonicalDelivery(session.id, delivery.deliveryId, explicit[0]!.id);
        consumedOnPage.add(explicit[0]!.id);
        continue;
      }
      if (candidates.length) {
        fallbackCandidatesByDelivery.set(delivery.deliveryId, candidates);
        for (const candidate of candidates) {
          const deliveryIDs = fallbackDeliveriesByUserID.get(candidate.id) ?? [];
          deliveryIDs.push(delivery.deliveryId);
          fallbackDeliveriesByUserID.set(candidate.id, deliveryIDs);
        }
      }
    }
    // Text-only fallback is safe only when exactly one delivery and one row
    // participate in the match. Two identical pending sends plus one row are
    // intentionally ambiguous and remain fail-closed.
    for (const delivery of unbound) {
      const candidates = fallbackCandidatesByDelivery.get(delivery.deliveryId);
      if (!candidates) continue; // provider echo is delayed; keep Stop hidden.
      if (candidates.length !== 1
        || (fallbackDeliveriesByUserID.get(candidates[0]!.id)?.length ?? 0) !== 1
        || latest?.id !== candidates[0]!.id) {
        this.clearTerminal(session.id, delivery.deliveryId);
        continue;
      }
      this.bindCanonicalDelivery(session.id, delivery.deliveryId, candidates[0]!.id);
      consumedOnPage.add(candidates[0]!.id);
    }
  }

  clear(sessionId: string, deliveryId?: string): void {
    const codex = this.codexDeliveryBySession.get(sessionId);
    const records = this.terminalRecords(sessionId);
    if (deliveryId
      && !records.some((delivery) => delivery.deliveryId === deliveryId)
      && codex !== deliveryId) return;
    // clearTerminal owns timer and image-lease cleanup. Keep generation
    // invalidation here so a public clear advances it exactly once, whether
    // it removes one delivery or the complete terminal ledger.
    if (deliveryId) this.clearTerminal(sessionId, deliveryId, false);
    else {
      this.clearTerminal(sessionId, undefined, false);
      this.knownTerminalTargetBySession.delete(sessionId);
    }
    if (!deliveryId || codex === deliveryId) this.codexDeliveryBySession.delete(sessionId);
    this.bumpTerminalGeneration(sessionId);
  }

  activeCancelDeliveryId(session: DiscoveredProviderSession): string | undefined {
    this.reconcile(session);
    if (session.section !== "working" || this.helper.isAvailable?.() === false) return undefined;
    if (session.provider === "codex" && session.messageTransport === "codex_app_server") {
      return this.cancelCodex === stopCodexTurn
        ? activeCodexTurnDeliveryId(session.id)
        : this.codexDeliveryBySession.get(session.id);
    }
    if (session.messageTransport !== "terminal"
      || session.controlTarget?.kind !== "terminal"
      || (session.provider !== "claude_code" && session.provider !== "pi")
      || !hasStableTerminalIdentity(session.controlTarget.target)) return undefined;
    const targetFingerprint = terminalTargetFingerprint(session.controlTarget.target);
    const current = this.terminalRecords(session.id)
      .filter((delivery) => delivery.targetFingerprint === targetFingerprint
        && delivery.boundUserEntryId !== undefined);
    return current.at(-1)?.deliveryId;
  }

  async cancel(session: DiscoveredProviderSession, deliveryId?: string): Promise<void> {
    const operation = this.queueAction(session.id, async (epoch, reservation) => {
      // Re-read the exact live record after every earlier queued send. This is
      // the last fail-closed check before an Escape/interrupt is sent.
      if (!this.isActionCurrent(session.id, epoch, reservation)) {
        throw new Error("Cancellation is unavailable for this session.");
      }
      if (!deliveryId || !this.canCancel(session, deliveryId)) {
        throw new Error("Cancellation is unavailable for this session.");
      }
      if (session.provider === "codex" && session.messageTransport === "codex_app_server") {
        if (!this.cancelCodex(session.id, deliveryId)) {
          throw new Error("No active Codex turn is available to cancel.");
        }
        this.clear(session.id, deliveryId);
        return;
      }
      if (session.messageTransport === "terminal" && session.controlTarget?.kind === "terminal") {
        const targetFingerprint = terminalTargetFingerprint(session.controlTarget.target);
        // The active record and fingerprint are checked again immediately
        // before the helper call. A route replacement cannot reuse an old ID.
        const current = this.terminalRecords(session.id)
          .find((delivery) => delivery.deliveryId === deliveryId);
        if (current?.boundUserEntryId === undefined || current.targetFingerprint !== targetFingerprint) {
          throw new Error("Cancellation is unavailable for this session.");
        }
        if (!this.isActionCurrent(session.id, epoch, reservation)) {
          throw new Error("Cancellation is unavailable for this session.");
        }
        await this.helper.cancelTerminal(session.controlTarget.target);
        if (!this.isActionCurrent(session.id, epoch, reservation)) {
          throw new Error("Cancellation is unavailable for this session.");
        }
        const after = this.terminalRecords(session.id)
          .find((delivery) => delivery.deliveryId === deliveryId);
        if (after?.deliveryId === deliveryId && after.targetFingerprint === targetFingerprint) {
          this.clear(session.id, deliveryId);
        }
        return;
      }
      throw new Error("Cancellation is unavailable for this session.");
    });
    return operation;
  }

  canCyclePermissionMode(session: DiscoveredProviderSession): boolean {
    if (this.helper.isAvailable?.() === false
      || session.section !== "working"
      || session.provider !== "claude_code"
      || session.messageTransport !== "terminal"
      || session.controlTarget?.kind !== "terminal"
      || !hasStableTerminalIdentity(session.controlTarget.target)) {
      return false;
    }
    const targetFingerprint = terminalTargetFingerprint(session.controlTarget.target);
    const knownTarget = this.knownTerminalTargetBySession.get(session.id);
    return knownTarget === undefined || knownTarget === targetFingerprint;
  }

  async cyclePermissionMode(session: DiscoveredProviderSession): Promise<void> {
    return this.queueAction(session.id, async (epoch, reservation) => {
      if (!this.isActionCurrent(session.id, epoch, reservation)
        || !this.canCyclePermissionMode(session)
        || session.controlTarget?.kind !== "terminal") {
        throw new Error("Permission mode cycling is unavailable for this session.");
      }
      const target = session.controlTarget.target;
      const targetFingerprint = terminalTargetFingerprint(target);
      const knownTarget = this.knownTerminalTargetBySession.get(session.id);
      if (knownTarget !== undefined && knownTarget !== targetFingerprint) {
        throw new Error("Permission mode cycling is unavailable for this terminal.");
      }
      this.knownTerminalTargetBySession.set(session.id, targetFingerprint);
      await this.helper.cyclePermissionMode(target);
      if (!this.isActionCurrent(session.id, epoch, reservation)
        || this.knownTerminalTargetBySession.get(session.id) !== targetFingerprint) {
        throw new Error("Permission mode cycling is unavailable for this session.");
      }
    });
  }

  forget(sessionId: string): void {
    const nextEpoch = (this.actionEpochBySession.get(sessionId) ?? 0) + 1;
    this.actionEpochBySession.set(sessionId, nextEpoch);
    // ponytail: retain at most 512 removed-session epochs. The epoch is only
    // a stale-work tombstone; all provider targets, queues, and delivery data
    // are cleared immediately and must not become a second session cache.
    while (this.actionEpochBySession.size > 512) {
      this.actionEpochBySession.delete(this.actionEpochBySession.keys().next().value!);
    }
    // Do not remove the queue while an operation can still be running. A
    // replacement session with the same ID must wait for that operation's
    // settled promise, while the reservation checks below prevent any late
    // provider write or post-operation mutation.
    for (const reservation of this.actionReservationsBySession.get(sessionId) ?? []) {
      reservation.active = false;
    }
    // clearTerminal cancels every owned expiry timer before this session's
    // ledger is forgotten. It also performs one image-lease release, so this
    // path must not call forgetSession a second time.
    this.clearTerminal(sessionId, undefined, false);
    this.terminalGenerationBySession.delete(sessionId);
    this.knownTerminalTargetBySession.delete(sessionId);
    this.consumedCanonicalUserIDsBySession.delete(sessionId);
    this.codexDeliveryBySession.delete(sessionId);
  }

  private async deliver(
    session: DiscoveredProviderSession,
    text: string,
    images: ChatImage[],
    deliveryId?: string,
    evidence?: ChatDeliveryEvidence,
    isCurrent: () => boolean = () => true,
  ): Promise<void> {
    if (!text && !images.length) throw new Error("The message is empty.");
    if (session.section !== "working") {
      throw new Error("Native message delivery is unavailable for this session.");
    }
    if (!isCurrent()) throw new Error("The chat send is no longer current.");
    const imageLease = await this.storeImages(session, deliveryId, evidence, images);
    const imagePaths = imageLease.paths;
    try {
      if (!isCurrent()) throw new Error("The session was removed before delivery.");
      if (session.provider === "codex" && session.messageTransport === "codex_app_server") {
        await this.sendCodex(
          session.id,
          text,
          imagePaths,
          this.registerCodexAction,
          deliveryId,
          evidence?.requestId,
          evidence?.generation,
        );
        if (!isCurrent()) throw new Error("The session was removed before delivery completed.");
        await this.imageLeases.release(imageLease.scope);
        return;
      }
      if (session.messageTransport !== "terminal" || session.controlTarget?.kind !== "terminal"
        || (session.provider !== "claude_code" && session.provider !== "pi")) {
        throw new Error("Native message delivery is unavailable for this session.");
      }

      const target = session.controlTarget.target;
      if (!hasStableTerminalIdentity(target)) {
        throw new Error("The terminal process identity is unavailable.");
      }
      const targetFingerprint = terminalTargetFingerprint(target);
      const knownTarget = this.knownTerminalTargetBySession.get(session.id);
      const currentDelivery = this.terminalRecords(session.id)[0];
      if (knownTarget !== undefined && knownTarget !== targetFingerprint
        && currentDelivery?.targetFingerprint !== targetFingerprint) {
        throw new Error("The terminal session changed before delivery.");
      }
      this.knownTerminalTargetBySession.set(session.id, targetFingerprint);
      if (session.provider === "claude_code") {
        if (imagePaths.length && target.application === "Terminal") {
          throw new Error("Claude image delivery is unavailable in Terminal.");
        }
        for (const imagePath of imagePaths) {
          if (!isCurrent()) throw new Error("The session was removed before delivery.");
          await this.helper.sendTerminal(target, imagePath, false);
          if (!isCurrent()) throw new Error("The session was removed before delivery completed.");
          await new Promise((resolve) => setTimeout(resolve, 120));
        }
        if (!isCurrent()) throw new Error("The session was removed before delivery.");
        await this.helper.sendTerminal(target, text, true);
        if (!isCurrent()) throw new Error("The session was removed before delivery completed.");
        return;
      }
      const prompt = session.provider === "pi"
        ? [text, ...imagePaths].filter(Boolean).join("\n")
        : text;
      this.updateTerminalSubmittedText(session.id, deliveryId, prompt);
      if (!isCurrent()) throw new Error("The session was removed before delivery.");
      await this.helper.sendTerminal(target, prompt, true);
      if (!isCurrent()) throw new Error("The session was removed before delivery completed.");
      this.imageLeases.markAwaitingCanonical(imageLease.scope);
    } catch (error) {
      // These are operation-local files. A failed, canceled, or invalidated
      // action must not leave a path that a later request can accidentally
      // reuse. Successful delivery returns normally and transfers ownership
      // to the existing retention/cleanup lifecycle.
      await this.imageLeases.release(imageLease.scope);
      throw error;
    }
  }

  async close(): Promise<void> {
    await this.imageLeases.close();
  }

  private beginTerminalSend(delivery: ActiveTerminalDelivery): number {
    this.pruneTerminalLedger(delivery.sessionId);
    const generation = this.bumpTerminalGeneration(delivery.sessionId);
    let records = this.terminalDeliveriesBySession.get(delivery.sessionId);
    if (!records) {
      records = new Map();
      this.terminalDeliveriesBySession.set(delivery.sessionId, records);
    }
    if (records.size >= MAX_TERMINAL_DELIVERY_RECORDS) {
      throw new Error("Terminal delivery evidence capacity is full; wait for a turn to settle.");
    }
    delivery.expiryTimer = setTimeout(() => {
      // The timer is already firing; do not ask clearTerminal/pruning to
      // cancel this consumed handle a second time.
      delivery.expiryTimer = undefined;
      const current = this.terminalRecords(delivery.sessionId)
        .find((item) => item.deliveryId === delivery.deliveryId);
      if (current !== delivery || current.boundUserEntryId !== undefined) return;
      this.clearTerminal(delivery.sessionId, delivery.deliveryId);
    }, Math.max(1, delivery.evidenceExpiresAt - Date.now()));
    delivery.expiryTimer.unref?.();
    records.set(delivery.deliveryId, delivery);
    return generation;
  }

  // ponytail: every removed delivery must cancel its timer or its retained
  // timer closure accumulates until TTL; keep removal on this helper path.
  private clearTerminal(sessionId: string, deliveryId?: string, bumpGeneration = true): void {
    const records = this.terminalDeliveriesBySession.get(sessionId);
    if (!records) {
      if (!deliveryId) void this.imageLeases.forgetSession(sessionId);
      else void this.imageLeases.releaseDelivery(sessionId, deliveryId);
      return;
    }
    if (deliveryId) {
      const removed = records.get(deliveryId);
      if (removed?.expiryTimer) clearTimeout(removed.expiryTimer);
      records.delete(deliveryId);
      void this.imageLeases.releaseDelivery(sessionId, deliveryId);
    } else {
      for (const record of records.values()) {
        if (record.expiryTimer) clearTimeout(record.expiryTimer);
      }
      records.clear();
      void this.imageLeases.forgetSession(sessionId);
    }
    if (!records.size) this.terminalDeliveriesBySession.delete(sessionId);
    if (bumpGeneration) this.bumpTerminalGeneration(sessionId);
  }

  private bindCanonicalDelivery(
    sessionId: string,
    deliveryId: string,
    canonicalUserEntryId: string,
  ): void {
    const current = this.terminalRecords(sessionId)
      .find((item) => item.deliveryId === deliveryId);
    if (!current) return;
    current.boundUserEntryId = canonicalUserEntryId;
    let history = this.consumedCanonicalUserIDsBySession.get(sessionId);
    if (!history) {
      history = new Map<string, string>();
      this.consumedCanonicalUserIDsBySession.set(sessionId, history);
    }
    history.set(canonicalUserEntryId, deliveryId);
    // Canonical provider evidence is the terminal success boundary for the
    // exact delivery. Release its temporary files now; expiry is only a
    // bounded fallback for providers that never publish a canonical row.
    void this.imageLeases.releaseDelivery(sessionId, deliveryId);
    while (history.size > maxTerminalReconcileUserEntries) {
      history.delete(history.keys().next().value!);
    }
  }

  private terminalRecords(sessionId: string): ActiveTerminalDelivery[] {
    this.pruneTerminalLedger(sessionId);
    return [...(this.terminalDeliveriesBySession.get(sessionId)?.values() ?? [])];
  }

  private pruneTerminalLedger(sessionId: string): void {
    const records = this.terminalDeliveriesBySession.get(sessionId);
    if (!records) return;
    const now = Date.now();
    for (const [deliveryId, record] of records) {
      if (record.boundUserEntryId !== undefined || record.evidenceExpiresAt > now) continue;
      if (record.expiryTimer) clearTimeout(record.expiryTimer);
      records.delete(deliveryId);
      void this.imageLeases.releaseDelivery(sessionId, deliveryId);
    }
    if (!records.size) this.terminalDeliveriesBySession.delete(sessionId);
  }

  private updateTerminalSubmittedText(
    sessionId: string,
    deliveryId: string | undefined,
    prompt: string,
  ): void {
    if (!deliveryId) return;
    const delivery = this.terminalRecords(sessionId)
      .find((item) => item.deliveryId === deliveryId);
    if (delivery) delivery.submittedText = normalizeChatText(prompt);
  }

  private bumpTerminalGeneration(sessionId: string): number {
    const generation = (this.terminalGenerationBySession.get(sessionId) ?? 0) + 1;
    this.terminalGenerationBySession.set(sessionId, generation);
    return generation;
  }

  private isActionEpochCurrent(sessionId: string, epoch: number): boolean {
    return (this.actionEpochBySession.get(sessionId) ?? 0) === epoch;
  }

  private isActionCurrent(
    sessionId: string,
    epoch: number,
    reservation: ActionReservation,
  ): boolean {
    return reservation.active && this.isActionEpochCurrent(sessionId, epoch);
  }

  private queueAction<T>(
    sessionId: string,
    action: (epoch: number, reservation: ActionReservation) => Promise<T>,
  ): Promise<T> {
    const epoch = this.actionEpochBySession.get(sessionId) ?? 0;
    const previous = this.actionQueueBySession.get(sessionId) ?? Promise.resolve();
    const existingReservations = this.actionReservationsBySession.get(sessionId);
    if ((existingReservations?.size ?? 0) >= MAX_NATIVE_SESSION_ACTIONS_PER_SESSION) {
      return Promise.reject(new Error(
        "Too many provider actions are queued for this session.",
      ));
    }
    const reservation: ActionReservation = { epoch, active: true };
    let reservations = this.actionReservationsBySession.get(sessionId);
    if (!reservations) {
      reservations = new Set();
      this.actionReservationsBySession.set(sessionId, reservations);
    }
    reservations.add(reservation);
    const operation = previous.then(async () => {
      if (!this.isActionCurrent(sessionId, epoch, reservation)) {
        throw new Error("The session is no longer available.");
      }
      return action(epoch, reservation);
    });
    const settled = operation.then(() => undefined, () => undefined);
    this.actionQueueBySession.set(sessionId, settled);
    void settled.then(() => {
      reservation.active = false;
      reservations?.delete(reservation);
      if (reservations?.size === 0 && this.actionReservationsBySession.get(sessionId) === reservations) {
        this.actionReservationsBySession.delete(sessionId);
      }
      if (this.actionQueueBySession.get(sessionId) === settled) {
        this.actionQueueBySession.delete(sessionId);
      }
    });
    return operation;
  }

  private async storeImages(
    session: DiscoveredProviderSession,
    deliveryId: string | undefined,
    evidence: ChatDeliveryEvidence | undefined,
    images: ChatImage[],
  ): Promise<MaterializedChatImages> {
    const generated = randomUUID();
    const scope: ChatDeliveryImageScope = {
      sessionId: session.id,
      generation: evidence?.generation ?? 0,
      requestId: evidence?.requestId ?? deliveryId ?? `request-${generated}`,
      deliveryId: deliveryId ?? `delivery-${generated}`,
    };
    return this.imageLeases.materialize(scope, images);
  }
}

function isTerminalCancellationRoute(session: DiscoveredProviderSession): boolean {
  return session.section === "working"
    && session.messageTransport === "terminal"
    && session.controlTarget?.kind === "terminal"
    && (session.provider === "claude_code" || session.provider === "pi");
}

/**
 * Bind cancellation to every identity the native helper was given. Sorting
 * keys keeps the fingerprint stable if callers construct equivalent targets
 * in a different property order, while retaining future target fields.
 */
function terminalTargetFingerprint(target: NativeHelperTerminalTarget): string {
  return JSON.stringify(Object.entries(target).sort(([left], [right]) => left.localeCompare(right)));
}

function hasStableTerminalIdentity(target: NativeHelperTerminalTarget): boolean {
  // A tty and PID are both reusable. Require the versioned helper-derived
  // process-instance token before advertising a route; callers without it
  // remain visible but fail closed for send/cancel. Validate the digest here
  // as well as in the helper so capability metadata cannot claim a route for
  // a hand-written/non-verifiable token.
  return isVerifiableProcessInstanceToken(target.pid, target.processStartToken);
}

// ponytail: cap reconciliation work to the most recent canonical rows; the
// latest page itself remains bounded by the protocol/page parser limits.
const maxTerminalReconcileUserEntries = 512;

function deduplicateUsers(page: ChatPage): Array<Extract<ChatPage["items"][number], { kind: "user" }>> {
  const seen = new Set<string>();
  const users: Array<Extract<ChatPage["items"][number], { kind: "user" }>> = [];
  for (const item of page.items) {
    if (item.kind !== "user" || seen.has(item.id)) continue;
    seen.add(item.id);
    users.push(item);
  }
  return users.length > maxTerminalReconcileUserEntries
    ? users.slice(-maxTerminalReconcileUserEntries)
    : users;
}

function matchesSubmittedTurn(
  candidate: Extract<ChatPage["items"][number], { kind: "user" }>,
  pending: ActiveTerminalDelivery,
): boolean {
  // An explicit provider identity is authoritative. Never fall back to text
  // when it is present but mismatched: a same-text external turn must not
  // inherit this delivery's Stop capability.
  if (candidate.deliveryId !== undefined) {
    return candidate.deliveryId === pending.deliveryId
      && (candidate.requestId === undefined || candidate.requestId === pending.requestId);
  }
  if (candidate.requestId !== undefined) {
    return pending.requestId !== undefined && candidate.requestId === pending.requestId;
  }
  if (candidate.providerMessageId !== undefined) return false;
  // The daemon must not infer a new turn from an empty, unreadable, or
  // truncated probe. Exact provider identity above remains valid without a
  // timestamp; only content fallback requires authoritative evidence.
  if (pending.authoritativeComplete === false) return false;
  if (pending.submittedAt !== undefined) {
    if (!candidate.timestamp) return false;
    const submittedAt = Date.parse(pending.submittedAt);
    const occurredAt = Date.parse(candidate.timestamp);
    if (!Number.isFinite(submittedAt) || !Number.isFinite(occurredAt) || occurredAt < submittedAt) {
      return false;
    }
  }
  if (!matchesSubmittedImages(candidate.images, pending)) return false;
  // Provider transcripts often omit request identity. This fallback is
  // intentionally exact and is only applied after baseline-ID subtraction.
  return normalizeChatText(candidate.text) === pending.submittedText;
}

function matchesSubmittedImages(
  candidateImages: readonly ChatImage[],
  pending: ActiveTerminalDelivery,
): boolean {
  const submitted = pending.submittedImageFingerprints;
  if (submitted === undefined) return false;
  const candidate = imageFingerprints(candidateImages);
  if (candidate === undefined) return false;
  // Pi's canonical user prompt contains the generated image paths. In that
  // route the provider may not retain image blocks, so an empty canonical
  // image list is valid only after the exact path-bearing prompt matched.
  if (pending.imageEvidenceMode === "prompt_paths" && candidate.length === 0) return true;
  return candidate.length === submitted.length
    && candidate.every((fingerprint, index) => fingerprint === submitted[index]);
}

function imageFingerprints(images: readonly ChatImage[]): string[] | undefined {
  const fingerprints: string[] = [];
  for (const image of images) {
    const bytes = chatImageBase64Bytes(image.data);
    if (!bytes) return undefined;
    fingerprints.push(`${image.mimeType}:${bytes.byteLength}:${createHash("sha256").update(bytes).digest("hex")}`);
  }
  return fingerprints;
}

function hasExplicitCanonicalIdentity(
  candidate: Extract<ChatPage["items"][number], { kind: "user" }>,
): boolean {
  return candidate.deliveryId !== undefined
    || candidate.requestId !== undefined
    || candidate.providerMessageId !== undefined;
}
