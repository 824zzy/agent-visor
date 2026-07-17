import XCTest
@testable import AgentVisorCore

final class PathTildifierTests: XCTestCase {
    private let home = "/Users/test"

    func testHomeBecomesTilde() {
        XCTAssertEqual(
            PathTildifier.tildify(home, homeDirectory: home),
            "~"
        )
    }

    func testPathUnderHomeReplacedWithTilde() {
        XCTAssertEqual(
            PathTildifier.tildify("/Users/test/Personal/agent-visor", homeDirectory: home),
            "~/Personal/agent-visor"
        )
    }

    func testPathOutsideHomeUnchanged() {
        XCTAssertEqual(
            PathTildifier.tildify("/tmp/foo", homeDirectory: home),
            "/tmp/foo"
        )
    }

    func testPathPrefixMatchOnlyAtBoundary() {
        // `/Users/test2` happens to start with `/Users/test`. Must
        // NOT be tildified — the tildify check requires either an
        // exact match or a `/` immediately after the home dir.
        XCTAssertEqual(
            PathTildifier.tildify("/Users/test2/foo", homeDirectory: home),
            "/Users/test2/foo"
        )
        XCTAssertEqual(
            PathTildifier.tildify("/Users/testNotHome", homeDirectory: home),
            "/Users/testNotHome"
        )
    }

    func testEmptyPath() {
        XCTAssertEqual(PathTildifier.tildify("", homeDirectory: home), "")
    }

    func testRoot() {
        XCTAssertEqual(PathTildifier.tildify("/", homeDirectory: home), "/")
    }

    func testEmbeddedTildeInPath() {
        // A path containing literal "~" (rare but legal) should pass
        // through unchanged when it's not under home.
        XCTAssertEqual(
            PathTildifier.tildify("/tmp/~weird", homeDirectory: home),
            "/tmp/~weird"
        )
    }

    func testHomeWithTrailingSlashHandledByCallSite() {
        // PathTildifier expects a normalized home (no trailing slash).
        // If a caller passes a trailing-slash home, the prefix check
        // fails as documented — the caller is responsible for
        // standardising. This test documents that contract so a
        // future change doesn't accidentally start handling trailing
        // slashes silently.
        XCTAssertEqual(
            PathTildifier.tildify("/Users/test/Personal", homeDirectory: "/Users/test/"),
            "/Users/test/Personal"
        )
    }
}
