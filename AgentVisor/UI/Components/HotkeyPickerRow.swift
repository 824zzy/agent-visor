//
//  HotkeyPickerRow.swift
//  AgentVisor
//
//  Settings row for choosing the global hotkey trigger modifier.
//

import AppKit
import AgentVisorCore
import SwiftUI

struct HotkeyPickerRow: View {
    @ObservedObject var hotkeySelector: HotkeySelector
    @State private var isHovered = false

    private var isExpanded: Bool {
        hotkeySelector.isPickerExpanded
    }

    private func setExpanded(_ value: Bool) {
        hotkeySelector.isPickerExpanded = value
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    setExpanded(!isExpanded)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "command")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text("Toggle Hotkey")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Text(selectedRowLabel)
                        .font(.system(size: 11))
                        .foregroundColor(ChatTheme.tertiary)
                        .lineLimit(1)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(ChatTheme.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Catppuccin.surface0.opacity(0.6) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(HotkeyTrigger.allCases, id: \.self) { option in
                        HotkeyOptionRow(
                            option: option,
                            isSelected: hotkeySelector.trigger == option
                        ) {
                            hotkeySelector.setTrigger(option)
                        }
                        if option == .custom && hotkeySelector.trigger == .custom {
                            CustomHotkeyRecorderRow(hotkeySelector: hotkeySelector)
                        }
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
    }

    /// Top-row right-hand label. For `.custom` with a recorded combo
    /// we show the combo glyphs so the user knows what's active at a
    /// glance without having to expand the picker.
    private var selectedRowLabel: String {
        if hotkeySelector.trigger == .custom, let combo = hotkeySelector.customCombo {
            return KeyComboFormatter.display(combo)
        }
        return hotkeySelector.trigger.displayLabel
    }

    private var textColor: Color {
        isHovered ? ChatTheme.primary : ChatTheme.secondary
    }
}

/// Inline recorder shown under the "Custom shortcut" radio when it's
/// the active trigger. Displays the current combo (or "Not set") and a
/// Record button that captures the next keystroke.
private struct CustomHotkeyRecorderRow: View {
    @ObservedObject var hotkeySelector: HotkeySelector
    @State private var isRecording = false
    @State private var validationError: String?
    @State private var localMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            // Indent under the radio
            Spacer().frame(width: 14)

            if isRecording {
                Text("Press a shortcut…")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Catppuccin.mauve)
            } else if let combo = hotkeySelector.customCombo {
                Text(KeyComboFormatter.display(combo))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(ChatTheme.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Catppuccin.surface0)
                    )
            } else {
                Text("Not set")
                    .font(.system(size: 11))
                    .foregroundColor(ChatTheme.tertiary)
                    .italic()
            }

            if let error = validationError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(Catppuccin.red)
                    .lineLimit(1)
            }

            Spacer()

            Button(isRecording ? "Cancel" : "Record") {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(isRecording ? Catppuccin.red : Catppuccin.lavender)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Catppuccin.surface0)
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        validationError = nil
        isRecording = true
        // Local-only monitor — user is interacting with the Preferences
        // window when they click Record, so AppKit routes keyDowns
        // through the local path. Returning nil swallows the event so
        // the captured combo doesn't double-fire as a normal keystroke.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            captureKeystroke(event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func captureKeystroke(_ event: NSEvent) {
        let semantic: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let mods = ModifierMask.fromNSEvent(event.modifierFlags.intersection(semantic))
        let combo = KeyCombo(keyCode: event.keyCode, modifiers: mods)
        guard KeyComboValidator.isValid(combo) else {
            validationError = "Needs a modifier (or use a function key)"
            return
        }
        hotkeySelector.setCustomCombo(combo)
        validationError = nil
        stopRecording()
    }
}

private struct HotkeyOptionRow: View {
    let option: HotkeyTrigger
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Catppuccin.surface2)
                    .frame(width: 6, height: 6)

                Text(option.displayLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isHovered ? ChatTheme.primary : ChatTheme.secondary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Catppuccin.surface0.opacity(0.4) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
