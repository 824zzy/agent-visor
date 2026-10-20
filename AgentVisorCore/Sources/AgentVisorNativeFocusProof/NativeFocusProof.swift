import Foundation

struct ProofProcess: Codable, Equatable { let pid: Int32; let start: String }
struct ProofSurface: Codable, Equatable, Hashable {
    let window: String
    let tab: String
    let terminal: String
}
struct ProofFixtures: Codable {
    let attempt: String
    let process: ProofProcess
    let surfaces: [ProofSurface]
}
struct ProofObservation: Codable {
    let process: ProofProcess
    let frontmost: Bool
    let focused: ProofSurface?
    let surfaces: [ProofSurface]
    let selected: [ProofSurface]
}
struct ProofReceipt: Codable {
    let attempt: String
    let action: String
    let status: String
    let expected: ProofSurface
    let before: ProofObservation
    let observed: ProofObservation
}

/// External native-app boundary. Automated tests provide a fixture host.
protocol NativeFocusHost {
    func create(attempt: String) throws -> ProofFixtures
    func observe(_ fixtures: ProofFixtures) throws -> ProofObservation
    func focus(_ surface: ProofSurface, fixtures: ProofFixtures) throws
    func close(_ surface: ProofSurface, fixtures: ProofFixtures) throws
}

enum ProofError: LocalizedError {
    case unavailable
    case message(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Fixture identity is missing, changed, or no longer owned. No fallback was attempted."
        case .message(let text): return text
        }
    }
}

final class NativeFocusProof {
    private let host: NativeFocusHost
    private(set) var fixtures: ProofFixtures?
    private(set) var attempted = false
    private(set) var attempt: String?
    init(host: NativeFocusHost) { self.host = host }
    func prepare() throws {
        guard !attempted else { throw ProofError.unavailable }
        attempted = true
        let attempt = UUID().uuidString
        self.attempt = attempt
        let created = try host.create(attempt: attempt)
        guard created.attempt == attempt, created.process.pid > 0, !created.process.start.isEmpty,
              created.surfaces.count == 3, Set(created.surfaces.map(\.terminal)).count == 3,
              Set(created.surfaces.map(\.tab)).count == 3, Set(created.surfaces.map(\.window)).count == 2,
              created.surfaces.allSatisfy({ [$0.window, $0.tab, $0.terminal].allSatisfy { !$0.isEmpty && $0.count <= 128 } })
        else { throw ProofError.unavailable }
        fixtures = created
    }
    func focus(index: Int) throws -> ProofReceipt {
        guard let fixtures, fixtures.surfaces.indices.contains(index) else { throw ProofError.unavailable }
        let target = fixtures.surfaces[index]
        let before = try host.observe(fixtures)
        guard !before.frontmost, safe(before, fixtures), before.surfaces.contains(target) else {
            return ProofReceipt(attempt: fixtures.attempt, action: UUID().uuidString,
                                status: "rejected", expected: target, before: before, observed: before)
        }
        try host.focus(target, fixtures: fixtures)
        let observed = try host.observe(fixtures)
        let unchanged = Set(before.selected.filter { $0.window != target.window })
            == Set(observed.selected.filter { $0.window != target.window })
        let verified = observed.focused == target && observed.frontmost
            && observed.surfaces.contains(target) && safe(observed, fixtures) && unchanged
        return ProofReceipt(attempt: fixtures.attempt, action: UUID().uuidString,
                            status: verified ? "verified" : "rejected",
                            expected: target, before: before, observed: observed)
    }
    @discardableResult func close(index: Int) throws -> ProofObservation {
        guard let fixtures, fixtures.surfaces.indices.contains(index) else { throw ProofError.unavailable }
        let target = fixtures.surfaces[index]
        let before = try host.observe(fixtures)
        guard safe(before, fixtures) else { throw ProofError.unavailable }
        if before.surfaces.contains(target) { try host.close(target, fixtures: fixtures) }
        let after = try host.observe(fixtures)
        guard !after.surfaces.contains(target) else { throw ProofError.unavailable }
        return after
    }
    func cleanup() throws -> ProofObservation {
        guard let fixtures else { throw ProofError.unavailable }
        for index in fixtures.surfaces.indices { try close(index: index) }
        return try host.observe(fixtures)
    }
    private func safe(_ observation: ProofObservation, _ fixtures: ProofFixtures) -> Bool {
        observation.process == fixtures.process
            && Set(observation.surfaces).isSubset(of: Set(fixtures.surfaces))
    }
}
