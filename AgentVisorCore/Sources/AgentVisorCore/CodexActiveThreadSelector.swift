import Foundation

/// Selects the Codex threads that should be treated as "active" — i.e.
/// surfaced as sessions in the pills / sidebar. Codex.app runs all its
/// threads inside one GUI process, so there's no per-thread PID to key
/// liveness on (unlike the claude-code CLI). A thread is active when ALL of:
///
///   1. the rollout has not been moved into Codex's explicit archive directory,
///   2. the thread is an interactive GUI conversation — one that shows in
///      Codex.app's own sidebar (`source == "vscode"`) — not a
///      programmatic `exec` run, a terminal `cli` session (surfaced by the
///      process/tty discovery path instead), or a `subagent` child, and
///   3. the thread has a rollout file on disk, and
///   4. either its `updatedAt` is within the observed window, or Codex marked
///      it archived while its rollout is still being actively written.
///
/// We deliberately do NOT gate on Codex.app being open: the threads live in
/// `state_5.sqlite` + rollout files on disk and are read-only in agent-visor
/// (original-host navigation only focuses Codex.app). Gating on the app made
/// recent sessions vanish whenever Codex was quit; the recency
/// window alone now governs visibility.
///
/// Rule (2) keeps the sidebar a mirror of Codex.app. The `exec` source
/// covers `codex exec` automation — often dozens of runs the user never
/// sees as conversations — so surfacing them only floods the list.
///
/// Rule (3) maps to "the conversation I'm currently working in":
/// `updatedAt` bumps on every turn, so it tracks chat activity. (We
/// deliberately do NOT key on spawned background processes — those can
/// outlive the conversation by hours and mistrack the active thread.)
///
/// Pure / value-in-value-out so it's unit-testable without sqlite, a
/// clock, or a running Codex.app.
public enum CodexActiveThreadSelector {
    /// Default activity window. A thread untouched for longer than this
    /// drops out of the active set even while Codex.app stays open.
    /// 42h keeps threads from the last day-and-change visible, since
    /// Codex.app threads are long-lived and `updatedAt` only bumps on a turn.
    /// The app passes a user-configurable value (AppSettings.observedWindow);
    /// this constant is the pure-Core fallback used by tests and any caller
    /// that doesn't override it.
    public static let defaultWindowSeconds: Int = 42 * 60 * 60

    /// How recently an *archived* thread's rollout JSONL must have been
    /// written for it to count as "still running". Codex flips
    /// background-research GUI threads to `archived=1` the moment they
    /// start, yet keeps appending turns to the rollout — so a fresh rollout
    /// mtime is the only reliable "a turn is in flight" signal that
    /// distinguishes them from the many genuinely-closed archived threads.
    /// Short by design: when the rollout stops growing the thread drops out
    /// within this window.
    public static let runningArchivedWindowSeconds: Int = 120

    public static func activeThreads(
        candidates: [CodexThreadCandidate],
        now: Int,
        windowSeconds: Int = defaultWindowSeconds
    ) -> [CodexThreadCandidate] {
        let cutoff = now - windowSeconds
        return candidates.filter { thread in
            guard !thread.isExplicitlyArchived else { return false }
            // GUI conversations only (excludes exec/cli/subagent), never an
            // observer/memory cwd. These gates apply whether or not the
            // thread is archived.
            guard isInteractiveGUISource(thread.source),
                  !isIgnoredObserverCwd(thread.cwd),
                  thread.rolloutModifiedAt != nil else {
                return false
            }
            if !thread.archived {
                // Normal GUI thread: governed by the recency window.
                return thread.updatedAt >= cutoff
            }
            // Archived but possibly still running: surface it ONLY while its
            // rollout JSONL is being actively written. nil mtime ⇒ can't
            // confirm liveness ⇒ exclude.
            guard let rolloutModifiedAt = thread.rolloutModifiedAt else {
                return false
            }
            let rolloutAge = now - rolloutModifiedAt
            return rolloutAge >= 0 && rolloutAge <= runningArchivedWindowSeconds
        }
    }

    /// True when the thread's `source` marks it as an interactive GUI
    /// conversation — the kind that appears in Codex.app's sidebar. Codex
    /// tags GUI/IDE threads `"vscode"`; programmatic runs are `"exec"`,
    /// terminal sessions `"cli"` (surfaced via the process/tty path), and
    /// subagent children a JSON blob like `{"subagent":{"other":"guardian"}}`.
    /// Only `"vscode"` belongs in the observed-GUI set.
    public static func isInteractiveGUISource(_ source: String) -> Bool {
        source == "vscode"
    }

    /// Internal observer/memory sessions are implementation details of the
    /// user's automation stack, not user-visible Codex conversations. Keep
    /// this in the shared selector so discovery, pruning, and metadata
    /// rediscovery snapshots agree on the same surfaced-GUI set.
    public static func isIgnoredObserverCwd(_ cwd: String) -> Bool {
        cwd.contains(".claude-mem") || cwd.contains("observer-sessions")
    }
}
