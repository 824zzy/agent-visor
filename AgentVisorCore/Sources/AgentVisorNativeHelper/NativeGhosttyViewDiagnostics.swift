import Foundation

/// Fixed codes and bounded counts only. No terminal or application content.
struct NativeGhosttyViewReadReport: Codable, Equatable {
    enum Reason: String, Codable {
        case accessibilityNeeded = "accessibility_needed"
        case applicationChanged = "application_changed"
        case windowsUnavailable = "windows_unavailable"
        case windowNotFound = "window_not_found"
        case windowAmbiguous = "window_ambiguous"
        case deadline, traversalLimit = "traversal_limit"
        case textAreaMissing = "text_area_missing"
        case textAreaAmbiguous = "text_area_ambiguous"
        case textUnavailable = "text_unavailable"
        case textTooLarge = "text_too_large"
        case titleChanged = "title_changed"
        case conversation, overview, unsupportedFooter = "unsupported_footer"
    }
    var reason: Reason
    var windows = 0
    var matchingWindows = 0
    var elements = 0
    var textAreas = 0
}

/// One latest observation, at most 1 KiB; unchanged polls do not write.
final class NativeGhosttyViewDiagnostics {
    private let fileURL: URL
    private var previous: NativeGhosttyViewReadReport?

    init(fileURL: URL) { self.fileURL = fileURL }

    func record(_ report: NativeGhosttyViewReadReport) {
        guard previous != report else { return }
        let value: [String: Any] = [
            "observedAt": ISO8601DateFormatter().string(from: Date()),
            "reason": report.reason.rawValue,
            "windows": min(64, max(0, report.windows)),
            "matchingWindows": min(64, max(0, report.matchingWindows)),
            "elements": min(256, max(0, report.elements)),
            "textAreas": min(256, max(0, report.textAreas)),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            guard data.count <= 1_024 else { return }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            previous = report
        } catch { /* Diagnostics cannot change discovery or navigation. */ }
    }
}
