/// Holds restoration authority while a newly-created snapshot is crossing the
/// durability boundary at app startup.
public struct PiRestorationStartupState: Sendable {
    public private(set) var coordinator: PiRebootRestorationCoordinator?
    public private(set) var isDisabled = false
    public private(set) var needsInitialSnapshotPersistence: Bool

    public init(
        coordinator: PiRebootRestorationCoordinator,
        needsInitialSnapshotPersistence: Bool
    ) {
        self.coordinator = coordinator
        self.needsInitialSnapshotPersistence = needsInitialSnapshotPersistence
    }

    /// Persists a fresh baseline before exposing its coordinator as startup
    /// authority. A failed save revokes that authority for the current run.
    public mutating func persistInitialSnapshotIfNeeded(
        using persist: (PiRestorationSnapshot) throws -> Void
    ) throws {
        guard needsInitialSnapshotPersistence,
              let coordinator else { return }

        do {
            try persist(coordinator.snapshot)
            needsInitialSnapshotPersistence = false
        } catch {
            isDisabled = true
            self.coordinator = nil
            throw error
        }
    }
}
