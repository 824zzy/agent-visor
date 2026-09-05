import { useEffect, useMemo, useRef, useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import type { ChatSettings, ChatSettingsPatch } from "@agent-visor/protocol";
import type { ChatPalette } from "./theme";
import {
  selectedModel,
  selectedPermissionProfile,
  selectedReasoningEffort,
  settingCanChange,
  settingScopeLabel,
  settingValues,
} from "./chat-composer-settings";

type SettingChange = (patch: ChatSettingsPatch) => boolean | void;

export function ChatComposerControls({
  fallbackEffort,
  fallbackModel,
  fallbackPermission,
  onChange,
  palette,
  scale,
  settings,
  staged,
}: {
  fallbackEffort?: string;
  fallbackModel?: string;
  fallbackPermission?: string;
  onChange?: SettingChange;
  palette: ChatPalette;
  scale: number;
  settings?: ChatSettings;
  staged?: ChatSettingsPatch;
}) {
  const styles = useMemo(() => createStyles(palette, scale), [palette, scale]);
  return (
    <View accessibilityLabel="Chat composer settings" style={styles.row}>
      <ModelEffortMenu
        fallbackEffort={fallbackEffort}
        fallbackModel={fallbackModel}
        onChange={onChange}
        settings={settings}
        staged={staged}
        styles={styles}
      />
      <PermissionMenu
        fallbackPermission={fallbackPermission}
        onChange={onChange}
        settings={settings}
        staged={staged}
        styles={styles}
      />
    </View>
  );
}

export function ChatComposerModelControl(props: {
  fallbackEffort?: string;
  fallbackModel?: string;
  onChange?: SettingChange;
  palette: ChatPalette;
  scale: number;
  settings?: ChatSettings;
  staged?: ChatSettingsPatch;
}) {
  const styles = useMemo(() => createStyles(props.palette, props.scale), [props.palette, props.scale]);
  return (
    <ModelEffortMenu
      fallbackEffort={props.fallbackEffort}
      fallbackModel={props.fallbackModel}
      onChange={props.onChange}
      settings={props.settings}
      staged={props.staged}
      styles={styles}
    />
  );
}

export function ChatComposerPermissionControl(props: {
  fallbackPermission?: string;
  onChange?: SettingChange;
  palette: ChatPalette;
  scale: number;
  settings?: ChatSettings;
  staged?: ChatSettingsPatch;
}) {
  const styles = useMemo(() => createStyles(props.palette, props.scale), [props.palette, props.scale]);
  return (
    <PermissionMenu
      fallbackPermission={props.fallbackPermission}
      onChange={props.onChange}
      settings={props.settings}
      staged={props.staged}
      styles={styles}
    />
  );
}

function ModelEffortMenu({
  fallbackEffort,
  fallbackModel,
  onChange,
  settings,
  staged,
  styles,
}: {
  fallbackEffort?: string;
  fallbackModel?: string;
  onChange?: SettingChange;
  settings?: ChatSettings;
  staged?: ChatSettingsPatch;
  styles: ComposerControlStyles;
}) {
  const values = settingValues(settings, staged);
  const model = selectedModel(settings, staged);
  const effort = selectedReasoningEffort(settings, staged);
  const modelLabel = model?.displayName ?? fallbackModel;
  const effortLabel = effort?.value ?? fallbackEffort;
  const label = [modelLabel, effortLabel ? displayEffort(effortLabel) : undefined]
    .filter(Boolean).join(" · ") || "Model settings";
  const modelOptions = settings?.models.map((option) => ({
    id: option.id,
    label: option.displayName,
    description: option.supportsImages
      ? option.description
      : `${option.description} Image attachments are unavailable for this model.`,
    reasoningEffort: option.defaultReasoningEffort,
  })) ?? [];
  const effortOptions = model?.reasoningEfforts.map((option) => ({
    id: option.value,
    label: displayEffort(option.value),
    description: option.description,
  })) ?? [];
  const canOpen = Boolean(
    onChange
      && settingCanChange(settings)
      && (modelOptions.length > 1 || effortOptions.length > 1),
  );
  if (!canOpen) {
    return (
      <Text accessibilityLabel="Composer model and effort" numberOfLines={1} style={styles.value}>
        {label}
      </Text>
    );
  }
  return (
    <SettingMenu
      accessibilityLabel="Composer model and effort"
      ariaLabel="Composer model and effort"
      onChange={onChange!}
      scope={settingScopeLabel(settings)}
      sections={[
        ...(modelOptions.length > 1 ? [{ key: "model" as const, label: "Model", options: modelOptions }] : []),
        ...(effortOptions.length > 1 ? [{ key: "reasoningEffort" as const, label: "Reasoning effort", options: effortOptions }] : []),
      ]}
      selected={{ modelId: values.modelId, reasoningEffort: values.reasoningEffort }}
      styles={styles}
      valueLabel={label}
    />
  );
}

function PermissionMenu({
  fallbackPermission,
  onChange,
  settings,
  staged,
  styles,
}: {
  fallbackPermission?: string;
  onChange?: SettingChange;
  settings?: ChatSettings;
  staged?: ChatSettingsPatch;
  styles: ComposerControlStyles;
}) {
  const values = settingValues(settings, staged);
  const current = selectedPermissionProfile(settings, staged);
  const label = current?.displayName ?? fallbackPermission ?? (settings ? "Permission" : undefined);
  const options = settings?.permissionProfiles.map((profile) => ({
    id: profile.id,
    label: profile.displayName,
    description: profile.description,
    disabled: !profile.allowed,
  })) ?? [];
  const canOpen = Boolean(onChange && settingCanChange(settings) && options.filter((option) => !option.disabled).length > 1);
  if (!label) return null;
  if (!canOpen) {
    return (
      <Text accessibilityLabel={`Permission: ${label}`} numberOfLines={1} style={styles.value}>
        {label}
      </Text>
    );
  }
  return (
    <SettingMenu
      accessibilityLabel={`Permission: ${label}`}
      ariaLabel="Composer permission"
      onChange={onChange!}
      scope={settingScopeLabel(settings)}
      scopeNote="Existing approval settings are preserved."
      sections={[{ key: "permission", label: "Permission", options }]}
      selected={{ permissionProfile: values.permissionProfile }}
      styles={styles}
      valueLabel={label}
    />
  );
}

type SettingOption = { id: string; label: string; description?: string; disabled?: boolean; reasoningEffort?: string };
type SettingSection = { key: "model" | "reasoningEffort" | "permission"; label: string; options: SettingOption[] };
type SelectedValues = { modelId?: string; reasoningEffort?: string; permissionProfile?: string };

function SettingMenu({
  accessibilityLabel,
  ariaLabel,
  onChange,
  scope,
  scopeNote,
  sections,
  selected,
  styles,
  valueLabel,
}: {
  accessibilityLabel: string;
  ariaLabel: string;
  onChange: SettingChange;
  scope?: string;
  scopeNote?: string;
  sections: SettingSection[];
  selected: SelectedValues;
  styles: ComposerControlStyles;
  valueLabel: string;
}) {
  const [open, setOpen] = useState(false);
  const [activeIndex, setActiveIndex] = useState(0);
  const activeIndexRef = useRef(0);
  const options = useMemo(
    () => sections.flatMap((section) => section.options.map((option) => ({ section, option }))),
    [sections],
  );
  const selectedIndex = options.findIndex(({ section, option }) => option.id === selectedValueFor(selected, section.key));
  const firstEnabledIndex = options.findIndex(({ option }) => !option.disabled);
  const triggerID = `chat-setting-trigger-${slug(ariaLabel)}`;
  const menuID = `${triggerID}-menu`;

  const focusTrigger = () => {
    if (typeof document === "undefined") return;
    document.getElementById(triggerID)?.focus();
  };
  const focusOption = (index: number) => {
    if (typeof document === "undefined") return;
    document.getElementById(`${menuID}-option-${index}`)?.focus();
  };
  const close = (restoreFocus: boolean) => {
    setOpen(false);
    if (restoreFocus) requestAnimationFrame(focusTrigger);
  };
  const move = (delta: number) => {
    if (!options.length) return;
    let index = activeIndexRef.current;
    for (let count = 0; count < options.length; count += 1) {
      index = (index + delta + options.length) % options.length;
      if (!options[index]!.option.disabled) {
        activeIndexRef.current = index;
        setActiveIndex(index);
        requestAnimationFrame(() => focusOption(index));
        return;
      }
    }
  };

  useEffect(() => {
    if (!open) return;
    const pointerDown = (event: PointerEvent) => {
      const target = event.target;
      if (!(target instanceof Node)) return;
      const trigger = document.getElementById(triggerID);
      const menu = document.getElementById(menuID);
      if (!trigger?.contains(target) && !menu?.contains(target)) close(false);
    };
    const keyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        close(true);
      } else if (event.key === "ArrowDown") {
        event.preventDefault();
        move(1);
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        move(-1);
      } else if (event.key === "Home") {
        event.preventDefault();
        if (firstEnabledIndex >= 0) {
          activeIndexRef.current = firstEnabledIndex;
          setActiveIndex(firstEnabledIndex);
          requestAnimationFrame(() => focusOption(firstEnabledIndex));
        }
      } else if (event.key === "End") {
        event.preventDefault();
        const index = options.findLastIndex(({ option }) => !option.disabled);
        if (index >= 0) {
          activeIndexRef.current = index;
          setActiveIndex(index);
          requestAnimationFrame(() => focusOption(index));
        }
      } else if (event.key === "Enter" || event.key === " ") {
        const index = options.findIndex((_entry, candidateIndex) => (
          document.activeElement?.id === `${menuID}-option-${candidateIndex}`
        ));
        if (index >= 0) {
          event.preventDefault();
          const entry = options[index];
          if (entry) select(entry.section, entry.option);
        }
      }
    };
    document.addEventListener("pointerdown", pointerDown);
    document.addEventListener("keydown", keyDown);
    return () => {
      document.removeEventListener("pointerdown", pointerDown);
      document.removeEventListener("keydown", keyDown);
    };
  }, [firstEnabledIndex, menuID, onChange, open, options, triggerID]);

  useEffect(() => {
    if (!open) return;
    const index = selectedIndex >= 0 && !options[selectedIndex]!.option.disabled
      ? selectedIndex : firstEnabledIndex;
    if (index < 0) return;
    activeIndexRef.current = index;
    setActiveIndex(index);
    requestAnimationFrame(() => focusOption(index));
  }, [firstEnabledIndex, open, options, selectedIndex]);

  const select = (section: SettingSection, option: SettingOption) => {
    if (option.disabled) return;
    const patch = section.key === "model"
      ? {
        modelId: option.id,
        ...(option.reasoningEffort ? { reasoningEffort: option.reasoningEffort } : {}),
      }
      : section.key === "reasoningEffort"
        ? { reasoningEffort: option.id }
        : { permissionProfile: option.id };
    const accepted = onChange(patch);
    if (accepted !== false) close(true);
  };

  return (
    <View style={styles.menuAnchor}>
      <Pressable
        accessibilityLabel={accessibilityLabel}
        accessibilityRole="button"
        accessibilityState={{ expanded: open }}
        aria-expanded={open}
        {...({
          "aria-controls": open ? menuID : undefined,
          "aria-haspopup": "menu",
          tabIndex: 0,
        } as Record<string, unknown>)}
        nativeID={triggerID}
        onPress={() => setOpen((current) => !current)}
        style={styles.trigger}
      >
        <Text numberOfLines={1} style={styles.value}>{valueLabel}</Text>
        <Text aria-hidden style={styles.chevron}>⌄</Text>
      </Pressable>
      {open ? (
        <View accessibilityLabel={`${ariaLabel} menu`} accessibilityRole="menu" nativeID={menuID} style={styles.menu}>
          <ScrollView keyboardShouldPersistTaps="handled" style={styles.menuScroller}>
            {sections.map((section) => (
              <View key={section.key}>
                <Text style={styles.sectionLabel}>{section.label}</Text>
                {section.options.map((option) => {
                  const index = options.findIndex(({ section: candidate, option: value }) => candidate.key === section.key && value.id === option.id);
                  const selectedValue = selectedValueFor(selected, section.key);
                  const selectedOption = option.id === selectedValue;
                  return (
                    <Pressable
                      accessibilityLabel={`${section.label}: ${option.label}`}
                      accessibilityRole="menuitem"
                      accessibilityState={{ disabled: option.disabled, selected: selectedOption }}
                      aria-checked={selectedOption}
                      aria-disabled={option.disabled}
                      aria-selected={selectedOption}
                      disabled={option.disabled}
                      {...({ tabIndex: -1 } as Record<string, unknown>)}
                      nativeID={`${menuID}-option-${index}`}
                      key={option.id}
                      onPress={() => select(section, option)}
                      style={[styles.option, index === activeIndex && styles.optionActive, selectedOption && styles.optionSelected]}
                    >
                      <Text style={styles.optionCheck}>{selectedOption ? "✓" : ""}</Text>
                      <View style={styles.optionCopy}>
                        <Text style={styles.optionLabel}>{option.label}</Text>
                        {option.description ? <Text style={styles.optionDescription}>{option.description}</Text> : null}
                      </View>
                    </Pressable>
                  );
                })}
              </View>
            ))}
            {scope ? <Text accessibilityLabel={scope} style={styles.scope}>{scope}</Text> : null}
            {scopeNote ? <Text accessibilityLabel={scopeNote} style={styles.scopeNote}>{scopeNote}</Text> : null}
          </ScrollView>
        </View>
      ) : null}
    </View>
  );
}

function displayEffort(value: string): string {
  return value.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/[-_]+/g, " ").replace(/\b\w/g, (part) => part.toUpperCase());
}

function selectedValueFor(values: SelectedValues, key: SettingSection["key"]): string | undefined {
  if (key === "model") return values.modelId;
  if (key === "reasoningEffort") return values.reasoningEffort;
  return values.permissionProfile;
}

function slug(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "setting";
}

function createStyles(palette: ChatPalette, scale: number) {
  const font = (size: number) => size * scale;
  return StyleSheet.create({
    row: { alignItems: "center", flexDirection: "row", flexShrink: 1, gap: 2, minHeight: 44, minWidth: 0 },
    menuAnchor: { flexShrink: 1, maxWidth: "100%", minWidth: 0, position: "relative" },
    trigger: { alignItems: "center", borderRadius: 8, flexDirection: "row", gap: 3, justifyContent: "center", maxWidth: "100%", minHeight: 44, minWidth: 0, paddingHorizontal: 4 },
    value: { color: palette.muted, flexShrink: 1, fontSize: font(12), lineHeight: font(18), maxWidth: 300, minWidth: 0, textAlign: "right" },
    chevron: { color: palette.tertiary, fontSize: font(13), lineHeight: font(18) },
    menu: { backgroundColor: palette.card, borderColor: palette.border, borderRadius: 10, borderWidth: 1, bottom: 48, maxWidth: 320, minWidth: 190, position: "absolute", right: 0, shadowColor: "#000", shadowOpacity: 0.12, shadowRadius: 12, zIndex: 20 },
    menuScroller: { maxHeight: 260 },
    sectionLabel: { color: palette.tertiary, fontSize: font(10), fontWeight: "600", paddingHorizontal: 11, paddingTop: 9, paddingBottom: 4, textTransform: "uppercase" },
    option: { alignItems: "flex-start", flexDirection: "row", gap: 7, minHeight: 36, paddingHorizontal: 10, paddingVertical: 7 },
    optionActive: { backgroundColor: palette.accentWash },
    optionSelected: { backgroundColor: `${palette.accentWash}88` },
    optionCheck: { color: palette.accent, fontSize: font(13), lineHeight: font(18), textAlign: "center", width: 14 },
    optionCopy: { flex: 1, minWidth: 0 },
    optionLabel: { color: palette.foreground, fontSize: font(12), lineHeight: font(17) },
    optionDescription: { color: palette.muted, fontSize: font(10), lineHeight: font(14) },
    scope: { borderTopColor: palette.border, borderTopWidth: 1, color: palette.tertiary, fontSize: font(10), lineHeight: font(14), paddingHorizontal: 10, paddingVertical: 8 },
    scopeNote: { color: palette.tertiary, fontSize: font(10), lineHeight: font(14), paddingHorizontal: 10, paddingBottom: 8 },
  });
}

type ComposerControlStyles = ReturnType<typeof createStyles>;
