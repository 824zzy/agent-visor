public enum SessionBrowserPrimaryAction: Equatable, Sendable {
    case enterChat
    case openOriginal
    case none
}

/// Keeps Sessions-browser controls semantically stable:
/// the row/Return path is Chat-first, while Shift-Return is owner-first.
/// The explicit `Open in <owner>` button bypasses this policy entirely.
public enum SessionBrowserPrimaryActionPolicy {
    public static func footerLabel(
        for action: SessionBrowserPrimaryAction
    ) -> String? {
        switch action {
        case .enterChat: return "Enter Chat"
        case .openOriginal: return "Continue in source app"
        case .none: return nil
        }
    }

    public static func action(
        canEnterChat: Bool,
        canOpenOriginal: Bool,
        alternate: Bool = false
    ) -> SessionBrowserPrimaryAction {
        if alternate {
            if canOpenOriginal { return .openOriginal }
            if canEnterChat { return .enterChat }
        } else {
            if canEnterChat { return .enterChat }
            if canOpenOriginal { return .openOriginal }
        }
        return .none
    }
}
