import { z } from "zod";

export const PROTOCOL_VERSION = 1 as const;

export const sessionSectionSchema = z.enum([
  "needs_you",
  "ready",
  "working",
  "history",
]);

export const sessionSummarySchema = z.object({
  id: z.string().min(1),
  title: z.string().min(1),
  subtitle: z.string(),
  source: z.string().min(1),
  project: z.string().min(1),
  owner: z.string().min(1),
  cwd: z.string().min(1),
  section: sessionSectionSchema,
  updatedAt: z.iso.datetime(),
  canOpenOwner: z.boolean(),
  canEnterChat: z.boolean(),
});

export const sessionSnapshotSchema = z.object({
  type: z.literal("session_snapshot"),
  revision: z.number().int().nonnegative(),
  sessions: z.array(sessionSummarySchema),
});

export const clientMessageSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("health") }),
  z.object({ type: z.literal("subscribe_sessions") }),
]);

export const serverMessageSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("hello"),
    protocolVersion: z.literal(PROTOCOL_VERSION),
  }),
  z.object({ type: z.literal("health"), status: z.literal("ok") }),
  sessionSnapshotSchema,
]);

export type ClientMessage = z.infer<typeof clientMessageSchema>;
export type ServerMessage = z.infer<typeof serverMessageSchema>;
export type SessionSection = z.infer<typeof sessionSectionSchema>;
export type SessionSnapshot = z.infer<typeof sessionSnapshotSchema>;
export type SessionSummary = z.infer<typeof sessionSummarySchema>;
