import Foundation

/// Drops Cursor IDE Agents Window transcripts that are older than a
/// configurable cutoff before they reach the agent-visor sidebar.
///
/// The discovery walker (`ClaudeSessionMonitor.discoverHistoricalCursorSessions`)
/// previously sorted every transcript under `~/.cursor/projects/*/agent-transcripts/`
/// by mtime and kept the top-N. With no age cap, a user with only a
/// handful of historical Cursor transcripts saw rows weeks-old stuck
/// in the live sidebar — clicking them was a visual no-op because
/// Cursor doesn't expose any way to reopen an old agent transcript
/// inside its Composer panel; we can only raise the workspace window,
/// which the user often already has frontmost.
///
/// Generic over the hit type so the discovery walker can pass its
/// own struct without exposing it to Core.
public enum CursorHistoricalRecencyFilter {
    /// - Parameters:
    ///   - hits: Transcript candidates in caller-defined order. Order is
    ///     preserved.
    ///   - now: Reference clock value (Unix seconds or any monotonically
    ///     increasing scale that matches `mtime`).
    ///   - maxAge: Maximum age in the same units as `now`/`mtime`.
    ///     Hits older than `now - maxAge` are dropped. The boundary
    ///     itself is INCLUSIVE — a transcript exactly at the cutoff
    ///     is kept.
    ///   - mtime: Closure extracting the modification timestamp from
    ///     a hit. Same scale as `now`.
    /// - Returns: The subset of `hits` whose mtime is within the cutoff
    ///   window, in the original order. Future-dated hits (mtime > now)
    ///   are kept as a clock-skew defense — silently hiding the user's
    ///   freshest data is a worse failure mode than briefly showing a
    ///   wrongly-stamped row.
    public static func filter<Hit>(
        hits: [Hit],
        now: TimeInterval,
        maxAge: TimeInterval,
        mtime: (Hit) -> TimeInterval
    ) -> [Hit] {
        let cutoff = now - maxAge
        return hits.filter { hit in
            let t = mtime(hit)
            return t >= cutoff  // Future timestamps satisfy this naturally.
        }
    }
}
