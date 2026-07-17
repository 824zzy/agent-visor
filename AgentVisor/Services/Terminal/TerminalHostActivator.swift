import AppKit
import AgentVisorCore
import os.log

enum TerminalHostActivator {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "PillNav")

    static func activateAndWait(
        bundleIdentifier: String,
        timeout: TimeInterval = 1.5
    ) -> NSRunningApplication? {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first
        else {
            logger.notice("host activate bundle=\(bundleIdentifier, privacy: .public) result=fail reason=notRunning")
            return nil
        }

        if isFrontmost(app) {
            return app
        }

        performOnMain {
            _ = app.activate(options: [.activateAllWindows])
        }
        if waitUntilFrontmost(app, timeout: min(timeout, 0.25)) {
            logger.notice("host activate bundle=\(bundleIdentifier, privacy: .public) result=ok route=runningApplication")
            return app
        }

        guard let appURL = app.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
            logger.notice("host activate bundle=\(bundleIdentifier, privacy: .public) result=fail reason=noAppURL")
            return nil
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false

        let openApplication = {
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: configuration,
                completionHandler: nil
            )
        }
        performOnMain(openApplication)

        let remaining = max(0, timeout - 0.25)
        let activated = waitUntilFrontmost(app, timeout: remaining)
        logger.notice("host activate bundle=\(bundleIdentifier, privacy: .public) result=\(activated ? "ok" : "fail", privacy: .public) route=workspace")
        return activated ? app : nil
    }

    static func isFrontmost(_ app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private static func performOnMain(_ action: () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.sync(execute: action)
        }
    }

    private static func waitUntilFrontmost(
        _ app: NSRunningApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isFrontmost(app) {
                return true
            }
            usleep(20_000)
        } while Date() < deadline
        return isFrontmost(app)
    }
}
