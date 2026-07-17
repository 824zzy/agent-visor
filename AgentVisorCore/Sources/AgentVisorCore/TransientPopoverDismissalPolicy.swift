public enum TransientPopoverInteraction: Equatable, Sendable {
    case insidePopover
    case presentingControl
    case outsideClick
    case escapeKey
    case otherKey
}

public enum TransientPopoverDismissalAction: Equatable, Sendable {
    case keepOpen
    case deferToPresenter
    case dismiss
}

public enum TransientPopoverDismissalPolicy {
    public static func action(
        for interaction: TransientPopoverInteraction
    ) -> TransientPopoverDismissalAction {
        switch interaction {
        case .insidePopover, .otherKey:
            return .keepOpen
        case .presentingControl:
            return .deferToPresenter
        case .outsideClick, .escapeKey:
            return .dismiss
        }
    }
}
