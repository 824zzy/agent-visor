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

const helperEnvelope = {
  version: z.literal(PROTOCOL_VERSION),
  id: z.string().min(1).max(128),
};

const rectangleSchema = z.object({
  x: z.number().finite(),
  y: z.number().finite(),
  width: z.number().finite().nonnegative(),
  height: z.number().finite().nonnegative(),
}).strict();

export const nativeHelperPillSchema = z.object({
  id: z.string().min(1).max(128),
  title: z.string().min(1).max(256),
  phase: sessionSectionSchema,
  priority: z.number().int(),
  accessibilityLabel: z.string().min(1).max(512),
}).strict();

export const nativeHelperFocusTargetSchema = z.object({
  pid: z.number().int().positive().max(2_147_483_647),
  bundleIdentifier: z.string().min(1).max(255),
  windowId: z.number().int().nonnegative().max(4_294_967_295).optional(),
}).strict();

export const nativeHelperRequestSchema = z.discriminatedUnion("method", [
  z.object({
    ...helperEnvelope,
    method: z.literal("screen_topology"),
  }).strict(),
  z.object({
    ...helperEnvelope,
    method: z.literal("accessibility_status"),
  }).strict(),
  z.object({
    ...helperEnvelope,
    method: z.literal("present_pills"),
    params: z.object({ pills: z.array(nativeHelperPillSchema).max(64) }).strict(),
  }).strict(),
  z.object({
    ...helperEnvelope,
    method: z.literal("focus"),
    params: z.object({ target: nativeHelperFocusTargetSchema }).strict(),
  }).strict(),
]);

export const nativeHelperScreenSchema = z.object({
  displayId: z.number().int().nonnegative().max(4_294_967_295),
  frame: rectangleSchema,
  visibleFrame: rectangleSchema,
  scale: z.number().finite().positive(),
  isMain: z.boolean(),
}).strict();

const nativeHelperResultSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("screen_topology"),
    screens: z.array(nativeHelperScreenSchema),
  }).strict(),
  z.object({
    type: z.literal("accessibility_status"),
    trusted: z.boolean(),
  }).strict(),
  z.object({
    type: z.literal("accepted"),
  }).strict(),
]);

export const nativeHelperResponseSchema = z.discriminatedUnion("ok", [
  z.object({
    ...helperEnvelope,
    ok: z.literal(true),
    result: nativeHelperResultSchema,
  }).strict(),
  z.object({
    ...helperEnvelope,
    ok: z.literal(false),
    error: z.object({
      code: z.enum(["invalid_request", "unsupported", "failed"]),
      message: z.string().min(1).max(512),
    }).strict(),
  }).strict(),
]);

export type ClientMessage = z.infer<typeof clientMessageSchema>;
export type NativeHelperFocusTarget = z.infer<typeof nativeHelperFocusTargetSchema>;
export type NativeHelperPill = z.infer<typeof nativeHelperPillSchema>;
export type NativeHelperRequest = z.infer<typeof nativeHelperRequestSchema>;
export type NativeHelperResponse = z.infer<typeof nativeHelperResponseSchema>;
export type NativeHelperScreen = z.infer<typeof nativeHelperScreenSchema>;
export type ServerMessage = z.infer<typeof serverMessageSchema>;
export type SessionSection = z.infer<typeof sessionSectionSchema>;
export type SessionSnapshot = z.infer<typeof sessionSnapshotSchema>;
export type SessionSummary = z.infer<typeof sessionSummarySchema>;
