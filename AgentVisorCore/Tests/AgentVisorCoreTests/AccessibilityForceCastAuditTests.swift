import XCTest

final class AccessibilityForceCastAuditTests: XCTestCase {
    func testAppSourceDoesNotForceCastAccessibilityValues() throws {
        let root = repoRootURL(from: URL(fileURLWithPath: #filePath))
        let appRoot = root.appendingPathComponent("AgentVisor")
        let sources = try swiftSources(under: appRoot)

        var offenders: [String] = []
        for url in sources {
            let source = try String(contentsOf: url)
            if source.contains("as! AXValue") || source.contains("as! AXUIElement") ||
                source.contains("as? AXValue") || source.contains("as? AXUIElement") {
                offenders.append(relativePath(url, root: root))
            }
        }

        let offenderList = offenders.joined(separator: ", ")
        XCTAssertTrue(
            offenders.isEmpty,
            "Accessibility values should be cast defensively. Force-cast offenders: \(offenderList)"
        )
    }

    private func swiftSources(under directory: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return try enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true ? url : nil
        }
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func repoRootURL(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
