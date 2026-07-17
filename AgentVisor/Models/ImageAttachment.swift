//
//  ImageAttachment.swift
//  AgentVisor
//
//  An image the user has pasted into the notch chat input but not yet sent.
//

import AppKit
import Foundation

struct ImageAttachment: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let thumbnail: NSImage

    static func == (lhs: ImageAttachment, rhs: ImageAttachment) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
