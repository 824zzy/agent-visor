import AgentVisorCore
import AppKit

/// Sends one session to the surface that should show it.
///
/// Every entry point comes through here: a pill click in the strip, a click in the session
/// browser, an approval notification, and the hover menu. The rule that picks the surface lives
/// in `PillClickNavigationPolicy`, and the rule that decides who owns the session lives in
/// `AgentControlSessionOwnership.of(_:)`. Both are in AgentVisorCore, with tests.
///
/// This type used to live at the top of `NotchView.swift`, inside a 1450-line view file, even
/// though `AppDelegate` and `NotchSideContent` also call it. It carries the two AppKit steps that
/// cannot move into the package: raise our own window, or focus the owning app.
enum SessionOpenRouter {
    static func smartOpen(
        _ session: SessionState,
        modifierIntent: PillClickModifierIntent = .standard
    ) {
        let action = PillClickNavigationPolicy.action(
            ownership: ownership(for: session),
            modifierIntent: modifierIntent
        )
        switch action {
        case .openAgentVisor:
            openAgentVisor(session)
        case .openOriginal:
            openOriginal(session)
        }
    }

    static func openAgentVisor(_ session: SessionState) {
        AppDelegate.shared?.openSessionInMainWindow(session.sessionId)
    }

    static func openOriginal(_ session: SessionState) {
        SessionNavigator.navigateToSession(session)
    }

    static func ownership(for session: SessionState) -> AgentControlSessionOwnership {
        AgentControlSessionOwnership.of(session)
    }
}
