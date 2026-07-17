//
//  AgentBrandLogo.swift
//  AgentVisor
//
//  Renders each agent's official brand mark. Installed native apps
//  supply their current high-resolution icon; every agent also has
//  a high-resolution bundled fallback for deterministic rendering.
//

import AppKit
import AgentVisorCore
import SwiftUI

struct AgentBrandLogo: View {
    let agent: AgentID
    var size: CGFloat = 22

    var body: some View {
        let source = AgentBrandLogoSourcePolicy.source(for: agent)
        Group {
            if let appIcon = AgentBrandIconCache.image(for: source) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(source.assetName)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

@MainActor
private enum AgentBrandIconCache {
    private static var images: [String: NSImage] = [:]
    private static var misses: Set<String> = []

    static func image(for source: AgentBrandLogoSource) -> NSImage? {
        guard let bundleID = source.runtimeBundleIdentifier else { return nil }
        let key = bundleID
        if let image = images[key] { return image }
        if misses.contains(key) { return nil }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            misses.insert(key)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        images[key] = image
        return image
    }
}
