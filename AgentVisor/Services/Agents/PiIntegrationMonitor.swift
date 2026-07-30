import Combine
import Foundation

/// Process-local proof that a Pi runtime loaded Agent Visor's bundled
/// extension. Installation alone is only Observing; the first socket event
/// advances Settings to Connected.
@MainActor
final class PiIntegrationMonitor: ObservableObject {
    static let shared = PiIntegrationMonitor()

    @Published private(set) var hasHeartbeat = false

    private init() {}

    func recordHeartbeat() {
        if !hasHeartbeat {
            hasHeartbeat = true
        }
    }
}
