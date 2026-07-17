import Foundation

public enum CodexServerRequestRoute: Equatable, Sendable {
    case handle
    case reject
    case deferToPeer
}

public enum CodexServerRequestRoutingPolicy {
    public static func route(
        kind: CodexAppServerProtocol.ServerRequestMethod.Kind,
        capability: CodexControlCapability
    ) -> CodexServerRequestRoute {
        if kind != .unsupported {
            return .handle
        }
        return capability == .connected ? .deferToPeer : .reject
    }
}
