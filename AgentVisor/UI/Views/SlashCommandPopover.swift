//
//  SlashCommandPopover.swift
//  AgentVisor
//
//  Autocomplete popover for slash commands. Shows above the composer
//  when the user types `/` at the start of the buffer, filters by what
//  they type after the slash, and inserts `/name ` into the composer
//  on Tab. Mirrors claude-code's prompt-input dropdown.
//

import SwiftUI
import Combine
import AgentVisorCore

/// Observable state for the slash-command popover. Owned by ChatView
/// and read by both the SwiftUI overlay view and the NSTextView key
/// handler in MultiLineInput.
///
/// State machine:
///   - closed → open when composer text matches `/<chars>` and the
///     filter has at least one result
///   - open → closed on: space typed after slash, no matches, ESC,
///     selection accepted, composer cleared past the slash
@MainActor
final class SlashCommandPopoverController: ObservableObject {

    @Published private(set) var isOpen: Bool = false
    @Published private(set) var filtered: [SlashCommand] = []
    @Published private(set) var selectedIndex: Int = 0

    /// Lazily loaded on first `/`. Reload via `invalidateCatalog()` when
    /// the user installs a plugin or switches sessions.
    private var catalog: SlashCommandCatalog?
    private var cachedCwd: URL?

    /// Bind to the chat session so per-session cwd flows into the
    /// project-skills lookup. Call when the active session changes.
    func bindSession(cwd: URL?) {
        if cachedCwd != cwd {
            cachedCwd = cwd
            catalog = nil  // force reload on next /
        }
    }

    /// Drop the cached catalog so the next `/` keystroke rebuilds it
    /// from disk. Use on chat-panel focus-in.
    func invalidateCatalog() {
        catalog = nil
    }

    /// Re-evaluate popover state for the current composer text.
    /// Caller passes the FULL composer string; the controller decides
    /// whether the leading slash + cursor position trigger the popover.
    func update(composerText: String) {
        // Trigger only on `/<chars>` with no whitespace. As soon as the
        // user types a space (entering args) or moves past the first
        // line, the popover closes. This matches claude-code's
        // "command mode is exclusive to the first token" rule.
        guard composerText.hasPrefix("/") else { close(); return }
        let firstLine = composerText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !firstLine.contains(" "), !firstLine.contains("\t") else { close(); return }

        let query = String(firstLine.dropFirst())  // drop the leading slash

        // Lazy-load catalog on first /. Synchronous because the catalog
        // build hits the filesystem once per session — under ~50 ms for
        // typical user setups.
        if catalog == nil {
            catalog = SlashCommandCatalogBuilder.build(cwd: cachedCwd)
        }
        guard let cat = catalog else { close(); return }

        let result = SlashCommandFilter.filter(query: query, catalog: cat)
        guard !result.isEmpty else { close(); return }

        filtered = result
        // Clamp selection rather than reset — keeps the highlight
        // stable as the user types more characters that further
        // narrow the list.
        if selectedIndex >= filtered.count { selectedIndex = 0 }
        isOpen = true
    }

    func selectPrevious() {
        guard isOpen, !filtered.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + filtered.count) % filtered.count
    }

    func selectNext() {
        guard isOpen, !filtered.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % filtered.count
    }

    /// Returns the text the composer should be replaced with on Tab
    /// (typically `/name `), or nil if the popover has no selection.
    func acceptSelection() -> String? {
        guard isOpen, filtered.indices.contains(selectedIndex) else { return nil }
        let cmd = filtered[selectedIndex]
        close()
        return "/\(cmd.name) "
    }

    func close() {
        if isOpen { isOpen = false }
        filtered = []
        selectedIndex = 0
    }
}

/// The popover row + container view. Renders 5 visible rows, scrolls
/// when the filtered list overflows. Mouse hover and click both select.
struct SlashCommandPopover: View {
    @ObservedObject var controller: SlashCommandPopoverController
    /// Called when the user clicks a row. Caller writes the returned
    /// text into the composer and updates the caret.
    let onAccept: (String) -> Void

    private static let maxVisibleRows: Int = 5
    private static let rowHeight: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(controller.filtered.enumerated()), id: \.offset) { idx, cmd in
                            row(for: cmd, isSelected: idx == controller.selectedIndex)
                                .id(idx)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onAccept("/\(cmd.name) ")
                                    controller.close()
                                }
                        }
                    }
                }
                .onChange(of: controller.selectedIndex) { _, newIdx in
                    withAnimation(.linear(duration: 0.05)) {
                        proxy.scrollTo(newIdx, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: rowsHeight)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Catppuccin.surface0.opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Catppuccin.surface2, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2)
    }

    private var rowsHeight: CGFloat {
        let visible = min(controller.filtered.count, Self.maxVisibleRows)
        return CGFloat(max(visible, 1)) * Self.rowHeight + 8
    }

    private func row(for cmd: SlashCommand, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Text("/" + cmd.name)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(isSelected ? Catppuccin.lavender : Catppuccin.text)

            if let hint = cmd.argumentHint, !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(Catppuccin.overlay)
            }

            Text(cmd.description)
                .font(.system(size: 12))
                .foregroundStyle(Catppuccin.subtext)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            sourceBadge(for: cmd.source)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(
            isSelected
                ? Catppuccin.surface2.opacity(0.6)
                : Color.clear
        )
    }

    @ViewBuilder
    private func sourceBadge(for source: SlashCommandSource) -> some View {
        switch source {
        case .builtin:
            EmptyView()
        case .userSkill:
            Text("user")
                .font(.system(size: 10))
                .foregroundStyle(Catppuccin.overlay)
        case .projectSkill:
            Text("project")
                .font(.system(size: 10))
                .foregroundStyle(Catppuccin.overlay)
        case .plugin(let name, _, _):
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(Catppuccin.overlay)
        }
    }
}
