import XCTest

final class UpdateNotificationWiringAuditTests: XCTestCase {
    func testAppMenuExposesCheckForUpdates() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let app = try source(root, "AgentVisor/App/AgentVisorApp.swift")

        XCTAssertTrue(app.contains("CommandGroup(after: .appInfo)"))
        XCTAssertTrue(app.contains("Button(\"Check for Updates...\")"))
        XCTAssertTrue(app.contains("appDelegate.openUpdateDetails(checkNow: true)"))
    }

    func testAutomaticChecksNotifyOnceAndStaySilent() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let delegate = try source(root, "AgentVisor/App/AppDelegate.swift")
        let driver = try source(root, "AgentVisor/Services/Update/NotchUserDriver.swift")
        let notifications = try source(root, "AgentVisor/Services/Notifications/ApprovalNotifier.swift")

        XCTAssertTrue(delegate.contains("updater.checkForUpdatesInBackground()"))
        XCTAssertTrue(driver.contains("isUserInitiated: state.userInitiated"))
        XCTAssertTrue(notifications.contains("UpdateNotificationPolicy.shouldNotify"))
        XCTAssertTrue(notifications.contains("content.sound = nil"))
        XCTAssertTrue(notifications.contains("completionHandler([.banner])"))
    }

    func testNotificationAndMenuOpenTheUpdatesDetail() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let delegate = try source(root, "AgentVisor/App/AppDelegate.swift")
        let notifications = try source(root, "AgentVisor/Services/Notifications/ApprovalNotifier.swift")
        let controller = try source(root, "AgentVisor/UI/Window/MainWindowController.swift")
        let model = try source(root, "AgentVisor/UI/Window/MainWindowViewModel.swift")
        let settings = try source(root, "AgentVisor/UI/Window/SettingsWindowView.swift")

        XCTAssertTrue(delegate.contains("func openUpdateDetails(checkNow: Bool)"))
        XCTAssertTrue(notifications.contains("openUpdateDetails(checkNow: false)"))
        XCTAssertTrue(controller.contains("func showUpdates()"))
        XCTAssertTrue(model.contains("func prepareForUpdateSettings()"))
        XCTAssertTrue(settings.contains(".id(\"settings-updates\")"))
        XCTAssertTrue(settings.contains("settingsUpdateRevealRequest"))
    }

    private func source(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path))
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
