import AgentVisorCore
import AppKit
import Carbon.HIToolbox

@MainActor
final class NativeMenuController: NSObject {
    var emit: (NativeHelperEvent) -> Void = { _ in }

    private let stableItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var sessionItems: [NSStatusItem] = []
    private var usageItems: [NSStatusItem] = []
    private var shortcutSessionIDs: [String] = []
    private var hotKeys: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?

    override init() {
        super.init()
        configureStableItem()
        registerShortcuts()
    }

    func present(pills: [NativeHelperPill], usageGlances: [NativeHelperUsageGlance]) {
        sessionItems.forEach(NSStatusBar.system.removeStatusItem)
        usageItems.forEach(NSStatusBar.system.removeStatusItem)
        sessionItems = pills.sorted { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority < rhs.priority
        }.map(makeSessionItem)
        usageItems = usageGlances.sorted { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority < rhs.priority
        }.map(makeUsageItem)
        shortcutSessionIDs = Array(pills.sorted { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority < rhs.priority
        }.prefix(9).map(\.id))
    }

    private func configureStableItem() {
        guard let button = stableItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "rectangle.stack",
            accessibilityDescription: nil
        )
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(openSessions)
        button.toolTip = "Open Agent Visor sessions"
        button.setAccessibilityLabel("Agent Visor sessions")
        button.setAccessibilityHelp("Opens the session browser")
    }

    private func makeSessionItem(_ pill: NativeHelperPill) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return item }
        button.identifier = NSUserInterfaceItemIdentifier(pill.id)
        button.image = dotImage(color: color(for: pill.phase))
        button.imagePosition = .imageLeading
        button.title = shortTitle(pill.title)
        button.target = self
        button.action = #selector(activatePill(_:))
        button.toolTip = [
            pill.title,
            pill.subtitle ?? "",
            [pill.source, pill.project].compactMap { $0 }.joined(separator: " · "),
            pill.owner.map { "Open in \($0)" } ?? "",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        button.setAccessibilityElement(false)
        return item
    }

    private func makeUsageItem(_ glance: NativeHelperUsageGlance) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return item }
        button.title = glance.label
        button.contentTintColor = color(for: glance.tone)
        button.toolTip = glance.detail
        button.setAccessibilityElement(false)
        return item
    }

    private func dotImage(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 7, height: 7), flipped: false) { bounds in
            color.setFill()
            NSBezierPath(ovalIn: bounds).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func color(for phase: NativeHelperPillPhase) -> NSColor {
        switch phase {
        case .needsYou: return .systemYellow
        case .ready: return .systemGreen
        case .working: return .systemOrange
        }
    }

    private func color(for tone: NativeHelperUsageTone) -> NSColor {
        switch tone {
        case .normal: return .labelColor
        case .warning: return .systemYellow
        case .critical: return .systemRed
        }
    }

    private func shortTitle(_ title: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > 22 ? String(clean.prefix(20)) + "…" : clean
    }

    @objc private func activatePill(_ sender: NSStatusBarButton) {
        guard let id = sender.identifier?.rawValue, !id.isEmpty else { return }
        emit(.activatePill(sessionId: id))
    }

    @objc private func openSessions() {
        emit(.openSessions)
    }

    private func registerShortcuts() {
        var specification = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return noErr }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard status == noErr else { return status }
                let controller = Unmanaged<NativeMenuController>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                Task { @MainActor in controller.handleShortcut(id.id) }
                return noErr
            },
            1,
            &specification,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        let signature = fourCharacterCode("AVSR")
        for hotKey in GlobalSessionShortcutPolicy.registeredHotKeys {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: hotKey.id)
            RegisterEventHotKey(
                hotKey.keyCode,
                UInt32(cmdKey | optionKey),
                id,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            hotKeys.append(reference)
        }
    }

    private func handleShortcut(_ id: UInt32) {
        guard let action = GlobalSessionShortcutPolicy.action(forRegisteredHotKeyID: id) else {
            return
        }
        switch action {
        case .navigate(let position):
            guard shortcutSessionIDs.indices.contains(position) else { return }
            emit(.activatePill(sessionId: shortcutSessionIDs[position]))
        case .toggleOverflow:
            emit(.openSessions)
        }
    }
}

private func fourCharacterCode(_ value: String) -> OSType {
    value.utf8.prefix(4).reduce(0) { ($0 << 8) | OSType($1) }
}
