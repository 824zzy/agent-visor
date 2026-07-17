import Foundation

public enum CodexSendRoute: Equatable, Sendable {
    case unavailable
    case sharedAppServer
    case managedAppServer
}

public enum CodexSendRoutePolicy {
    public static func route(for capability: CodexControlCapability) -> CodexSendRoute {
        switch capability {
        case .observed: return .unavailable
        case .connected: return .sharedAppServer
        case .managed: return .managedAppServer
        }
    }
}
