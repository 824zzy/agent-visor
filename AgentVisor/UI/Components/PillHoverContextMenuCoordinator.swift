import AgentVisorCore
import Combine

@MainActor
final class PillHoverContextMenuCoordinator: ObservableObject {
    static let shared = PillHoverContextMenuCoordinator()

    @Published private(set) var dismissalRevision = 0
    private var states: [String: PillHoverContextMenuState] = [:]

    private init() {}

    func pointerEntered(_ sessionID: String) {
        apply(.pointerEntered, to: sessionID)
    }

    func pointerExited(_ sessionID: String) {
        apply(.pointerExited, to: sessionID)
    }

    func contextMenuOpened(for sessionID: String) {
        apply(.contextMenuOpened, to: sessionID)
        dismissalRevision &+= 1
    }

    func contextMenuClosed(for sessionID: String) {
        apply(.contextMenuClosed, to: sessionID)
    }

    func primaryActionTriggered(for sessionID: String) {
        apply(.primaryActionTriggered, to: sessionID)
        dismissalRevision &+= 1
    }

    func canPresentHover(for sessionID: String) -> Bool {
        state(for: sessionID).canPresentHover
    }

    private func apply(
        _ event: PillHoverContextMenuEvent,
        to sessionID: String
    ) {
        let next = PillHoverContextMenuPolicy.applying(event, to: state(for: sessionID))
        if next == PillHoverContextMenuState() {
            states.removeValue(forKey: sessionID)
        } else {
            states[sessionID] = next
        }
    }

    private func state(for sessionID: String) -> PillHoverContextMenuState {
        states[sessionID] ?? PillHoverContextMenuState()
    }
}
