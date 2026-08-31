import { describe, expect, it } from "vitest";
import { CHAT_DELIVERY_TTL_MS } from "./chat-delivery.js";
import { createChatDeliveryExpiryScheduler } from "./use-chat.js";

type Scheduled = {
  run: () => void;
  delay: number;
  canceled: boolean;
};

describe("Chat delivery expiry scheduler", () => {
  it("keeps one bounded timer and clears the previous timer when rescheduled", () => {
    const scheduled: Scheduled[] = [];
    let now = 1_700_000_000_000;
    const scheduler = createChatDeliveryExpiryScheduler({
      now: () => now,
      getExpiry: () => now + CHAT_DELIVERY_TTL_MS,
      expire: () => undefined,
      schedule: (run, delay) => {
        const task: Scheduled = { run, delay, canceled: false };
        scheduled.push(task);
        return task as unknown as ReturnType<typeof setTimeout>;
      },
      cancel: (handle) => { (handle as unknown as Scheduled).canceled = true; },
    });

    scheduler.schedule(1);
    scheduler.schedule(1);
    expect(scheduled).toHaveLength(2);
    expect(scheduled[0]?.canceled).toBe(true);
    expect(scheduled[1]).toMatchObject({ delay: CHAT_DELIVERY_TTL_MS, canceled: false });

    scheduler.clear();
    expect(scheduled[1]?.canceled).toBe(true);
    now += CHAT_DELIVERY_TTL_MS;
  });

  it("does not revive a stale generation after cleanup", () => {
    const scheduled: Scheduled[] = [];
    let activeGeneration = 1;
    const expired: number[] = [];
    const scheduler = createChatDeliveryExpiryScheduler({
      now: () => 1_700_000_000_000,
      getExpiry: (generation) => generation === activeGeneration
        ? 1_700_000_000_000 + CHAT_DELIVERY_TTL_MS
        : undefined,
      expire: (generation) => {
        if (generation === activeGeneration) expired.push(generation);
      },
      schedule: (run, delay) => {
        const task: Scheduled = { run, delay, canceled: false };
        scheduled.push(task);
        return task as unknown as ReturnType<typeof setTimeout>;
      },
      cancel: (handle) => { (handle as unknown as Scheduled).canceled = true; },
    });

    scheduler.schedule(1);
    activeGeneration = 2;
    scheduler.clear();
    scheduled[0]?.run();
    expect(expired).toEqual([]);
    expect(scheduled[0]?.canceled).toBe(true);
  });
});
