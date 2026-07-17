import AppKit
import AgentVisorCore
import Combine
import CoreGraphics

@MainActor
final class NotchMenuLayoutCoordinator: ObservableObject {
    private static let initialSnapshot = NotchMenuLayoutPolicy.begin(
        generation: 0,
        targetScreenID: "unconfigured",
        ownerBundleID: nil,
        ownerIsResolved: false,
        cachedOwnerEdge: nil
    )
    @Published private(set) var snapshot = initialSnapshot
    private static let initialStatusTraySnapshot = StatusTrayLayoutPolicy.begin(
        targetScreenID: "unconfigured",
        observedLeftEdge: nil
    )
    @Published private(set) var statusTraySnapshot = initialStatusTraySnapshot

    private struct Context: Equatable {
        let frontmostPid: pid_t?
        let targetScreenID: String
        let ownerPid: pid_t?
        let ownerBundleID: String?
        let ownerIsResolved: Bool
        let resolutionSource: NotchMenuOwnerResolver.Resolution.Source
    }

    private struct ProbeRequest: Sendable {
        let generation: UInt64
        let requestID: UInt64
        let ownerPid: pid_t?
        let ownerBundleID: String?
        let ownerIsResolved: Bool
        let targetScreenRect: CGRect
        let screenFrames: [CGRect]
        let primaryScreenHeight: CGFloat
    }

    private enum ProbeResult: Sendable {
        case owner(edge: CGFloat, onTargetScreen: Bool, bundleID: String)
        case localOwner(edge: CGFloat, bundleID: String)
        case screen(edge: CGFloat)
        case unavailable
    }

    private var context: Context?
    private var reconciliationSnapshot = initialSnapshot
    private var generation: UInt64 = 0
    private var nextRequestID: UInt64 = 0
    private var retryWorkItems: [DispatchWorkItem] = []
    private var isStarted = false

    func safeWidth(available: CGFloat, margin: CGFloat = 28) -> CGFloat {
        NotchMenuLayoutPolicy.safeWidth(
            available: available,
            snapshot: snapshot,
            margin: margin
        )
    }

    func statusTraySafeWidth(availableFrom: CGFloat, margin: CGFloat = 16) -> CGFloat {
        StatusTrayLayoutPolicy.safeWidth(
            availableFrom: availableFrom,
            snapshot: statusTraySnapshot,
            margin: margin
        )
    }

    func start(screenRect: CGRect) {
        guard !isStarted else { return }
        isStarted = true
        establishContext(
            frontmostPid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            screenRect: screenRect,
            forceNewGeneration: true
        )
        probe(screenRect: screenRect)
        scheduleRetries(after: [0.3, 1.0, 2.5], screenRect: screenRect)
    }

    func stop() {
        isStarted = false
        cancelRetries()
    }

    func handleAppActivation(_ notification: Notification, screenRect: CGRect) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        guard app.activationPolicy == .regular else {
            NotchMenuDiagnostics.log("activation skip non-regular app=\(app.bundleIdentifier ?? "?")")
            return
        }

        cancelRetries()
        establishContext(
            frontmostPid: app.processIdentifier,
            screenRect: screenRect,
            forceNewGeneration: true
        )
        probe(screenRect: screenRect)
        scheduleRetries(after: [0.1, 0.4, 1.0], screenRect: screenRect)
    }

    func probe(screenRect: CGRect) {
        guard isStarted else { return }

        updateStatusTrayEdge(screenRect: screenRect)

        let frontmost = NSWorkspace.shared.frontmostApplication
        let observedFrontmostPid = frontmost?.activationPolicy == .regular
            ? frontmost?.processIdentifier
            : nil
        let observedTargetScreenID = Self.screenID(for: screenRect)
        if NotchMenuContextRefreshPolicy.shouldResolveOwner(
            hasContext: context != nil,
            contextFrontmostPid: context?.frontmostPid,
            observedFrontmostPid: observedFrontmostPid,
            contextTargetScreenID: context?.targetScreenID,
            observedTargetScreenID: observedTargetScreenID,
            contextOwnerIsResolved: context?.ownerIsResolved ?? false
        ) {
            establishContext(
                frontmostPid: observedFrontmostPid,
                screenRect: screenRect,
                forceNewGeneration: true
            )
        }

        guard let context else { return }
        nextRequestID &+= 1
        let screenFrames = NSScreen.screens.map(\.frame)
        let request = ProbeRequest(
            generation: reconciliationSnapshot.generation,
            requestID: nextRequestID,
            ownerPid: context.ownerPid,
            ownerBundleID: context.ownerBundleID,
            ownerIsResolved: context.ownerIsResolved,
            targetScreenRect: screenRect,
            screenFrames: screenFrames,
            primaryScreenHeight: screenFrames.first?.height ?? screenRect.height
        )
        let ownPid = getpid()

        if request.ownerIsResolved,
           request.ownerPid == ownPid,
           let ownerBundleID = request.ownerBundleID,
           let edge = Self.localMenuBarRightEdge(screenRect: screenRect) {
            apply(
                .localOwner(edge: edge, bundleID: ownerBundleID),
                request: request
            )
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result: ProbeResult
            if request.ownerIsResolved,
               let ownerPid = request.ownerPid,
               ownerPid != ownPid,
               let ownerBundleID = request.ownerBundleID,
               let measured = NotchMenuProbe.menuBarRightEdge(
                   for: ownerPid,
                   targetScreenRect: request.targetScreenRect,
                   screenFrames: request.screenFrames,
                   primaryScreenHeight: request.primaryScreenHeight
               ) {
                result = .owner(
                    edge: measured.edge,
                    onTargetScreen: measured.onTargetScreen,
                    bundleID: ownerBundleID
                )
            } else {
                let edge = NotchMenuProbe.screenMenuRightEdge(
                    screenRect: request.targetScreenRect,
                    primaryScreenHeight: request.primaryScreenHeight
                )
                result = edge > 0 ? .screen(edge: edge) : .unavailable
            }

            Task { @MainActor [weak self] in
                self?.apply(result, request: request)
            }
        }
    }

    private func updateStatusTrayEdge(screenRect: CGRect) {
        let observedEdge = Self.statusTrayLeftEdge(screenRect: screenRect)
        let updated = StatusTrayLayoutPolicy.applying(
            observedLeftEdge: observedEdge,
            observedAt: Foundation.ProcessInfo.processInfo.systemUptime,
            targetScreenID: Self.screenID(for: screenRect),
            to: statusTraySnapshot
        )
        guard updated != statusTraySnapshot else { return }
        statusTraySnapshot = updated
    }

    private func establishContext(
        frontmostPid: pid_t?,
        screenRect: CGRect,
        forceNewGeneration: Bool
    ) {
        let newContext = resolveContext(frontmostPid: frontmostPid, screenRect: screenRect)
        guard forceNewGeneration || newContext != context else { return }

        generation &+= 1
        context = newContext
        let cachedEdge = newContext.ownerIsResolved
            ? newContext.ownerBundleID.flatMap(MenuBarWidthCache.read)
            : nil
        let localOwnerEdge = newContext.ownerPid == getpid()
            ? Self.localMenuBarRightEdge(screenRect: screenRect)
            : nil
        let initial = NotchMenuLayoutPolicy.begin(
            generation: generation,
            targetScreenID: newContext.targetScreenID,
            ownerBundleID: newContext.ownerBundleID,
            ownerIsResolved: newContext.ownerIsResolved,
            cachedOwnerEdge: cachedEdge,
            localOwnerEdge: localOwnerEdge
        )
        reconciliationSnapshot = initial
        snapshot = initial

        NotchMenuDiagnostics.log(
            "context generation=\(generation) owner=\(newContext.ownerBundleID ?? "nil")"
                + " source=\(String(describing: newContext.resolutionSource))"
                + " resolved=\(newContext.ownerIsResolved) cached=\(Int(cachedEdge ?? 0))"
                + " local=\(Int(localOwnerEdge ?? 0))"
        )
    }

    private func resolveContext(frontmostPid: pid_t?, screenRect: CGRect) -> Context {
        let separateSpaces = NSScreen.screensHaveSeparateSpaces
        let screens = NSScreen.screens
        let isSingleScreen = screens.count == 1
        let needsWindowInfo = separateSpaces && !isSingleScreen
        let primaryHeight = screens.first?.frame.height ?? screenRect.height
        let frontmostHasWindow = needsWindowInfo
            ? Self.appHasWindow(pid: frontmostPid, on: screenRect, primaryScreenHeight: primaryHeight)
            : false
        let topmost = needsWindowInfo
            ? Self.topmostAppPid(on: screenRect, primaryScreenHeight: primaryHeight)
            : nil
        let resolution = NotchMenuOwnerResolver.resolve(
            frontmostPid: frontmostPid,
            frontmostHasWindowOnNotchScreen: frontmostHasWindow,
            topmostOnNotchPid: topmost,
            separateSpaces: separateSpaces,
            isSingleScreen: isSingleScreen
        )
        let ownerBundleID = resolution.ownerPid.flatMap {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        }

        return Context(
            frontmostPid: frontmostPid,
            targetScreenID: Self.screenID(for: screenRect),
            ownerPid: resolution.ownerPid,
            ownerBundleID: ownerBundleID,
            ownerIsResolved: resolution.isConfident && ownerBundleID != nil,
            resolutionSource: resolution.source
        )
    }

    private func apply(_ result: ProbeResult, request: ProbeRequest) {
        let evidence: NotchMenuEdgeEvidence
        switch result {
        case .owner(let edge, let onTargetScreen, let bundleID):
            evidence = NotchMenuEdgeEvidence(
                generation: request.generation,
                requestID: request.requestID,
                ownerBundleID: bundleID,
                edge: edge,
                source: .ownerAccessibility(onTargetScreen: onTargetScreen)
            )
        case .localOwner(let edge, let bundleID):
            evidence = NotchMenuEdgeEvidence(
                generation: request.generation,
                requestID: request.requestID,
                ownerBundleID: bundleID,
                edge: edge,
                source: .ownerLocalMenu
            )
        case .screen(let edge):
            evidence = NotchMenuEdgeEvidence(
                generation: request.generation,
                requestID: request.requestID,
                ownerBundleID: nil,
                edge: edge,
                source: .screenWindowList
            )
        case .unavailable:
            NotchMenuDiagnostics.log(
                "probe unavailable generation=\(request.generation) request=\(request.requestID)"
            )
            return
        }

        let previous = reconciliationSnapshot
        let updated = NotchMenuLayoutPolicy.applying(evidence, to: previous)
        guard updated.evidence == evidence else {
            NotchMenuDiagnostics.log(
                "probe rejected generation=\(request.generation) request=\(request.requestID)"
                    + " currentGeneration=\(reconciliationSnapshot.generation)"
                    + " owner=\(request.ownerBundleID ?? "nil")"
            )
            return
        }

        reconciliationSnapshot = updated
        let previousEdge = NotchMenuLayoutPolicy.renderedEdge(for: previous)
        let updatedEdge = NotchMenuLayoutPolicy.renderedEdge(for: updated)
        if previousEdge != updatedEdge {
            snapshot = updated
        }
        if case .ownerAccessibility = evidence.source,
           let ownerBundleID = evidence.ownerBundleID {
            MenuBarWidthCache.write(evidence.edge, bundleID: ownerBundleID)
        }
        if previous.evidence?.source != evidence.source || previousEdge != updatedEdge {
            NotchMenuDiagnostics.log(
                "probe accepted generation=\(evidence.generation) request=\(evidence.requestID)"
                    + " owner=\(evidence.ownerBundleID ?? "screen") edge=\(Int(evidence.edge))"
                    + " source=\(String(describing: evidence.source))"
            )
        }
    }

    private func scheduleRetries(after delays: [TimeInterval], screenRect: CGRect) {
        let expectedGeneration = reconciliationSnapshot.generation
        for delay in delays {
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.isStarted,
                          self.reconciliationSnapshot.generation == expectedGeneration else {
                        return
                    }
                    self.probe(screenRect: screenRect)
                }
            }
            retryWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func cancelRetries() {
        retryWorkItems.forEach { $0.cancel() }
        retryWorkItems.removeAll()
    }

    private static func localMenuBarRightEdge(screenRect: CGRect) -> CGFloat? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        let items = mainMenu.items.filter { !$0.isHidden }

        let itemFrames = items
            .map { $0.accessibilityFrame() }
            .filter {
                $0.width > 0
                    && $0.height > 0
                    && $0.midX >= screenRect.minX
                    && $0.midX < screenRect.maxX
            }
        if let maxX = itemFrames.map(\.maxX).max() {
            let edge = ceil(maxX - screenRect.minX)
            if edge > 0, edge < screenRect.width / 2 {
                return edge
            }
        }

        let menuFont = NSFont.menuBarFont(ofSize: 0)
        let titleWidths = items.compactMap { item -> CGFloat? in
            let width: CGFloat
            if let attributedTitle = item.attributedTitle,
               attributedTitle.length > 0 {
                width = attributedTitle.size().width
            } else {
                width = (item.title as NSString).size(withAttributes: [.font: menuFont]).width
            }
            return width > 0 ? width : nil
        }
        return LocalMenuBarEdgeEstimator.estimate(titleWidths: titleWidths)
    }

    private static func screenID(for rect: CGRect) -> String {
        "\(Int(rect.origin.x)):\(Int(rect.origin.y)):\(Int(rect.width)):\(Int(rect.height))"
    }

    private static func statusTrayLeftEdge(screenRect: CGRect) -> CGFloat? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        var minLeft = screenRect.width
        for window in windows {
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 25 else { continue }

            let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let x = (bounds["X"] ?? 0) - screenRect.origin.x
            let height = bounds["Height"] ?? 0
            if height < 50, x > screenRect.width / 2 {
                minLeft = min(minLeft, x)
            }
        }
        return minLeft < screenRect.width ? minLeft : nil
    }

    private static func appHasWindow(
        pid: pid_t?,
        on screenRect: CGRect,
        primaryScreenHeight: CGFloat
    ) -> Bool {
        guard let pid else { return false }
        let target = cgScreenRect(
            from: screenRect,
            primaryScreenHeight: primaryScreenHeight
        )
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        return windows.contains { window in
            guard (window[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else {
                return false
            }
            return target.contains(windowCenter(bounds))
        }
    }

    private static func topmostAppPid(
        on screenRect: CGRect,
        primaryScreenHeight: CGFloat
    ) -> pid_t? {
        let target = cgScreenRect(
            from: screenRect,
            primaryScreenHeight: primaryScreenHeight
        )
        let ownPid = getpid()
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            let app = NSRunningApplication(processIdentifier: pid)
            guard NotchMenuOwnerCandidatePolicy.canOwnTargetMenu(
                windowLayer: window[kCGWindowLayer as String] as? Int ?? 0,
                isOwnProcess: pid == ownPid,
                isOnTargetScreen: target.contains(windowCenter(bounds)),
                isRegularApplication: app?.activationPolicy == .regular,
                hasBundleIdentifier: !(app?.bundleIdentifier?.isEmpty ?? true)
            ) else {
                continue
            }
            return pid
        }
        return nil
    }

    private static func cgScreenRect(
        from screenRect: CGRect,
        primaryScreenHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: screenRect.origin.x,
            y: primaryScreenHeight - screenRect.origin.y - screenRect.height,
            width: screenRect.width,
            height: screenRect.height
        )
    }

    private static func windowCenter(_ bounds: [String: CGFloat]) -> CGPoint {
        CGPoint(
            x: (bounds["X"] ?? 0) + (bounds["Width"] ?? 0) / 2,
            y: (bounds["Y"] ?? 0) + (bounds["Height"] ?? 0) / 2
        )
    }
}

private enum MenuBarWidthCache {
    private static let key = "menuBarWidthCache"

    static func read(bundleID: String) -> CGFloat? {
        guard let values = UserDefaults.standard.dictionary(forKey: key) as? [String: Double],
              let value = values[bundleID],
              value > 0 else {
            return nil
        }
        return CGFloat(value)
    }

    static func write(_ width: CGFloat, bundleID: String) {
        var values = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        let rounded = Double(width.rounded())
        guard values[bundleID] != rounded else { return }
        values[bundleID] = rounded
        UserDefaults.standard.set(values, forKey: key)
    }
}

private enum NotchMenuProbe {
    struct Measurement: Sendable {
        let edge: CGFloat
        let onTargetScreen: Bool
    }

    static func menuBarRightEdge(
        for pid: pid_t,
        targetScreenRect: CGRect,
        screenFrames: [CGRect],
        primaryScreenHeight: CGFloat
    ) -> Measurement? {
        let app = AXUIElementCreateApplication(pid)
        var menuBarValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXMenuBarAttribute as CFString,
            &menuBarValue
        ) == .success,
        let menuBarValue,
        CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let menuBar = unsafeBitCast(menuBarValue, to: AXUIElement.self)

        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            menuBar,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
        let children = childrenValue as? [AXUIElement],
        children.count >= 2,
        let firstPosition = position(of: children[1]) else {
            return nil
        }

        let itemScreen = screenContaining(
            axPoint: firstPosition,
            screenFrames: screenFrames,
            primaryScreenHeight: primaryScreenHeight
        )
        let effectiveOriginX = itemScreen?.origin.x ?? targetScreenRect.origin.x
        let onTargetScreen = itemScreen == targetScreenRect

        struct MenuChild {
            let x: CGFloat
            let rightEdge: CGFloat
        }
        var menuChildren: [MenuChild] = []
        for child in children {
            guard role(of: child) != "AXMenuExtra",
                  let position = position(of: child),
                  let size = size(of: child) else {
                continue
            }
            let x = position.x - effectiveOriginX
            let rightEdge = x + size.width
            if rightEdge > 0 {
                menuChildren.append(MenuChild(x: x, rightEdge: rightEdge))
            }
        }
        guard !menuChildren.isEmpty else { return nil }

        menuChildren.sort { $0.x < $1.x }
        var maxRight = menuChildren[0].rightEdge
        for index in 1..<menuChildren.count {
            let gap = menuChildren[index].x - menuChildren[index - 1].rightEdge
            if gap > 50 { break }
            maxRight = max(maxRight, menuChildren[index].rightEdge)
        }
        guard maxRight > 0 else { return nil }

        let appleMenuOffset: CGFloat = 10
        let relativeEdge = maxRight - menuChildren[0].x + appleMenuOffset
        return Measurement(
            edge: relativeEdge > 0 ? relativeEdge : maxRight,
            onTargetScreen: onTargetScreen
        )
    }

    static func screenMenuRightEdge(
        screenRect: CGRect,
        primaryScreenHeight: CGFloat
    ) -> CGFloat {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return 0
        }

        let screenTop = primaryScreenHeight - screenRect.origin.y - screenRect.height
        var maxRight: CGFloat = 0
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int ?? 0) == 25 else { continue }
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let x = (bounds["X"] ?? 0) - screenRect.origin.x
            let y = bounds["Y"] ?? 0
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            guard x >= 0,
                  x < screenRect.width,
                  y >= screenTop,
                  y < screenTop + 50 else {
                continue
            }

            let isStatusItem = owner == "Control Center"
                || owner == "SystemUIServer"
                || owner == "TextInputMenuAgent"
                || owner == "Spotlight"
            if !isStatusItem && height < 50 && x < screenRect.width / 2 {
                maxRight = max(maxRight, x + width)
            }
        }
        return maxRight
    }

    private static func screenContaining(
        axPoint: CGPoint,
        screenFrames: [CGRect],
        primaryScreenHeight: CGFloat
    ) -> CGRect? {
        screenFrames.first { frame in
            let cgRect = CGRect(
                x: frame.origin.x,
                y: primaryScreenHeight - frame.origin.y - frame.height,
                width: frame.width,
                height: frame.height
            )
            return axPoint.x >= cgRect.minX
                && axPoint.x < cgRect.maxX
                && axPoint.y >= cgRect.minY
                && axPoint.y < cgRect.maxY
        }
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        var rawValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &rawValue
        ) == .success,
        let rawValue,
        CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        var value = CGPoint.zero
        guard AXValueGetValue(
            unsafeBitCast(rawValue, to: AXValue.self),
            .cgPoint,
            &value
        ) else {
            return nil
        }
        return value
    }

    private static func size(of element: AXUIElement) -> CGSize? {
        var rawValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &rawValue
        ) == .success,
        let rawValue,
        CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        var value = CGSize.zero
        guard AXValueGetValue(
            unsafeBitCast(rawValue, to: AXValue.self),
            .cgSize,
            &value
        ) else {
            return nil
        }
        return value
    }
}

private enum NotchMenuDiagnostics {
    private static let enabled = UserDefaults.standard.bool(forKey: "menuDetectLog")
    private static let queue = DispatchQueue(label: "com.824zzy.AgentVisor.menuDetectLog")
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AgentVisor/menu-detect.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func log(_ message: String) {
        guard enabled else { return }
        queue.async {
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
