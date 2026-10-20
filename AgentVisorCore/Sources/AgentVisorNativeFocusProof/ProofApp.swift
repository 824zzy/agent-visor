import SwiftUI
import UniformTypeIdentifiers

enum ProofAction: String, CaseIterable {
    case prepare = "Prepare 2 test windows", focusA = "Focus A", focusB = "Focus B"
    case closeB = "Close B target", cleanup = "Clean up test windows"
}

@MainActor final class ProofModel: ObservableObject {
    private let proof: NativeFocusProof
    @Published private(set) var report = #"{"scope":"native focus only","state":"not run"}"#
    @Published private(set) var recoveryWarning: String?
    var prepared: Bool { proof.fixtures != nil }
    var attempted: Bool { proof.attempted }
    init(host: NativeFocusHost = LiveGhosttyProofHost()) { proof = NativeFocusProof(host: host) }
    func perform(_ action: ProofAction) {
        do {
            switch action {
            case .prepare: try proof.prepare(); try append(proof.fixtures, event: action.rawValue)
            case .focusA: try append(proof.focus(index: 0), event: action.rawValue)
            case .focusB: try append(proof.focus(index: 2), event: action.rawValue)
            case .closeB: try append(proof.close(index: 2), event: action.rawValue)
            case .cleanup: try append(proof.cleanup(), event: action.rawValue)
            }
        } catch {
            let attempt = proof.attempt ?? "not-started"
            if action == .prepare {
                recoveryWarning = "Setup failed. Do not retry. Manually close only new windows showing AV Focus Proof \(attempt). If missing or ambiguous, leave windows untouched and report it. This is not a passed cleanup."
            }
            let data = try? JSONSerialization.data(withJSONObject: ["event": action.rawValue,
                "action": UUID().uuidString, "attempt": attempt,
                "recoveryBanner": "AV Focus Proof " + attempt,
                "manualCleanupRequired": action == .prepare,
                "error": error.localizedDescription], options: [.sortedKeys])
            if let data, let text = String(data: data, encoding: .utf8) { report += "\n" + text }
        }
    }
    private func append<T: Encodable>(_ value: T, event: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let object = try JSONSerialization.jsonObject(with: encoder.encode(value))
        let data = try JSONSerialization.data(withJSONObject: ["event": event, "value": object], options: [.sortedKeys])
        report += "\n" + (String(data: data, encoding: .utf8) ?? "")
    }
    func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "native-focus-receipt.jsonl"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do { try report.write(to: url, atomically: true, encoding: .utf8) }
            catch { report += "\nSave failed: \(error.localizedDescription)" }
        }
    }
}

/// This test app has no startup/native automation, background tasks, or global shortcuts.
@main struct ProofApp: App {
    @StateObject private var model = ProofModel()
    var body: some Scene {
        Window("Agent Visor — Native Focus Proof", id: "native-focus-proof") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Human-operated native focus test").font(.title2)
                Text("Open Ghostty yourself. Prepare creates 2 disposable plain-shell windows (3 tabs). No running conversation is used.")
                Text("If setup fails, manual cleanup may be needed. Each fixture displays a unique AV Focus Proof banner.").font(.caption)
                Text("Click Focus B, return here, then Focus A. Close B target, then Focus B again: it must reject. Finish with Clean up, then Save receipt.")
                HStack {
                    ForEach(ProofAction.allCases, id: \.self) { action in
                        Button(action.rawValue) { model.perform(action) }
                            .disabled(action == .prepare ? model.attempted : !model.prepared)
                    }
                }
                Text("Do not add tabs/splits to these fixtures. Cleanup refuses changed ownership. Quitting this app does not close any Ghostty window.").font(.caption)
                if let warning = model.recoveryWarning { Text(warning).foregroundStyle(.red) }
                ScrollView { Text(model.report).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("Save receipt…") { model.save() }
                Text("Native focus only. This does not prove Herdr/provider discovery or unblock ticket 01.").font(.caption)
            }.padding(20).frame(minWidth: 980, minHeight: 560)
        }.defaultSize(width: 1050, height: 640)
    }
}
