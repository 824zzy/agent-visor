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

    /// How many blocking calls are running, and how many wait for a turn.
    /// For diagnostics: a rising queue is the shape the app showed when it froze.
    static func load() async -> (running: Int, waiting: Int) {
        (await gate.busy, await gate.queued)
    }
}
