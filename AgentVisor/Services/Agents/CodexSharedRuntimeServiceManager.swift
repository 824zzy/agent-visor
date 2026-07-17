import ServiceManagement

enum CodexSharedRuntimeServiceStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
}

protocol CodexSharedRuntimeServiceManaging: Sendable {
    var status: CodexSharedRuntimeServiceStatus { get }
    func register() throws
    func unregister() throws
}

final class CodexSharedRuntimeServiceManager: @unchecked Sendable, CodexSharedRuntimeServiceManaging {
    private let service: SMAppService

    init(
        service: SMAppService = .agent(
            plistName: "com.824zzy.AgentVisor.CodexRuntime.plist"
        )
    ) {
        self.service = service
    }

    var status: CodexSharedRuntimeServiceStatus {
        switch service.status {
        case .notRegistered, .notFound:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        @unknown default:
            return .notRegistered
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}
