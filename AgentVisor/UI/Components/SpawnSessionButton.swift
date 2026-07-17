//
//  SpawnSessionButton.swift
//  AgentVisor
//
//  Affordance for launching a visor-spawned `claude` session in a
//  Cursor workspace. Spawned sessions run under a pty owned by
//  `SpawnedSessionManager`, which gives the notch's chat composer a
//  silent input channel (no focus theft, no keystroke injection).
//
//  Visibility: shown only when ~/.claude/ide/*.lock advertises at
//  least one Cursor workspace. With a single workspace, the button
//  spawns directly. With multiple, it surfaces a picker menu.
//

import SwiftUI
import Combine
import os.log
import AgentVisorCore

struct SpawnSessionButton: View {
    @State private var workspaces: [String] = []
    @State private var isSpawning = false
    @State private var errorMessage: String?

    private let pollTimer = Timer.publish(every: 5.0, on: .main, in: .common).autoconnect()
    private let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "SpawnButton")

    var body: some View {
        Group {
            if workspaces.isEmpty {
                EmptyView()
            } else if workspaces.count == 1 {
                singleWorkspaceButton(workspaces[0])
            } else {
                multiWorkspaceMenu
            }
        }
        .onAppear { refreshWorkspaces() }
        .onReceive(pollTimer) { _ in refreshWorkspaces() }
    }

    // MARK: - Single workspace

    private func singleWorkspaceButton(_ cwd: String) -> some View {
        Button {
            spawn(cwd: cwd)
        } label: {
            buttonLabel(text: "+ New session in \(folderName(cwd))")
        }
        .buttonStyle(.plain)
        .disabled(isSpawning)
        .help("Spawn a silent-send claude session in \(displayPath(cwd))")
    }

    // MARK: - Multi-workspace picker

    private var multiWorkspaceMenu: some View {
        Menu {
            ForEach(workspaces, id: \.self) { cwd in
                Button("\(folderName(cwd))  ·  \(displayPath(cwd))") {
                    spawn(cwd: cwd)
                }
            }
        } label: {
            buttonLabel(text: "+ New session…")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isSpawning)
    }

    // MARK: - Shared label

    private func buttonLabel(text: String) -> some View {
        HStack(spacing: 6) {
            if isSpawning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }
            Text(text)
                .chatScaledFont(size: 11, weight: .medium)
                .foregroundColor(Catppuccin.lavender)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Catppuccin.lavender.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Catppuccin.lavender.opacity(0.35), lineWidth: 1)
                )
        )
    }

    // MARK: - State

    private func refreshWorkspaces() {
        workspaces = CursorMCPConfigBuilder.listWorkspaces()
    }

    private func spawn(cwd: String) {
        guard !isSpawning else { return }
        isSpawning = true
        errorMessage = nil
        Task {
            do {
                let info = try await SpawnedSessionManager.shared.spawn(
                    SpawnedSessionManager.SpawnSpec(cwd: cwd, attachCursorIDE: true)
                )
                logger.info("spawned session=\(info.sessionId.prefix(8), privacy: .public) cwd=\(cwd, privacy: .public)")
            } catch {
                logger.error("spawn failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { errorMessage = error.localizedDescription }
            }
            await MainActor.run { isSpawning = false }
        }
    }

    private func folderName(_ path: String) -> String {
        ProjectDisplayNamePolicy.displayFolderName(forPath: path)
    }

    private func displayPath(_ path: String) -> String {
        ProjectDisplayNamePolicy.displayPath(
            forCwd: path,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }
}
