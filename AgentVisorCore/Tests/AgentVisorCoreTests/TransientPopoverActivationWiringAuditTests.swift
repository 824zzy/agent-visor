import AppKit
import SwiftUI
import XCTest

final class TransientPopoverActivationWiringAuditTests: XCTestCase {
    func testSessionNavigatorControlsAcceptTheFirstClickWithoutActivatingAgentVisor() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let sideContent = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Components/NotchSideContent.swift"
        ))

        XCTAssertTrue(
            sideContent.contains("override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }"),
            "Popover controls should receive the initial click while Agent Visor is inactive."
        )
        XCTAssertTrue(
            sideContent.contains("final class FirstMouseActionButton: NSButton")
                && sideContent.contains("struct FirstMouseActionOverlay: NSViewRepresentable"),
            "The actual row hit target must be a first-mouse AppKit control."
        )
        let rowSource = try XCTUnwrap(
            sideContent.split(separator: "struct SessionNavigatorRow: View", maxSplits: 1).last
        )
        XCTAssertTrue(
            rowSource.contains("FirstMouseActionOverlay"),
            "Wrapping the popover root is insufficient because ScrollView inserts deeper native hit targets."
        )
        XCTAssertFalse(
            sideContent.contains("NSApp.activate"),
            "First-click delivery must not activate Agent Visor."
        )
    }

    func testFirstMouseRowsAndFooterActionsKeepHoverFeedback() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let sideContent = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Components/NotchSideContent.swift"
        ))
        let rowSource = try XCTUnwrap(
            sideContent.split(separator: "struct SessionNavigatorRow: View", maxSplits: 1).last
        )

        XCTAssertTrue(
            sideContent.contains("var onHoverChange: ((Bool) -> Void)?")
                && sideContent.contains("override func mouseEntered(with event: NSEvent)")
                && sideContent.contains("override func mouseExited(with event: NSEvent)")
                && sideContent.contains(".activeAlways"),
            "The first-mouse overlay must forward pointer transitions instead of swallowing row hover."
        )
        XCTAssertTrue(
            rowSource.contains("onHoverChange: { isHovered = $0 }"),
            "Session rows should derive hover styling from their actual AppKit hit target."
        )
        XCTAssertTrue(
            sideContent.contains("isOpenBrowserFooterHovered")
                && sideContent.contains("isSettingsFooterHovered"),
            "Both footer actions should provide visible hover feedback."
        )
    }

    @MainActor
    func testRowLevelFirstMouseControlForwardsHoverTransitions() throws {
        let button = TestFirstMouseActionButton()
        var transitions: [Bool] = []
        button.onHoverChange = { transitions.append($0) }
        let entered = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            trackingNumber: 1,
            userData: nil
        ))
        let exited = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseExited,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            trackingNumber: 1,
            userData: nil
        ))

        button.mouseEntered(with: entered)
        button.mouseExited(with: exited)

        XCTAssertEqual(transitions, [true, false])
    }

    @MainActor
    func testRowLevelFirstMouseControlIsTheDeepestHitTargetInsideSwiftUIScrollView() throws {
        let root = NSHostingView(rootView: ScrollView {
            Button("Session") {}
                .buttonStyle(.plain)
                .frame(width: 220, height: 44)
                .overlay(TestFirstMouseActionOverlay())
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        root.frame = NSRect(x: 0, y: 0, width: 220, height: 100)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        root.layoutSubtreeIfNeeded()

        let actionButton = try XCTUnwrap(findSubview(of: TestFirstMouseActionButton.self, in: root))
        let center = NSPoint(x: root.bounds.midX, y: root.bounds.maxY - actionButton.bounds.midY)
        let hitView = try XCTUnwrap(root.hitTest(center))

        XCTAssertTrue(
            hitView === actionButton,
            "Expected row control, got \(String(describing: type(of: hitView))); center=\(center); ancestry=\(viewAncestry(from: actionButton))"
        )
        XCTAssertTrue(
            hitView.acceptsFirstMouse(for: nil),
            "Deepest hit target \(String(describing: type(of: hitView))) rejected first mouse."
        )
    }

    @MainActor
    func testRowLevelFirstMouseControlLeavesSecondaryClickForContextMenuAncestor() throws {
        let parent = TestPointerEventRecordingView()
        let button = TestFirstMouseActionButton()
        parent.addSubview(button)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        button.rightMouseDown(with: event)

        XCTAssertEqual(parent.rightMouseDownCount, 1)
    }

    @MainActor
    func testRowLevelFirstMouseControlLeavesScrollingForScrollViewAncestor() throws {
        let parent = TestPointerEventRecordingView()
        let button = TestFirstMouseActionButton()
        parent.addSubview(button)
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: 10,
            wheel2: 0,
            wheel3: 0
        ))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))

        button.scrollWheel(with: event)

        XCTAssertEqual(parent.scrollWheelCount, 1)
    }

    func testMenuBarPopoversOpenWithoutActivatingTheApplicationOrBrowser() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let notchView = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Views/NotchView.swift"
        ))
        let appDelegate = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/App/AppDelegate.swift"
        ))

        XCTAssertFalse(
            notchView.contains("NSApp.activate(ignoringOtherApps: true)"),
            "Opening a menu-bar popover must not raise the Agent Sessions browser."
        )
        XCTAssertFalse(
            notchView.contains("activateForTransientSurface()"),
            "The +N and Usage popovers should remain nonactivating surfaces."
        )
        XCTAssertFalse(
            appDelegate.contains("transientSurfaceActivationGate"),
            "Popover opening should not alter the application's normal Dock reopen behavior."
        )
        XCTAssertTrue(notchView.contains("onOpenMainWindow:"))
        XCTAssertTrue(notchView.contains("requestMainWindowActivation(.overflowPill)"))
    }

    func testOverflowFooterOpensOverallSettingsAfterDismissingThePopover() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let sideContent = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Components/NotchSideContent.swift"
        ))
        let notchView = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Views/NotchView.swift"
        ))
        let mainWindowController = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/MainWindowController.swift"
        ))

        XCTAssertTrue(sideContent.contains("let onOpenSettings: () -> Void"))
        XCTAssertTrue(sideContent.contains("Button(action: onOpenSettings)"))
        XCTAssertTrue(sideContent.contains("SessionNavigatorSummaryPolicy.settingsLabel"))
        XCTAssertTrue(
            notchView.contains(
                "onOpenSettings: {\n                        dismissTransientPopovers()\n                        AppDelegate.shared?.openSettings()"
            ),
            "Settings should close the transient popover before opening overall Settings."
        )
        XCTAssertFalse(
            mainWindowController.contains(
                "func showSettings() {\n        viewModel.selectedSettingsCategory = .general"
            ),
            "Opening overall Settings should preserve the last-selected category."
        )
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @MainActor
    private func findSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = findSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    @MainActor
    private func viewAncestry(from view: NSView) -> String {
        var entries: [String] = []
        var current: NSView? = view
        while let node = current {
            entries.append("\(String(describing: type(of: node))) frame=\(node.frame)")
            current = node.superview
        }
        return entries.joined(separator: " <- ")
    }
}

@MainActor
private final class TestFirstMouseActionButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}

@MainActor
private final class TestPointerEventRecordingView: NSView {
    var rightMouseDownCount = 0
    var scrollWheelCount = 0

    override func rightMouseDown(with event: NSEvent) {
        rightMouseDownCount += 1
    }

    override func scrollWheel(with event: NSEvent) {
        scrollWheelCount += 1
    }
}

private struct TestFirstMouseActionOverlay: NSViewRepresentable {
    final class Coordinator: NSObject {
        @objc func invoke() {}
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TestFirstMouseActionButton {
        let button = TestFirstMouseActionButton(
            title: "",
            target: context.coordinator,
            action: #selector(Coordinator.invoke)
        )
        button.isBordered = false
        button.isTransparent = true
        button.setAccessibilityElement(false)
        return button
    }

    func updateNSView(_ nsView: TestFirstMouseActionButton, context: Context) {}
}
