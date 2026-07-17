//
//  AppToast.swift
//  AgentVisor
//
//  Transient bottom-anchored toast for one-off feedback the chat view
//  can't render naturally — e.g. "Cursor doesn't support reopening
//  old agent transcripts; we raised the workspace window instead."
//
//  Driven by `NotificationCenter.default.post(name: .cvShowToast)` so
//  any background-thread caller can surface a message without owning
//  a binding into MainSplitView's state.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Userinfo: ["text": String]. Posts from any thread.
    static let cvShowToast = Notification.Name("AgentVisor.showToast")
}

@MainActor
final class AppToastModel: ObservableObject {
    @Published private(set) var visibleText: String?
    private var hideWorkItem: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .cvShowToast,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let text = (note.userInfo?["text"] as? String) ?? ""
            guard !text.isEmpty else { return }
            Task { @MainActor in
                self.show(text: text)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func show(text: String) {
        visibleText = text
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.visibleText = nil
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }
}

struct AppToastView: View {
    @ObservedObject var model: AppToastModel

    var body: some View {
        VStack {
            Spacer()
            if let text = model.visibleText {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(ChatTheme.secondary)
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundColor(ChatTheme.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Catppuccin.surface0.opacity(0.95))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Catppuccin.surface1, lineWidth: 0.5)
                        )
                )
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
                .padding(.bottom, 24)
                .padding(.horizontal, 24)
                .frame(maxWidth: 520)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.visibleText)
        .allowsHitTesting(false)
    }
}
