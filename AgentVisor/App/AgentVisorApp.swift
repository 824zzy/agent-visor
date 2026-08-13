//
//  AgentVisorApp.swift
//  AgentVisor
//
//  Dynamic Island for monitoring Claude Code instances
//

import AgentVisorCore
import SwiftUI

@main
struct AgentVisorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We use a completely custom window, so no default scene needed
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    appDelegate.openUpdateDetails(checkNow: true)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appDelegate.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    applyContentScale(.zoomIn)
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Zoom Out") {
                    applyContentScale(.zoomOut)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    applyContentScale(.reset)
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }
    }

    private func applyContentScale(_ command: ContentFontScaleCommand) {
        AppSettings.contentFontScale = command.apply(
            to: AppSettings.contentFontScale,
            step: AppSettings.contentFontScaleStep,
            min: AppSettings.contentFontScaleMin,
            max: AppSettings.contentFontScaleMax
        )
    }
}
