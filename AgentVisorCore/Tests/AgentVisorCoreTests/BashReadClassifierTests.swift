import XCTest
@testable import AgentVisorCore

final class BashReadClassifierTests: XCTestCase {
    func test_grepRecursiveOverDir_returnsThatDir() {
        let target = BashReadClassifier.readTarget(
            command: "grep -rn TODO src/",
            cwd: "/p",
            homeDirectory: "/Users/me"
        )
        // The user usually wants to allow reading from the directory the
        // grep recurses over. Trailing slash should be normalized away.
        XCTAssertEqual(target?.path, "/p/src")
        XCTAssertEqual(target?.isDirectory, true)
    }

    func test_lsWithoutPositional_returnsCwd() {
        let target = BashReadClassifier.readTarget(
            command: "ls",
            cwd: "/p",
            homeDirectory: "/Users/me"
        )
        XCTAssertEqual(target?.path, "/p")
        XCTAssertEqual(target?.isDirectory, true)
    }

    func test_lsWithFlagsButNoPositional_returnsCwd() {
        let target = BashReadClassifier.readTarget(
            command: "ls -la",
            cwd: "/p",
            homeDirectory: "/Users/me"
        )
        XCTAssertEqual(target?.path, "/p")
        XCTAssertEqual(target?.isDirectory, true)
    }

    func test_unknownCommand_returnsNil() {
        XCTAssertNil(BashReadClassifier.readTarget(
            command: "npm test",
            cwd: "/p",
            homeDirectory: "/Users/me"
        ))
        XCTAssertNil(BashReadClassifier.readTarget(
            command: "make build",
            cwd: "/p",
            homeDirectory: "/Users/me"
        ))
    }

    func test_multiTargetCat_returnsNilForV1() {
        // Upstream emits one Read rule per unique parent dir; v1 just
        // bails out and falls back to the prefix path.
        XCTAssertNil(BashReadClassifier.readTarget(
            command: "cat foo.txt bar.txt",
            cwd: "/p",
            homeDirectory: "/Users/me"
        ))
    }

    func test_emptyCommand_returnsNil() {
        XCTAssertNil(BashReadClassifier.readTarget(
            command: "",
            cwd: "/p",
            homeDirectory: "/Users/me"
        ))
        XCTAssertNil(BashReadClassifier.readTarget(
            command: "   ",
            cwd: "/p",
            homeDirectory: "/Users/me"
        ))
    }

    func test_relativePathWithDotDot_normalizes() {
        let target = BashReadClassifier.readTarget(
            command: "cat ../sibling.txt",
            cwd: "/p/proj",
            homeDirectory: "/Users/me"
        )
        XCTAssertEqual(target?.path, "/p/sibling.txt")
        XCTAssertEqual(target?.isDirectory, false)
    }

    func test_sedWithDashN_isReadAndSkipsScriptArg() {
        // sed -n '1,10p' ~/.zshrc — `-n` means print-only mode (read).
        // The classifier must skip the script argument ('1,10p') and
        // return the file as the read target.
        let target = BashReadClassifier.readTarget(
            command: "sed -n '1,10p' ~/.zshrc",
            cwd: "/p",
            homeDirectory: "/Users/me"
        )
        XCTAssertEqual(target?.path, "/Users/me/.zshrc")
        XCTAssertEqual(target?.isDirectory, false)
    }

    func test_sedWithDashI_isWriteAndReturnsNil() {
        XCTAssertNil(BashReadClassifier.readTarget(
            command: "sed -i 's/x/y/' file.txt",
            cwd: "/p",
            homeDirectory: "/Users/me"
        ))
    }

    func test_sedWithoutDashN_returnsNil() {
        // Bare `sed 's/x/y/' file.txt` writes to stdout but is conservatively
        // treated as write-eligible — we don't know without running it.
        XCTAssertNil(BashReadClassifier.readTarget(
            command: "sed 's/x/y/' file.txt",
            cwd: "/p",
            homeDirectory: "/Users/me"
        ))
    }

    func test_headWithRelativePath_resolvesAgainstCwd() {
        let target = BashReadClassifier.readTarget(
            command: "head -20 src/app.swift",
            cwd: "/Users/me/proj",
            homeDirectory: "/Users/me"
        )
        XCTAssertEqual(target?.path, "/Users/me/proj/src/app.swift")
        XCTAssertEqual(target?.isDirectory, false)
    }

    func test_tailWithTildePath_expandsToHome() {
        let target = BashReadClassifier.readTarget(
            command: "tail ~/.zshrc",
            cwd: "/p",
            homeDirectory: "/Users/me"
        )
        XCTAssertEqual(target?.path, "/Users/me/.zshrc")
        XCTAssertEqual(target?.isDirectory, false)
    }

    func test_catWithAbsolutePath_returnsThatPath() {
        let target = BashReadClassifier.readTarget(
            command: "cat /etc/hosts",
            cwd: "/p",
            homeDirectory: "/Users/me"
        )
        XCTAssertEqual(target?.path, "/etc/hosts")
        XCTAssertEqual(target?.isDirectory, false)
    }
}
