//
//  HookInstaller.swift
//  AgentVisor
//
//  Thin shim that walks AgentRegistry and asks each provider to install
//  its own hook script. The per-agent logic (settings.json shape,
//  script payload, config paths) lives in the provider; this file
//  exists so the app-launch site doesn't need to know about agents.
//

import Foundation

struct HookInstaller {

    /// Install hooks for every known agent. Safe to call repeatedly;
    /// providers merge into existing settings rather than overwriting.
    static func installIfNeeded() {
        for provider in AgentRegistry.all {
            try? provider.installHooks()
        }
    }

    /// True iff any known agent currently has our hooks wired in.
    static func isInstalled() -> Bool {
        AgentRegistry.all.contains { $0.isInstalled() }
    }

    /// Remove our entries from every known agent. Each provider only
    /// touches its own settings, so this is fine to call broadly.
    static func uninstall() {
        for provider in AgentRegistry.all {
            provider.uninstallHooks()
        }
    }
}
