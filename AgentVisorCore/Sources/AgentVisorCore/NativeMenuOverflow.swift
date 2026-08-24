import AppKit
import SwiftUI

public struct NativeMenuOverflowSnapshot {
    private static let activityFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public let pills: [NativeHelperPill]
    public let overflowSessionIDs: [String]
    private let pillsByID: [String: NativeHelperPill]

    public init(pills: [NativeHelperPill], visibleSessionIDs: Set<String>) {
        self.init(
            menuPills: pills,
            navigatorPills: pills,
            visibleSessionIDs: visibleSessionIDs
        )
    }

    public init(
        menuPills: [NativeHelperPill],
        navigatorPills: [NativeHelperPill],
        visibleSessionIDs: Set<String>
    ) {
        var seen = Set<String>()
        pills = (navigatorPills + menuPills).filter { seen.insert($0.id).inserted }
        pillsByID = Dictionary(uniqueKeysWithValues: pills.map { ($0.id, $0) })
        overflowSessionIDs = menuPills.map(\.id).filter { !visibleSessionIDs.contains($0) }
    }

    public func selection(query: String) -> SessionNavigatorSearchSelection {
        SessionNavigatorSearchPolicy.select(
            overflowSessionIDs: overflowSessionIDs,
            allCandidates: pills.enumerated().map { index, pill in
                SessionNavigatorSearchCandidate(
                    sessionID: pill.id,
                    title: pill.title,
                    project: pill.project ?? "",
                    source: pill.source ?? "",
                    owner: pill.owner ?? "",
                    path: pill.inspector?.projectPath ?? "",
                    sortDate: pill.inspector.flatMap {
                        Self.activityFormatter.date(from: $0.activityAt)
                    } ?? Date(timeIntervalSinceReferenceDate: Double(pills.count - index))
                )
            },
            query: query
        )
    }

    public func pill(id: String) -> NativeHelperPill? {
        pillsByID[id]
    }
}

public struct NativeMenuOverflowView: View {
    public let snapshot: NativeMenuOverflowSnapshot
    public let onSelect: (String) -> Void
    public let onSelectChat: (String) -> Void
    public let onOpenSessions: () -> Void
    public let onOpenSettings: () -> Void
    public let onDismiss: () -> Void

    @State private var query = ""
    @State private var hoveredID: String?
    @State private var keyboardCursorID: String?
    @State private var searchFocusRequest = 0
    @StateObject private var keyboardMonitor = SessionNavigatorKeyboardEventMonitor()

    public init(
        snapshot: NativeMenuOverflowSnapshot,
        onSelect: @escaping (String) -> Void,
        onSelectChat: @escaping (String) -> Void = { _ in },
        onOpenSessions: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.snapshot = snapshot
        self.onSelect = onSelect
        self.onSelectChat = onSelectChat
        self.onOpenSessions = onOpenSessions
        self.onOpenSettings = onOpenSettings
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if displayedSessionIDs.isEmpty {
                            Text(selection.isSearching ? "No matching sessions" : "No recent sessions")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        } else if selection.isSearching {
                            rows(displayedSessionIDs)
                        } else {
                            ForEach([
                                NativeHelperPillPhase.needsYou,
                                .ready,
                                .working,
                                .history,
                            ], id: \.rawValue) { phase in
                                let ids = displayedSessionIDs.filter {
                                    snapshot.pill(id: $0)?.phase == phase
                                }
                                if !ids.isEmpty {
                                    Text(sectionTitle(for: phase))
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                        .padding(.horizontal, 4)
                                        .padding(.top, phase == .needsYou ? 0 : 6)
                                    rows(ids)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: keyboardCursorID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: query) { _, _ in
                    keyboardCursorID = displayedSessionIDs.first
                }
            }
            .frame(maxHeight: CGFloat(SessionNavigatorPopoverLayoutPolicy.maximumHeight))
            Divider()
            footer
        }
        .frame(width: popoverWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            keyboardMonitor.onEvent = handleKeyboardEvent
            keyboardMonitor.start()
            handleKeyboardEvent(.opened)
        }
        .onDisappear {
            keyboardMonitor.stop()
            keyboardMonitor.onEvent = nil
        }
    }

    private var selection: SessionNavigatorSearchSelection {
        snapshot.selection(query: query)
    }

    private var displayedSessionIDs: [String] {
        selection.orderedSessionIDs
    }

    private var popoverWidth: CGFloat {
        CGFloat(SessionNavigatorPopoverLayoutPolicy.width(
            forVisibleScreenWidth: NSScreen.main.map { Double($0.visibleFrame.width) }
        ))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(selection.isSearching
                    ? SessionNavigatorSummaryPolicy.searchTitle
                    : SessionNavigatorSummaryPolicy.overflowTitle)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(displayedSessionIDs.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
            Text(headerDetail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var headerDetail: String {
        if selection.isSearching {
            return SessionNavigatorSummaryPolicy.searchHeaderText(
                matchCount: displayedSessionIDs.count,
                totalSessionCount: snapshot.pills.count
            )
        }
        var counts: [SidebarStateSectionKind: Int] = [:]
        for id in snapshot.overflowSessionIDs {
            guard let pill = snapshot.pill(id: id) else { continue }
            counts[section(for: pill.phase), default: 0] += 1
        }
        return SessionNavigatorSummaryPolicy.headerText(
            for: SessionNavigatorSummaryPolicy.summary(sectionCounts: counts)
        )
    }

    private var searchField: some View {
        NativeMenuSearchField(
            text: $query,
            focusRequest: searchFocusRequest,
            placeholder: SessionNavigatorSummaryPolicy.searchPlaceholder(
                totalSessionCount: snapshot.pills.count
            )
        )
        .frame(height: 28)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func rows(_ ids: [String]) -> some View {
        ForEach(ids, id: \.self) { id in
            if let pill = snapshot.pill(id: id) { row(pill).id(id) }
        }
    }

    private func row(_ pill: NativeHelperPill) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(color(for: pill.phase))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(pill.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(metadata(for: pill))
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(status(for: pill.phase))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hoveredID == pill.id || keyboardCursorID == pill.id
                    ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.18)
                    : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityHidden(true)
        .overlay(NativeMenuFirstMouseAction(
            accessibilityLabel: pill.accessibilityLabel,
            onHoverChange: { hoveredID = $0 ? pill.id : nil },
            action: { modifiers in
                modifiers.contains(.option) ? onSelectChat(pill.id) : onSelect(pill.id)
            }
        ))
    }

    private var footer: some View {
        HStack(spacing: 0) {
            footerAction(
                title: SessionNavigatorSummaryPolicy.openBrowserLabel,
                systemImage: "rectangle.stack",
                action: onOpenSessions
            )
            Divider().frame(height: 20)
            footerAction(
                title: SessionNavigatorSummaryPolicy.settingsLabel,
                systemImage: "gearshape",
                action: onOpenSettings
            )
        }
    }

    private func footerAction(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title).font(.system(size: 12, weight: .medium))
            if title == SessionNavigatorSummaryPolicy.openBrowserLabel { Spacer() }
        }
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
        .overlay(NativeMenuFirstMouseAction(
            accessibilityLabel: title,
            action: { _ in action() }
        ))
    }

    private func handleKeyboardEvent(_ event: SessionNavigatorKeyboardEvent) {
        let decision = SessionNavigatorKeyboardPolicy.reduce(
            currentCursorID: keyboardCursorID,
            visibleSessionIDs: displayedSessionIDs,
            query: query,
            event: event
        )
        keyboardCursorID = decision.cursorSessionID
        query = decision.query
        switch decision.action {
        case .none:
            break
        case .open(let id, let intent):
            intent == .standard ? onSelect(id) : onSelectChat(id)
        case .focusSearch:
            searchFocusRequest += 1
        case .dismiss:
            onDismiss()
        }
    }

    private func metadata(for pill: NativeHelperPill) -> String {
        [pill.source, pill.project].compactMap { $0 }.joined(separator: " · ")
    }

    private func sectionTitle(for phase: NativeHelperPillPhase) -> String {
        switch phase {
        case .needsYou: SidebarStateSectionKind.needsAttention.displayTitle
        case .ready: SidebarStateSectionKind.ready.displayTitle
        case .working: SidebarStateSectionKind.working.displayTitle
        case .history: SidebarStateSectionKind.recent.displayTitle
        }
    }

    private func status(for phase: NativeHelperPillPhase) -> String {
        switch phase {
        case .needsYou: "Needs attention"
        case .ready: "Ready"
        case .working: "In progress"
        case .history: "History"
        }
    }

    private func color(for phase: NativeHelperPillPhase) -> Color {
        switch phase {
        case .needsYou: .yellow
        case .ready: .green
        case .working: .orange
        case .history: Color(nsColor: .tertiaryLabelColor)
        }
    }

    private func section(for phase: NativeHelperPillPhase) -> SidebarStateSectionKind {
        switch phase {
        case .needsYou: .needsAttention
        case .ready: .ready
        case .working: .working
        case .history: .recent
        }
    }
}

private struct NativeMenuSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NativeMenuFirstMouseSearchField()
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search sessions")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String
        var focusRequest = 0

        init(text: Binding<String>) { _text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text = field.stringValue
        }
    }
}

private final class NativeMenuFirstMouseSearchField: NSSearchField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct NativeMenuFirstMouseAction: NSViewRepresentable {
    let accessibilityLabel: String
    var onHoverChange: (Bool) -> Void = { _ in }
    let action: (NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> NativeMenuFirstMouseButton {
        NativeMenuFirstMouseButton()
    }

    func updateNSView(_ button: NativeMenuFirstMouseButton, context: Context) {
        button.onActivate = action
        button.onHoverChange = onHoverChange
        button.setAccessibilityLabel(accessibilityLabel)
    }
}

private final class NativeMenuFirstMouseButton: NSButton {
    var onActivate: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onHoverChange: (Bool) -> Void = { _ in }
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        target = self
        action = #selector(activate)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange(false)
    }

    @objc private func activate() {
        onActivate(NSApp.currentEvent?.modifierFlags ?? [])
    }
}
