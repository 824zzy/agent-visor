public struct SessionBrowserShortcutHint: Equatable, Sendable {
    public let keys: String
    public let label: String

    public init(keys: String, label: String) {
        self.keys = keys
        self.label = label
    }
}

public struct SessionBrowserShortcutEducationPresentation: Equatable, Sendable {
    public let hints: [SessionBrowserShortcutHint]
    public let disabledMessage: String?

    public init(
        hints: [SessionBrowserShortcutHint],
        disabledMessage: String?
    ) {
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
                hints: [],
                disabledMessage: "Global shortcuts off · Configure in Settings"
            )
        }

        return SessionBrowserShortcutEducationPresentation(
            hints: [
                SessionBrowserShortcutHint(
                    keys: "\(modifiers)1-9",
                    label: "Open pills"
                ),
                SessionBrowserShortcutHint(
                    keys: "\(modifiers)0",
                    label: "More sessions"
                ),
            ],
            disabledMessage: nil
        )
    }
}
