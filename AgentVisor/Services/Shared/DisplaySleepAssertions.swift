//
//  DisplaySleepAssertions.swift
//  AgentVisor
//
//  Detects whether any process is currently holding a display-sleep
//  prevention assertion. Used by the full-screen pill-hide policy:
//  video playback, video calls, and presentations all assert one of
//  these on the foreground process while they're running, and
//  full-screen Xcode / Safari / editors do not.
//
//  Public API: `DisplaySleepAssertions.isPreventingSleep(pid:)` — pass a
//  pid (the foreground full-screen app's process id) to check whether
//  *that specific app* is keeping the display awake. Pid-scoped is
//  intentional: a globally-running `caffeinate` or a background music
//  app shouldn't hide pills when the user is just coding in full-screen.
//

import Foundation
import IOKit
import IOKit.pwr_mgt

enum DisplaySleepAssertions {
    /// Names of assertion types that prevent display sleep — the relevant
    /// signals for "is the user actively watching something?". We
    /// deliberately exclude `PreventSystemSleep` and similar idle-system
    /// assertions because those fire for background work like compiles,
    /// downloads, and Time Machine that shouldn't hide pills.
    private static let displayAssertionTypes: Set<String> = [
        kIOPMAssertionTypeNoDisplaySleep as String,
        kIOPMAssertionTypePreventUserIdleDisplaySleep as String
    ]

    /// True if the given process id holds at least one display-sleep
    /// prevention assertion right now. Returns false on any IOKit error
    /// — the caller treats "unknown" the same as "not preventing
    /// sleep" so an API failure can never accidentally hide pills.
    static func isPreventingSleep(pid: pid_t) -> Bool {
        var dict: Unmanaged<CFDictionary>?
        let rc = IOPMCopyAssertionsByProcess(&dict)
        guard rc == kIOReturnSuccess, let cf = dict?.takeRetainedValue() else {
            return false
        }
        // IOPMCopyAssertionsByProcess returns a CFDictionary keyed by
        // NSNumber pids — not Int. Bridge through NSDictionary so the
        // lookup works regardless of how Swift bridges the underlying
        // CFNumber boxing.
        let nsDict = cf as NSDictionary
        guard let assertions = nsDict[NSNumber(value: pid)] as? [[String: Any]] else {
            return false
        }
        for assertion in assertions {
            guard let type = assertion[kIOPMAssertionTypeKey as String] as? String else {
                continue
            }
            if displayAssertionTypes.contains(type) {
                return true
            }
        }
        return false
    }
}
