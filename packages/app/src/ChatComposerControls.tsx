import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View, type ViewStyle } from "react-native";
import type { ChatSettings, ChatSettingsPatch } from "@agent-visor/protocol";
import type { ChatPalette } from "./theme";
import {
  composerModelLabel,
  selectedModel,
  selectedPermissionProfile,
  selectedReasoningEffort,
  settingCanChange,
  settingScopeLabel,
  settingValues,
} from "./chat-composer-settings";
import { chatSettingMenuLayout } from "./chat-setting-menu-layout";

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
  const modelLabel = composerModelLabel(settings, staged, fallbackModel);
  const effortLabel = effort?.value ?? fallbackEffort;
  const label = [modelLabel, effortLabel ? displayEffort(effortLabel) : undefined]
    .filter(Boolean).join(" · ") || "Model settings";
  const modelOptions: SettingOption[] = settings?.models.map((option) => ({
    id: option.id,
    label: option.displayName,
    description: option.supportsImages
      ? option.description
      : `${option.description} Text only.`,
    reasoningEffort: option.defaultReasoningEffort,
  })) ?? [];
  if (values.modelId && !model) {
    modelOptions.unshift({
      id: values.modelId,
      label: modelLabel!,
      description: "Current model · unavailable to select",
      disabled: true,
    });
  }
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
      align="left"
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
      align="right"
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
  align,
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
  align: "left" | "right";
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
  const [layout, setLayout] = useState<ReturnType<typeof chatSettingMenuLayout>>();
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

  useLayoutEffect(() => {
    if (!open) return;
    const trigger = document.getElementById(triggerID);
    if (!trigger) return;
    const reposition = () => setLayout(chatSettingMenuLayout(
      trigger.getBoundingClientRect(),
      { width: window.innerWidth, height: window.innerHeight },
      align,
      styles.optionLabel.fontSize / 14,
    ));
    reposition();
    const observer = new ResizeObserver(reposition);
    observer.observe(trigger);
    window.addEventListener("resize", reposition);
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", reposition);
    };
  }, [align, open, styles, triggerID]);

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
    const focusIn = (event: FocusEvent) => {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (!document.getElementById(triggerID)?.contains(target)
        && !document.getElementById(menuID)?.contains(target)) close(false);
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
    document.addEventListener("focusin", focusIn);
    document.addEventListener("keydown", keyDown);
    return () => {
      document.removeEventListener("pointerdown", pointerDown);
      document.removeEventListener("focusin", focusIn);
      document.removeEventListener("keydown", keyDown);
    };
  }, [firstEnabledIndex, menuID, onChange, open, options, triggerID]);

  const initialIndex = selectedIndex >= 0 && !options[selectedIndex]!.option.disabled
    ? selectedIndex : firstEnabledIndex;
  useEffect(() => {
    if (!open) return;
    const index = initialIndex;
    if (index < 0) return;
    activeIndexRef.current = index;
    setActiveIndex(index);
    requestAnimationFrame(() => focusOption(index));
  }, [initialIndex, menuID, open]);

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
        <svg aria-hidden="true" width={styles.optionLabel.fontSize} height={styles.optionLabel.fontSize} viewBox="0 0 20 20" style={{ color: styles.value.color, flexShrink: 0 }}>
          <path d="m5 7.5 5 5 5-5" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </Pressable>
      {open && layout ? (
        <View accessibilityLabel={`${ariaLabel} menu`} accessibilityRole="menu" nativeID={menuID} style={[styles.menu, layout]}>
            {sections.map((section) => {
              const content = (
              <View key={section.key} style={section.key === "reasoningEffort" && styles.effortSection}>
                <Text style={styles.sectionLabel}>{section.label}</Text>
                <View style={section.key === "reasoningEffort" && styles.effortOptions}>
                {section.options.map((option) => {
                  const index = options.findIndex(({ section: candidate, option: value }) => candidate.key === section.key && value.id === option.id);
                  const selectedValue = selectedValueFor(selected, section.key);
                  const selectedOption = option.id === selectedValue;
                  return (
                    <Pressable
                      accessibilityLabel={`${section.label}: ${option.label}`}
                      accessibilityHint={option.description}
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
                      onFocus={() => { activeIndexRef.current = index; setActiveIndex(index); }}
                      onHoverIn={() => focusOption(index)}
                      style={[styles.option, section.key === "reasoningEffort" && styles.effortOption, index === activeIndex && styles.optionActive, selectedOption && styles.optionSelected]}
                    >
                      <Text style={styles.optionCheck}>{selectedOption ? "✓" : ""}</Text>
                      <View style={styles.optionCopy}>
                        <Text style={styles.optionLabel}>{option.label}</Text>
                        {option.description && section.key !== "reasoningEffort" ? <Text numberOfLines={2} style={styles.optionDescription}>{option.description}</Text> : null}
                      </View>
                    </Pressable>
                  );
                })}
                </View>
              </View>
              );
              return section.key === "reasoningEffort" ? content : (
                <ScrollView key={section.key} keyboardShouldPersistTaps="handled" style={styles.menuScroller}>
                  {content}
                </ScrollView>
              );
            })}
            {scope ? <Text accessibilityLabel={scope} style={styles.scope}>{scope}</Text> : null}
            {scopeNote ? <Text accessibilityLabel={scopeNote} style={styles.scopeNote}>{scopeNote}</Text> : null}
        </View>
      ) : null}
    </View>
  );
}

function displayEffort(value: string): string {
  if (value === "xhigh") return "Extra high";
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
    trigger: { alignItems: "center", borderRadius: 8, flexDirection: "row", gap: 6, justifyContent: "center", maxWidth: "100%", minHeight: 44, minWidth: 0, paddingHorizontal: 6 },
    value: { color: palette.muted, flexShrink: 1, fontSize: font(13), lineHeight: font(20), maxWidth: 300, minWidth: 0 },
    menu: { backgroundColor: palette.card, borderColor: palette.border, borderRadius: 12, borderWidth: 1, position: "fixed", shadowColor: "#000", shadowOpacity: 0.16, shadowRadius: 18, shadowOffset: { width: 0, height: 6 }, overflow: "hidden", padding: 5, zIndex: 100 } as unknown as ViewStyle,
    menuScroller: { flexShrink: 1, minHeight: 0, scrollbarColor: `${palette.composerBorder} ${palette.card}`, scrollbarWidth: "thin" } as unknown as ViewStyle,
    sectionLabel: { color: palette.muted, fontSize: font(12), fontWeight: "600", paddingHorizontal: 10, paddingTop: 8, paddingBottom: 6 },
    effortSection: { borderTopColor: palette.border, borderTopWidth: 1, marginTop: 5, flexShrink: 0 },
    effortOptions: { flexDirection: "row", flexWrap: "wrap", gap: 3, paddingBottom: 6 },
    effortOption: { flexBasis: "30%", flexGrow: 1, paddingHorizontal: 7, alignItems: "center" },
    option: { alignItems: "flex-start", borderRadius: 7, flexDirection: "row", gap: 8, minHeight: 36, paddingHorizontal: 9, paddingVertical: 8 },
    optionActive: { backgroundColor: palette.accentWash },
    optionSelected: { backgroundColor: palette.accentWash },
    optionCheck: { color: palette.accent, fontSize: font(14), lineHeight: font(20), textAlign: "center", width: 14 },
    optionCopy: { flex: 1, minWidth: 0 },
    optionLabel: { color: palette.foreground, fontSize: font(14), lineHeight: font(20) },
    optionDescription: { color: palette.muted, fontSize: font(12), lineHeight: font(17), marginTop: 2 },
    scope: { borderTopColor: palette.border, borderTopWidth: 1, color: palette.muted, flexShrink: 0, fontSize: font(11), lineHeight: font(16), paddingHorizontal: 10, paddingVertical: 9, marginTop: 5 },
    scopeNote: { color: palette.muted, flexShrink: 0, fontSize: font(11), lineHeight: font(16), paddingHorizontal: 10, paddingBottom: 8 },
  });
}

type ComposerControlStyles = ReturnType<typeof createStyles>;
