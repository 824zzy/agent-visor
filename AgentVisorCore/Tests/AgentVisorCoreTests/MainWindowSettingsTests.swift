import XCTest
@testable import AgentVisorCore

final class MainWindowSettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "com.824zzy.agentvisor.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        // Sanity: the suite is genuinely empty.
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testReturnsNilWhenUnset() {
        XCTAssertNil(MainWindowSettings.lastSessionId(in: defaults()))
    }

    func testRoundTrips() {
        let d = defaults()
        MainWindowSettings.setLastSessionId("abc-123", in: d)
        XCTAssertEqual(MainWindowSettings.lastSessionId(in: d), "abc-123")
    }

    func testNilClears() {
        let d = defaults()
        MainWindowSettings.setLastSessionId("abc", in: d)
        MainWindowSettings.setLastSessionId(nil, in: d)
        XCTAssertNil(MainWindowSettings.lastSessionId(in: d))
    }

    func testEmptyStringTreatedAsNil() {
        let d = defaults()
        MainWindowSettings.setLastSessionId("", in: d)
        XCTAssertNil(MainWindowSettings.lastSessionId(in: d))
    }

    func testFrameAutosaveNameStable() {
        // Stable identifier wired into NSWindow.setFrameAutosaveName so
        // the OS persists window frame across launches. If this changes,
        // existing users' window position resets — keep it stable.
        XCTAssertEqual(MainWindowSettings.frameAutosaveName, "AgentVisor.MainWindow")
    }

    // MARK: - Hidden sessions

    func testHiddenSessionsEmptyByDefault() {
        let d = defaults()
        XCTAssertTrue(MainWindowSettings.hiddenSessions(in: d).isEmpty)
        XCTAssertTrue(MainWindowSettings.hiddenSessionIds(in: d).isEmpty)
    }

    func testHiddenSessionRoundTrips() {
        let d = defaults()
        MainWindowSettings.hide(id: "s1", title: "Research HRM", agentRaw: "codex", in: d)
        let entries = MainWindowSettings.hiddenSessions(in: d)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first, HiddenSessionEntry(id: "s1", title: "Research HRM", agentRaw: "codex"))
        XCTAssertEqual(MainWindowSettings.hiddenSessionIds(in: d), ["s1"])
    }

    func testHideMultipleAndUnhideOne() {
        let d = defaults()
        MainWindowSettings.hide(id: "a", title: "A", agentRaw: "claude", in: d)
        MainWindowSettings.hide(id: "b", title: "B", agentRaw: "codex", in: d)
        XCTAssertEqual(MainWindowSettings.hiddenSessionIds(in: d), ["a", "b"])
        MainWindowSettings.unhide(id: "a", in: d)
        XCTAssertEqual(MainWindowSettings.hiddenSessionIds(in: d), ["b"])
        XCTAssertEqual(MainWindowSettings.hiddenSessions(in: d).first?.title, "B")
    }

    func testReHideReplacesExistingEntry() {
        let d = defaults()
        MainWindowSettings.hide(id: "a", title: "Old title", agentRaw: "claude", in: d)
        MainWindowSettings.hide(id: "a", title: "New title", agentRaw: "claude", in: d)
        let entries = MainWindowSettings.hiddenSessions(in: d)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "New title")
    }

    func testUnhideLastClearsStorage() {
        let d = defaults()
        MainWindowSettings.hide(id: "a", title: "A", agentRaw: "claude", in: d)
        MainWindowSettings.unhide(id: "a", in: d)
        XCTAssertTrue(MainWindowSettings.hiddenSessions(in: d).isEmpty)
    }

    func testTitleWithTabOrNewlineIsSanitized() {
        let d = defaults()
        MainWindowSettings.hide(id: "a", title: "line1\tcol\nline2", agentRaw: "codex", in: d)
        let entry = MainWindowSettings.hiddenSessions(in: d).first
        XCTAssertEqual(entry?.id, "a")
        XCTAssertEqual(entry?.title, "line1 col line2")
        XCTAssertEqual(entry?.agentRaw, "codex")
    }

    func testEmptyIdIgnored() {
        let d = defaults()
        MainWindowSettings.hide(id: "", title: "X", agentRaw: "codex", in: d)
        XCTAssertTrue(MainWindowSettings.hiddenSessions(in: d).isEmpty)
    }

    func testMalformedEncodedEntriesAreDropped() {
        let d = defaults()
        // Simulate a corrupt stored value (wrong field count / empty id).
        d.set(["only-two\tfields", "\ttitle\tcodex", "good\tGood\tclaude"],
              forKey: "AgentVisor.MainWindow.hiddenSessions")
        let entries = MainWindowSettings.hiddenSessions(in: d)
        XCTAssertEqual(entries.map(\.id), ["good"])
    }
}
