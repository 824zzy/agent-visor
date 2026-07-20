import AppKit
import AgentVisorCore
import Darwin
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(
        Data("AgentVisorDevCodexRuntime: \(message)\n".utf8)
    )
    Darwin.exit(EXIT_FAILURE)
}

private func codexHomePath(environment: [String: String]) -> String {
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    guard let configured = environment["CODEX_HOME"], !configured.isEmpty else {
        return homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL.path
    }

    let expanded = NSString(string: configured).expandingTildeInPath
    let url = expanded.hasPrefix("/")
        ? URL(fileURLWithPath: expanded, isDirectory: true)
        : homeDirectory.appendingPathComponent(expanded, isDirectory: true)
    return url.standardizedFileURL.path
}

private final class SignalForwarder {
    private let sources: [DispatchSourceSignal]

    init(child: Process) {
        sources = [SIGTERM, SIGINT].map { signalNumber in
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: DispatchQueue.global(qos: .userInitiated)
            )
            source.setEventHandler { [weak child] in
                guard let child, child.isRunning else { return }
                _ = Darwin.kill(child.processIdentifier, signalNumber)
            }
            source.activate()
            return source
        }
    }

    func cancel() {
        sources.forEach { $0.cancel() }
    }
}

private func exitMatchingChild(_ child: Process) -> Never {
    if child.terminationReason == .exit {
        Darwin.exit(child.terminationStatus)
    }

    let signalNumber = child.terminationStatus
    Darwin.signal(signalNumber, SIG_DFL)
    _ = Darwin.raise(signalNumber)
    Darwin.exit(128 + signalNumber)
}

guard let appURL = NSWorkspace.shared.urlForApplication(
    withBundleIdentifier: "com.openai.codex"
) else {
    fail("could not locate the com.openai.codex application")
}

let codexURL = appURL
    .appendingPathComponent("Contents", isDirectory: true)
    .appendingPathComponent("Resources", isDirectory: true)
    .appendingPathComponent("codex", isDirectory: false)
guard FileManager.default.isExecutableFile(atPath: codexURL.path) else {
    fail("Codex executable is missing or not executable at \(codexURL.path)")
}

let inheritedEnvironment = ProcessInfo.processInfo.environment
let plan = CodexSharedRuntimeLaunchPlan(
    codexHome: codexHomePath(environment: inheritedEnvironment)
)
let child = Process()
child.executableURL = codexURL
child.arguments = plan.rawServerArguments
child.environment = inheritedEnvironment.merging(
    plan.helperEnvironmentOverrides,
    uniquingKeysWith: { _, override in override }
)

do {
    try child.run()
} catch {
    fail("could not launch Codex: \(error.localizedDescription)")
}

// Install after spawning so Codex inherits the default signal dispositions.
private let signalForwarder = SignalForwarder(child: child)
child.waitUntilExit()
signalForwarder.cancel()
exitMatchingChild(child)
