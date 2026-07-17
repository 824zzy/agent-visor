import Foundation
import XCTest

final class BrandIdentityAuditTests: XCTestCase {
    func testRepositoryUsesOnlyCurrentProductIdentity() throws {
        let repositoryRoot = repositoryRoot()
        let fragments = ["claude", "visor"]
        var forbidden = [
            fragments.joined(),
            fragments.joined(separator: "-"),
            fragments.joined(separator: " "),
            fragments.joined(separator: "_"),
        ]
        let integrationFragments = ["codex", "visor"]
        forbidden.append(integrationFragments.joined())
        forbidden.append(integrationFragments.joined(separator: "-"))
        let retiredPrefix = ["c", "v"].joined()
        forbidden.append(retiredPrefix + "_")
        forbidden.append("/tmp/" + retiredPrefix)
        forbidden.append("." + retiredPrefix + "_")
        let skippedDirectories: Set<String> = [
            ".build",
            ".git",
            ".swiftpm",
            "build",
            "releases",
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: repositoryRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        ) else {
            return XCTFail("Could not enumerate repository")
        }

        var violations: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true, skippedDirectories.contains(fileURL.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }

            let relativePath = String(fileURL.path.dropFirst(repositoryRoot.path.count + 1))
            let normalizedPath = relativePath.lowercased()
            if forbidden.contains(where: normalizedPath.contains) {
                violations.append(relativePath)
            }

            guard values.isRegularFile == true,
                  let contents = try? String(contentsOf: fileURL, encoding: .utf8)
            else {
                continue
            }

            for (index, line) in contents.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).enumerated() {
                let normalizedLine = line.lowercased()
                if forbidden.contains(where: normalizedLine.contains) {
                    violations.append("\(relativePath):\(index + 1)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Found \(violations.count) references to the retired identity:
            \(violations.prefix(100).joined(separator: "\n"))
            """
        )
    }

    func testLoggerSubsystemHasOneSourceOfTruth() throws {
        let repositoryRoot = repositoryRoot()
        let subsystem = ["com", "824zzy", "agentvisor"].joined(separator: ".")
        let branding = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "AgentVisorCore/Sources/AgentVisorCore/AppBranding.swift"
            )
        )
        XCTAssertTrue(
            branding.contains("loggerSubsystem = \"\(subsystem)\"")
        )

        let appRoot = repositoryRoot.appendingPathComponent("AgentVisor")
        let enumerator = FileManager.default.enumerator(
            at: appRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var violations: [String] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift",
                  let source = try? String(contentsOf: fileURL)
            else {
                continue
            }
            if source.contains("\"\(subsystem)\"") {
                violations.append(fileURL.path)
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Logger call sites must use AppBranding.loggerSubsystem:\n\(violations.joined(separator: "\n"))"
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
