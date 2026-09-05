import { describe, expect, it } from "vitest";
import type { ChatSettings } from "@agent-visor/protocol";
import {
  canSendImagesForSettings,
  imageCapabilityMessage,
  mergeSettingPatch,
  selectedModel,
  selectedModelSupportsImages,
  selectedPermissionProfile,
  selectedReasoningEffort,
  settingScopeLabel,
  settingValues,
} from "./chat-composer-settings.js";

const settings: ChatSettings = {
  provider: "codex",
  current: {
    modelId: "gpt-5.6-sol",
    reasoningEffort: "high",
    permissionProfile: ":workspace",
  },
  models: [
    {
      id: "gpt-5.6-sol",
      displayName: "GPT-5.6 Sol",
      description: "Everyday agentic work.",
      reasoningEfforts: [
        { value: "high", description: "Strong reasoning." },
      ],
      defaultReasoningEffort: "high",
      supportsImages: true,
      isDefault: false,
    },
    {
      id: "gpt-6-astra",
      displayName: "GPT-6 Astra",
      description: "Most capable model.",
      reasoningEfforts: [
        { value: "max", description: "Maximum reasoning." },
      ],
      defaultReasoningEffort: "max",
      supportsImages: true,
      isDefault: true,
    },
    {
      id: "gpt-text-only",
      displayName: "Text only",
      description: "No image input.",
      reasoningEfforts: [
        { value: "high", description: "Strong reasoning." },
      ],
      defaultReasoningEffort: "high",
      supportsImages: false,
      isDefault: false,
    },
  ],
  permissionProfiles: [
    { id: ":workspace", displayName: "Workspace", allowed: true },
    { id: ":danger-full-access", displayName: "Full access", allowed: true },
  ],
  appliesTo: "next_turn",
  canChange: true,
};

describe("chat composer settings", () => {
  it("uses staged values for the next message without changing provider current values", () => {
    const staged = { modelId: "gpt-6-astra", reasoningEffort: "max" };
    expect(settingValues(settings, staged)).toEqual({
      modelId: "gpt-6-astra",
      reasoningEffort: "max",
      permissionProfile: ":workspace",
    });
    expect(selectedModel(settings, staged)?.displayName).toBe("GPT-6 Astra");
    expect(selectedReasoningEffort(settings, staged)?.value).toBe("max");
    expect(selectedPermissionProfile(settings, staged)?.displayName).toBe("Workspace");
    expect(selectedModel(settings)?.displayName).toBe("GPT-5.6 Sol");
    expect(settingScopeLabel(settings)).toBe("Applies from your next message (until changed)");
  });

  it("merges a staged patch without inventing omitted provider values", () => {
    expect(mergeSettingPatch(settings.current, { modelId: "gpt-6-astra" })).toEqual({
      modelId: "gpt-6-astra",
      reasoningEffort: "high",
      permissionProfile: ":workspace",
    });
    expect(mergeSettingPatch(undefined, { permissionProfile: ":danger-full-access" })).toEqual({
      permissionProfile: ":danger-full-access",
    });
  });

  it("derives image capability from the effective staged model", () => {
    const staged = { modelId: "gpt-text-only", reasoningEffort: "high" };
    expect(selectedModelSupportsImages(settings, staged)).toBe(false);
    expect(canSendImagesForSettings(true, settings, staged)).toBe(false);
    expect(imageCapabilityMessage(true, settings, staged)).toContain("Choose a model with image support");
    expect(canSendImagesForSettings(true, settings, { modelId: "gpt-6-astra" })).toBe(true);
    expect(imageCapabilityMessage(true, settings, { modelId: "gpt-6-astra" })).toBeUndefined();
  });
});
