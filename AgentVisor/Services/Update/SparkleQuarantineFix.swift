//
//  SparkleQuarantineFix.swift
//  AgentVisor
//
//  SPUUpdaterDelegate that mirrors the no-Developer-ID Homebrew postflight on
//  every Sparkle update. It removes download-origin attributes while preserving
//  the distributed signature. Re-signing here would replace the stable release
//  certificate and invalidate Accessibility authorization on every update.
//
//  Sparkle in-app updates bypass the cask postflight entirely — they
//  download via URLSession, unzip, and atomically replace the bundle, all
//  inside Sparkle's installer XPC. So every Sparkle update reintroduces
//  the broken state for apps without Developer ID and the user has to
//  reinstall to recover. This delegate fires in the OLD process just before
//  relaunch, with `Bundle.main.bundlePath` already pointing at the new
//  (just-staged) bundle on disk. We synchronously remove the attributes before
//  returning so the relauncher launches a clean binary with its original
//  identity intact.
//

import AgentVisorCore
import Foundation
import os.log
import Sparkle

@MainActor
final class SparkleQuarantineFix: NSObject, SPUUpdaterDelegate {
    nonisolated private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "SparkleQuarantineFix")

    /// Sparkle fires this in the running (outgoing) process after the new
    /// bundle has been swapped into place on disk, just before it tells
    /// the installer to relaunch us. We get one synchronous chance to
    /// clean the bundle. Block until xattr finishes so the relaunched app sees
    /// a clean state without changing its code identity.
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        let bundlePath = Bundle.main.bundlePath

        // Strip macOS download-origin xattrs. `provenance` was added in Sonoma
        // alongside `quarantine`; neither operation changes signed bytes.
        runSynchronously("/usr/bin/xattr", ["-dr", "com.apple.quarantine", bundlePath])
        runSynchronously("/usr/bin/xattr", ["-dr", "com.apple.provenance", bundlePath])

        Self.logger.info("Sparkle download attributes removed from \(bundlePath, privacy: .public)")
    }

    private nonisolated func runSynchronously(_ launchPath: String, _ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            Self.logger.error("Failed to run \(launchPath, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
