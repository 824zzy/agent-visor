//
//  SessionBrowserRedirect.swift
//  AgentVisor
//
//  Keeps the menu-bar accessibility status item independent from AppDelegate.
//  AppDelegate installs the Sessions-browser action at launch, and the status
//  item invokes it for its primary action and menu command.
//

import Foundation

enum SessionBrowserRedirect {
    /// Installed by AppDelegate at launch. The closure returns to the main
    /// thread before it asks the Sessions browser to show.
    static var openMainWindow: (() -> Void)?
}
