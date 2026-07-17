//
//  EditorPreferenceSelector.swift
//  AgentVisor
//
//  Live mirror of `AppSettings.editorPreference`. Drives the picker row
//  in Settings and is consumed by `FileOpener` when chat file-links
//  resolve a target editor.
//

import Combine
import Foundation

@MainActor
final class EditorPreferenceSelector: ObservableObject {
    static let shared = EditorPreferenceSelector()

    @Published var preference: EditorPreference = AppSettings.editorPreference

    /// Drives the picker's collapsed/expanded chrome, mirrored on
    /// other selectors via the same `isPickerExpanded` name.
    @Published var isPickerExpanded: Bool = false

    private init() {}

    func setPreference(_ value: EditorPreference) {
        guard value != preference else { return }
        AppSettings.editorPreference = value
        preference = value
    }
}
