public struct SessionBrowserShortcutHint: Equatable, Sendable {
    public let keys: String
    public let label: String

    public init(keys: String, label: String) {
        self.keys = keys
        self.label = label
    }
}

public struct SessionBrowserShortcutEducationPresentation: Equatable, Sendable {
    public let title: String
    public let hints: [SessionBrowserShortcutHint]
    public let disabledMessage: String?

    public init(
        title: String,
        hints: [SessionBrowserShortcutHint],
        disabledMessage: String?
    ) {
        self.title = title
        self.hints = hints
        self.disabledMessage = disabledMessage
    }
}

public enum SessionBrowserShortcutEducationPolicy {
    public static func presentation(
        for family: SessionShortcutModifierFamily
    ) -> SessionBrowserShortcutEducationPresentation {
        guard let modifiers = family.modifierGlyphs else {
            return SessionBrowserShortcutEducationPresentation(
                title: "Global shortcuts",
                hints: [],
                disabledMessage: "Global session shortcuts are off · Configure in Settings"
            )
        }

        return SessionBrowserShortcutEducationPresentation(
            title: "Global shortcuts",
            hints: [
                SessionBrowserShortcutHint(
                    keys: "\(modifiers)1-9",
                    label: "Open numbered pills"
                ),
                SessionBrowserShortcutHint(
                    keys: "\(modifiers)0",
                    label: "More Sessions"
                ),
            ],
            disabledMessage: nil
        )
    }
}
