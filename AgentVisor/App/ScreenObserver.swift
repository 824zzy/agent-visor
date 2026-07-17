//
//  ScreenObserver.swift
//  AgentVisor
//
//  Monitors screen configuration changes and wake from sleep events.
//  Both trigger a window recreate because the NotchPanel can end up in a
//  stale or misaligned state after the system wakes from lid-close sleep.
//

import AppKit

class ScreenObserver {
    private var screenParamsObserver: Any?
    private var didWakeObserver: Any?
    private var screensDidWakeObserver: Any?
    private let onScreenChange: () -> Void

    init(onScreenChange: @escaping () -> Void) {
        self.onScreenChange = onScreenChange
        startObserving()
    }

    deinit {
        stopObserving()
    }

    private func startObserving() {
        // Screen reconfiguration (plug/unplug external display, resolution change,
        // clamshell mode changes)
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onScreenChange()
        }

        // System wake from sleep (lid close/open without display change).
        // Screen parameters don't change on a simple lid cycle, but the panel
        // can still end up with stale frame/mouse-event state after wake.
        // Delayed so macOS has time to restore display state before we recreate.
        didWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.onScreenChange()
            }
        }

        // Screens specifically waking (separate from system wake, e.g. external
        // display power cycle). Harmless duplicate when system wakes too.
        screensDidWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.onScreenChange()
            }
        }
    }

    private func stopObserving() {
        if let screenParamsObserver = screenParamsObserver {
            NotificationCenter.default.removeObserver(screenParamsObserver)
        }
        if let didWakeObserver = didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(didWakeObserver)
        }
        if let screensDidWakeObserver = screensDidWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screensDidWakeObserver)
        }
    }
}
