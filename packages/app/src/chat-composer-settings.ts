import type { ChatSettings, ChatSettingsPatch, ChatSettingsValues } from "@agent-visor/protocol";

export type { ChatSettings, ChatSettingsPatch, ChatSettingsValues };

export function settingValues(
  settings: ChatSettings | undefined,
  staged?: ChatSettingsPatch,
): ChatSettingsValues {
  return {
    ...(settings?.current ?? {}),
    ...(staged ?? {}),
  };
}

export function selectedModel(settings: ChatSettings | undefined, staged?: ChatSettingsPatch) {
  const values = settingValues(settings, staged);
  return settings?.models.find((model) => model.id === values.modelId);
}

export function selectedPermissionProfile(settings: ChatSettings | undefined, staged?: ChatSettingsPatch) {
  const values = settingValues(settings, staged);
  return settings?.permissionProfiles.find((profile) => profile.id === values.permissionProfile);
}

export function selectedReasoningEffort(settings: ChatSettings | undefined, staged?: ChatSettingsPatch) {
  const model = selectedModel(settings, staged);
  const value = settingValues(settings, staged).reasoningEffort;
  return model?.reasoningEfforts.find((effort) => effort.value === value)
    ?? (value ? { value, description: "" } : undefined);
}

export function selectedModelSupportsImages(
  settings: ChatSettings | undefined,
  staged?: ChatSettingsPatch,
): boolean | undefined {
  return selectedModel(settings, staged)?.supportsImages;
}

export function canSendImagesForSettings(
  surfaceCanSendImages: boolean,
  settings: ChatSettings | undefined,
  staged?: ChatSettingsPatch,
): boolean {
  return surfaceCanSendImages && selectedModelSupportsImages(settings, staged) !== false;
}

export function imageCapabilityMessage(
  surfaceCanSendImages: boolean,
  settings: ChatSettings | undefined,
  staged?: ChatSettingsPatch,
): string | undefined {
  if (!surfaceCanSendImages) return "Image attachments are unavailable from this Chat surface.";
  if (selectedModelSupportsImages(settings, staged) === false) {
    return "The selected model does not support image attachments. Choose a model with image support or remove the image.";
  }
  return undefined;
}

export function settingCanChange(settings: ChatSettings | undefined): boolean {
  return Boolean(settings?.canChange);
}

export function settingScopeLabel(settings: ChatSettings | undefined): string | undefined {
  return settings?.appliesTo === "next_turn"
    ? "Applies from your next message (until changed)"
    : undefined;
}

export function mergeSettingPatch(
  current: ChatSettingsValues | undefined,
  patch: ChatSettingsPatch,
): ChatSettingsValues {
  return { ...(current ?? {}), ...patch };
}
