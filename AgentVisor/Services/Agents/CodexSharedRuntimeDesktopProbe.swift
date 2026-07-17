import AppKit
import AgentVisorCore
import Foundation

struct CodexDesktopApplicationObservation: Equatable, Sendable {
    let processIdentifier: Int
    let launchDate: Date?
}

struct CodexDesktopRuntimeProbeResult: Equatable, Sendable {
    let evidence: CodexDesktopRuntimeEvidence
    let runtime: CodexDesktopRuntime
}

protocol CodexDesktopRuntimeProbing: Sendable {
    nonisolated func probe(
        activationDate: Date?,
        sharedRuntimeHealthy: Bool,
        agentVisorHandshake: Bool
    ) async -> CodexDesktopRuntimeProbeResult
}

struct CodexSharedRuntimeDesktopProbe: CodexDesktopRuntimeProbing {
    typealias RunningApplicationsProvider = @Sendable () -> [CodexDesktopApplicationObservation]
    typealias PrivateAppServerDetector = @Sendable ([Int]) -> Bool
    typealias SharedRuntimeSocketDetector = @Sendable ([Int], String) -> Bool

    private let runningApplicationsProvider: RunningApplicationsProvider
    private let privateAppServerDetector: PrivateAppServerDetector
    private let sharedRuntimeSocketDetector: SharedRuntimeSocketDetector
    private let sharedRuntimeSocketPath: String

    nonisolated init(sharedRuntimeSocketPath: String) {
        runningApplicationsProvider = Self.runningDesktopApplications
        privateAppServerDetector = Self.hasPrivateAppServerDescendant
        sharedRuntimeSocketDetector = Self.hasSharedRuntimeSocket
        self.sharedRuntimeSocketPath = sharedRuntimeSocketPath
    }

    nonisolated init(
        sharedRuntimeSocketPath: String,
        runningApplicationsProvider: @escaping RunningApplicationsProvider,
        privateAppServerDetector: @escaping PrivateAppServerDetector,
        sharedRuntimeSocketDetector: @escaping SharedRuntimeSocketDetector
    ) {
        self.sharedRuntimeSocketPath = sharedRuntimeSocketPath
        self.runningApplicationsProvider = runningApplicationsProvider
        self.privateAppServerDetector = privateAppServerDetector
        self.sharedRuntimeSocketDetector = sharedRuntimeSocketDetector
    }

    nonisolated func probe(
        activationDate: Date?,
        sharedRuntimeHealthy: Bool,
        agentVisorHandshake: Bool
    ) async -> CodexDesktopRuntimeProbeResult {
        let applications = runningApplicationsProvider()
        let launchedAfterActivation = activationDate.map { activationDate in
            applications.contains { application in
                guard let launchDate = application.launchDate else { return false }
                return launchDate >= activationDate
            }
        } ?? false
        let desktopPIDs = applications.map(\.processIdentifier)
        let privateAppServerDetector = self.privateAppServerDetector
        let sharedRuntimeSocketDetector = self.sharedRuntimeSocketDetector
        let sharedRuntimeSocketPath = self.sharedRuntimeSocketPath
        let detection = await Task.detached(priority: .utility) {
            (
                privateAppServerDetector(desktopPIDs),
                sharedRuntimeSocketDetector(desktopPIDs, sharedRuntimeSocketPath)
            )
        }.value
        let evidence = CodexDesktopRuntimeEvidence(
            desktopRunning: !applications.isEmpty,
            launchedAfterActivation: launchedAfterActivation,
            privateAppServerChildPresent: detection.0,
            sharedRuntimeSocketPresent: detection.1,
            sharedRuntimeHealthy: sharedRuntimeHealthy,
            agentVisorHandshake: agentVisorHandshake
        )
        return CodexDesktopRuntimeProbeResult(
            evidence: evidence,
            runtime: CodexDesktopRuntimeClassifier.classify(evidence)
        )
    }

    nonisolated private static func runningDesktopApplications()
        -> [CodexDesktopApplicationObservation]
    {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .filter { !$0.isTerminated }
            .map {
                CodexDesktopApplicationObservation(
                    processIdentifier: Int($0.processIdentifier),
                    launchDate: $0.launchDate
                )
            }
    }

    nonisolated private static func hasPrivateAppServerDescendant(
        of desktopPIDs: [Int]
    ) -> Bool {
        guard !desktopPIDs.isEmpty else { return false }
        let tree = ProcessTreeBuilder.shared.buildTree()
        let descendants = desktopPIDs.reduce(into: Set<Int>()) { result, pid in
            result.formUnion(ProcessTreeBuilder.shared.findDescendants(of: pid, tree: tree))
        }
        guard !descendants.isEmpty else { return false }

        let pidList = descendants.sorted().map(String.init).joined(separator: ",")
        guard let output = ProcessExecutor.shared.runSyncOrNil(
            "/bin/ps",
            arguments: ["-ww", "-p", pidList, "-o", "command="]
        ) else {
            return false
        }

        return output.split(separator: "\n").contains { line in
            let tokens = line.split(whereSeparator: { $0.isWhitespace })
            return tokens.contains("app-server")
                && tokens.contains("--analytics-default-enabled")
        }
    }

    nonisolated private static func hasSharedRuntimeSocket(
        for desktopPIDs: [Int],
        socketPath: String
    ) -> Bool {
        guard !desktopPIDs.isEmpty else { return false }
        let expectedPath = canonicalPath(socketPath)
        guard let serverOutput = ProcessExecutor.shared.runSyncOrNil(
            "/usr/sbin/lsof",
            arguments: ["-t", "--", expectedPath]
        ) else {
            return false
        }
        let serverPIDs = Set(serverOutput.split(whereSeparator: { $0.isWhitespace })
            .compactMap { Int($0) })
        guard !serverPIDs.isEmpty else { return false }

        let tree = ProcessTreeBuilder.shared.buildTree()
        let processIDs = desktopPIDs.reduce(into: Set(desktopPIDs)) { result, pid in
            result.formUnion(ProcessTreeBuilder.shared.findDescendants(of: pid, tree: tree))
        }
        let inspectedPIDs = processIDs.union(serverPIDs)
        let pidList = inspectedPIDs.sorted().map(String.init).joined(separator: ",")
        guard case .success(let lsofResult) = ProcessExecutor.shared.runSyncWithResult(
            "/usr/sbin/lsof",
            arguments: ["-n", "-P", "-a", "-U", "-p", pidList, "-Fpdfn"]
        ) else {
            return false
        }

        return CodexSharedRuntimeSocketPolicy.hasConnection(
            processIDs: processIDs,
            socketPath: expectedPath,
            lsofResult: ProcessOutputSnapshot(
                output: lsofResult.output,
                exitCode: lsofResult.exitCode
            )
        )
    }

    nonisolated private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
