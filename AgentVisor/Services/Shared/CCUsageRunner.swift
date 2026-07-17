//
//  CCUsageRunner.swift
//  AgentVisor
//
//  Shells out to `ccusage` to get the active 5-hour block usage percentage
//  shown in the status bar. Returns nil if ccusage isn't installed or fails.
//

import Foundation
import Combine

@MainActor
final class CCUsageRunner: ObservableObject {
    static let shared = CCUsageRunner()

    /// Active block percentage (0-100), or nil when unavailable
    @Published private(set) var activeBlockPercent: Double?

    /// Whether ccusage was found on PATH at last attempt
    @Published private(set) var isAvailable: Bool = false

    private var lastFetch: Date?
    private let cacheDuration: TimeInterval = 30

    private init() {}

    /// Refresh if cache is stale. Safe to call frequently.
    func refreshIfNeeded() {
        if let last = lastFetch, Date().timeIntervalSince(last) < cacheDuration {
            return
        }
        Task { await fetch() }
    }

    private func fetch() async {
        lastFetch = Date()
        let result = await Self.runCCUsage()
        await MainActor.run {
            switch result {
            case .some(let pct):
                self.isAvailable = true
                self.activeBlockPercent = pct
            case nil:
                self.isAvailable = false
                self.activeBlockPercent = nil
            }
        }
    }

    /// Runs `ccusage blocks --json --active` and pulls `tokenLimitStatus.percentUsed`
    /// from the active block. Returns nil on any failure.
    private static func runCCUsage() async -> Double? {
        guard let binary = findCCUsage() else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = ["blocks", "--json", "--active"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let blocks = json["blocks"] as? [[String: Any]],
                  let active = blocks.first(where: { ($0["isActive"] as? Bool) == true }),
                  let status = active["tokenLimitStatus"] as? [String: Any],
                  let percent = status["percentUsed"] as? Double else {
                return nil
            }
            return percent
        } catch {
            return nil
        }
    }

    private static func findCCUsage() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ccusage",
            "/usr/local/bin/ccusage",
            NSHomeDirectory() + "/.local/bin/ccusage",
            NSHomeDirectory() + "/.bun/bin/ccusage",
        ]
        let fm = FileManager.default
        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
