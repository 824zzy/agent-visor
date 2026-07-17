//
//  SparkleQuarantineFix.swift
//  AgentVisor
//
//  SPUUpdaterDelegate that mirrors the Homebrew cask postflight on every
//  Sparkle in-app update. We ship ad-hoc signed (no Apple Developer ID),
//  so Gatekeeper relies on a clean bundle origin to allow first launch.
//
//  The cask installer at Casks/agent-visor.rb:23-28 already handles this
//  for fresh `brew install` flows: it strips `com.apple.quarantine` (which
//  macOS attaches to anything downloaded via URLSession, including Sparkle's
//  fetch) and re-signs ad-hoc to mint a fresh CDHash. Without this step the
//  user double-clicks the app and sees a silent Dock bounce (no dialog,
//  nothing in Console) because Gatekeeper refuses an ad-hoc binary that
//  still carries the download xattr.
//
//  Sparkle in-app updates bypass the cask postflight entirely — they
//  download via URLSession, unzip, and atomically replace the bundle, all
//  inside Sparkle's installer XPC. So every Sparkle update reintroduces
//  the broken state for ad-hoc apps and the user has to brew-reinstall to
//  recover. This delegate fires in the OLD process just before relaunch,
//  with `Bundle.main.bundlePath` already pointing at the new (just-staged)
//  bundle on disk. We synchronously xattr + re-sign before returning, so
//  the relauncher launches a clean binary.
//
//  Caveat: this delegate only protects updates FROM the version that
//  ships it. A user on 2.1.4 updating to 2.1.6 still hits the bug
//  because 2.1.4 has no fix; they'll need a one-time recovery shell
//  command or `brew reinstall --cask`. From 2.1.6 → 2.1.7+ the delegate
//  is in place and silent updates work.
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
    /// clean the bundle. Block until xattr + codesign finish so the
    /// relaunched app sees a clean state.
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        let bundlePath = Bundle.main.bundlePath

        // Strip macOS download-origin xattrs. `provenance` was added in
        // Sonoma alongside `quarantine`; both trip Gatekeeper for ad-hoc
        // binaries even after one is removed.
        runSynchronously("/usr/bin/xattr", ["-dr", "com.apple.quarantine", bundlePath])
        runSynchronously("/usr/bin/xattr", ["-dr", "com.apple.provenance", bundlePath])

        // Fresh ad-hoc signature → new CDHash → macOS treats this as a
        // locally-built binary instead of a downloaded one. Matches the
        // cask postflight verbatim so behavior is identical across install
        // paths.
        runSynchronously("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", bundlePath])

        Self.logger.info("SparkleQuarantineFix applied to \(bundlePath, privacy: .public)")
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
