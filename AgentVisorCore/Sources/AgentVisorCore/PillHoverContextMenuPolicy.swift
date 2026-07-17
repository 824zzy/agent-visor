public enum PillHoverContextMenuEvent: Equatable, Sendable {
    case pointerEntered
    case pointerExited
    case contextMenuOpened
    case contextMenuClosed
    case primaryActionTriggered
}

public struct PillHoverContextMenuState: Equatable, Sendable {
    public let pointerIsInside: Bool
    public let contextMenuIsOpen: Bool
    public let requiresFreshHover: Bool

    public init(
        pointerIsInside: Bool = false,
        contextMenuIsOpen: Bool = false,
        requiresFreshHover: Bool = false
    ) {
        self.pointerIsInside = pointerIsInside
        self.contextMenuIsOpen = contextMenuIsOpen
        self.requiresFreshHover = requiresFreshHover
    }

    public var canPresentHover: Bool {
        pointerIsInside && !contextMenuIsOpen && !requiresFreshHover
    }
}

public enum PillHoverContextMenuPolicy {
    public static func applying(
        _ event: PillHoverContextMenuEvent,
        to state: PillHoverContextMenuState
    ) -> PillHoverContextMenuState {
        switch event {
        case .pointerEntered:
            return PillHoverContextMenuState(
                pointerIsInside: true,
                contextMenuIsOpen: state.contextMenuIsOpen,
                requiresFreshHover: state.requiresFreshHover
            )
        case .pointerExited:
            return PillHoverContextMenuState(
                pointerIsInside: false,
                contextMenuIsOpen: state.contextMenuIsOpen,
                requiresFreshHover: false
            )
        case .contextMenuOpened:
            return PillHoverContextMenuState(
                pointerIsInside: true,
                contextMenuIsOpen: true,
                requiresFreshHover: true
            )
        case .contextMenuClosed:
            return PillHoverContextMenuState(
                pointerIsInside: state.pointerIsInside,
                contextMenuIsOpen: false,
                requiresFreshHover: state.requiresFreshHover
            )
        case .primaryActionTriggered:
            return PillHoverContextMenuState(
                pointerIsInside: true,
                contextMenuIsOpen: false,
                requiresFreshHover: true
            )
        }
    }
}
