//
//  ZedChannel.swift
//  AgentVisorCore
//
//  Zed ships four release channels from one codebase. They install as
//  separate apps with distinct bundle ids, but they SHARE one data
//  directory (`~/Library/Application Support/Zed`, because Zed's
//  `APP_NAME` is channel-independent) and separate their sqlite state
//  into `db/0-<channel>/db.sqlite`.
//
//  Agent Visor previously knew only `dev.zed.Zed`, so a Preview /
//  Nightly / Dev user got no Zed host attribution at all: the parent
//  walk fell through to `.unknown`, which means no host badge, no
//  read-only Chat banner, and terminal-style navigation for a session
//  that lives inside an editor.
//

import Foundation

public enum ZedChannel: String, CaseIterable, Sendable {
    case stable
    case preview
    case nightly
    case dev

    /// Bundle identifier of the installed app for this channel.
    /// Mirrors Zed's `ReleaseChannel::app_id`.
    public var bundleID: String {
        switch self {
        case .stable: return "dev.zed.Zed"
        case .preview: return "dev.zed.Zed-Preview"
        case .nightly: return "dev.zed.Zed-Nightly"
        case .dev: return "dev.zed.Zed-Dev"
        }
    }

    /// User-facing app name, matching Zed's own `display_name`. Used in
    /// toasts and the read-only Chat banner so copy names the app the
    /// user actually launched.
    public var displayName: String {
        switch self {
        case .stable: return "Zed"
        case .preview: return "Zed Preview"
        case .nightly: return "Zed Nightly"
        case .dev: return "Zed Dev"
        }
    }

    /// Per-channel sqlite scope directory under `<data dir>/db`.
    /// Mirrors Zed's `format!("0-{}", channel.dev_name())`.
    public var databaseScopeDirectoryName: String {
        "0-\(rawValue)"
    }

    public static func channel(forBundleID bundleID: String) -> ZedChannel? {
        allCases.first { $0.bundleID == bundleID }
    }

    /// Every known Zed bundle id, stable first. Callers that need to ask
    /// "is any Zed running?" iterate this rather than hardcoding stable.
    public static var allBundleIDs: [String] {
        allCases.map(\.bundleID)
    }
}
