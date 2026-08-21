public enum SessionBrowserPrimaryAction: Equatable, Sendable {
    case enterChat
    case openOriginal
    case none
}

/// Keeps Sessions-browser controls semantically stable:
/// the row/Return path is source-first, while Shift-Return opens Chat.
public enum SessionBrowserPrimaryActionPolicy {
    public static func footerLabel(
        for action: SessionBrowserPrimaryAction
    ) -> String? {
        switch action {
        case .enterChat: return "Open Chat"
        case .openOriginal: return "Open source app"
        case .none: return nil
        }
    }

    public static func action(
        canEnterChat: Bool,
        canOpenOriginal: Bool,
        alternate: Bool = false
    ) -> SessionBrowserPrimaryAction {
        if alternate {
            if canEnterChat { return .enterChat }
            if canOpenOriginal { return .openOriginal }
        } else {
            if canOpenOriginal { return .openOriginal }
            if canEnterChat { return .enterChat }
        }
        return .none
    }
}
