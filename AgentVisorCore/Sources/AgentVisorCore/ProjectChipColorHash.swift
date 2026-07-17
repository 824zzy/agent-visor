//
//  ProjectChipColorHash.swift
//  AgentVisorCore
//
//  Deterministic mapping from a project name (cwd's last path component)
//  to one of N palette slots. Used by the sidebar's project chip to
//  give each project a stable color so the user can scan the flat
//  recency-sorted list and visually group sessions by project without
//  a section header.
//
//  Why deterministic: the chip color must NOT shift across launches —
//  if `agent-visor-dev` is "lavender" today, it stays lavender tomorrow.
//  Using `hash(into:)` would work in-process but Swift's String.hash
//  changes per launch (seeded), so we use a tiny portable FNV-1a
//  variant that's stable forever.
//

import Foundation

public enum ProjectChipColorHash {
    /// Returns a stable 0..<paletteSize index for a project name.
    /// Same input always produces same output across processes,
    /// platforms, and Swift versions. Empty input returns 0 so an
    /// "unknown project" row gets a deterministic (if uninteresting)
    /// color.
    public static func paletteIndex(for projectName: String, paletteSize: Int) -> Int {
        precondition(paletteSize > 0, "paletteSize must be positive")
        guard !projectName.isEmpty else { return 0 }
        // FNV-1a 32-bit. Constants from the original FNV spec.
        var hash: UInt32 = 0x811c9dc5
        for byte in projectName.utf8 {
            hash ^= UInt32(byte)
            hash &*= 0x01000193
        }
        return Int(hash % UInt32(paletteSize))
    }
}
