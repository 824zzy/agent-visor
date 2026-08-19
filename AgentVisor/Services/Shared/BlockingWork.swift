import Foundation
import os.log
import AgentVisorCore

/// Runs work that blocks its thread, away from the threads the app needs.
///
/// Swift runs every `await` in the app on a small pool of worker threads, about
/// one per core. A call that blocks — a child process, a sqlite read, a question
/// to another app — holds one of those threads until it answers. Enough of them
/// at once and the app has no thread left for a hook event, a phase change, or a
/// click, even though nothing has crashed and no work is slow on its own.
///
/// This runner keeps that work on its own threads instead. It also bounds how
/// many run at once through `BlockingWorkGate`, so a sweep over two hundred
/// sessions becomes a queue rather than a storm.
///
/// Use it for a call that waits on the machine. Do not use it for work that only
/// reads memory: the hop costs more than the work, and the bound would then
/// delay real reads for no reason.
enum BlockingWork {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "BlockingWork")

    /// Threads of our own, not the ones Swift hands out for `await`.
    ///
    /// Concurrent, because the gate is what bounds the count. If this queue were
    /// serial, the bound would be one and a slow read would delay every other.
    private static let queue = DispatchQueue(
        label: "\(AppBranding.loggerSubsystem).blocking-work",
        qos: .utility,
        attributes: .concurrent
    )

    private static let gate = BlockingWorkGate()

    /// A second counter, for reads we cannot move.
    ///
    /// Some blocking reads sit behind an actor we do not own, such as a transcript
    /// parser. We cannot put those on our own threads, because the actor decides
    /// where its work runs. We can still say how many run at once, which is what
    /// stops a fan-out over hundreds of rows.
    ///
    /// It is a separate counter for two reasons. A sweep of transcripts must not
    /// starve a question about who is alive. And one kind may end up nested inside
    /// the other, which with a single counter could stop both for good.
    private static let readGate = BlockingWorkGate()

    /// Run `body` on a thread of our own and return its answer.
    ///
    /// The caller waits as a suspended task, so it holds no thread while the
    /// work runs or while it queues for a permit.
    static func run<T: Sendable>(
        _ label: StaticString = "read",
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await gate.withPermit {
            await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
                queue.async {
                    let started = DispatchTime.now()
                    let value = body()
                    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    if elapsedMs > 1_000 {
                        logger.info("\(label, privacy: .public) took \(Int(elapsedMs))ms")
                    }
                    continuation.resume(returning: value)
                }
            }
        }
    }

    /// Bound how many of these reads run at once, without moving them.
    ///
    /// Use this when the work is already behind `async` code you do not own, so
    /// `run` cannot take it. A transcript summary is the example: the scan asks
    /// for one per row, and two hundred at once is what froze the app.
    static func limited<T: Sendable>(
        _ label: StaticString = "read",
        _ body: @Sendable () async -> T
    ) async -> T {
        let started = DispatchTime.now()
        let value = await readGate.withPermit(body)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        if elapsedMs > 1_000 {
            logger.info("\(label, privacy: .public) took \(Int(elapsedMs))ms, waiting included")
        }
        return value
    }

    /// How many blocking calls are running, and how many wait for a turn.
    /// For diagnostics: a rising queue is the shape the app showed when it froze.
    static func load() async -> (running: Int, waiting: Int) {
        (await gate.busy, await gate.queued)
    }
}
