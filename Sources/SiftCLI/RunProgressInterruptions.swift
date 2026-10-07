//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The signals that end a plain `sift run`, each written into the run's progress file as its end before the process goes exactly as it would have without this: killed by that signal.
///
/// A source rather than a handler, because the writer locks and writes a file, which a signal handler may not do. Only a signal whose disposition is the default is watched, so one the caller had ignored (a `nohup`'s `SIGHUP`) stays ignored. The source is listening before `SIG_IGN` is set, so a signal never falls between the two. The handler's first act puts every watched signal back to the default, so a second signal kills outright however the write is going; its last re-sends the signal to the process, which the default then ends. The child is never signalled from here, as it never was: Foundation's `Process` starts it in a process group of its own, so a terminal's signal to sift's group does not reach it through this process either way.
final class RunProgressInterruptions {
    private static let watched: [Int32] = [SIGINT, SIGTERM, SIGHUP]
    private let queue = DispatchQueue(label: "sift.run.progress.signals")
    private var armed: [Int32] = []
    private var sources: [any DispatchSourceSignal] = []
    private var progress: RunProgress?

    /// Watches the signals that end the process for `progress`'s run (where `arming`) until ``end()``, which the caller makes sure runs on every path out, a throwing one included.
    static func watch(_ progress: RunProgress?, arming: Bool) -> RunProgressInterruptions {
        let interruptions = arming ? progress.map { arm(ending: $0.writer) } ?? RunProgressInterruptions() : RunProgressInterruptions()
        interruptions.progress = progress
        return interruptions
    }

    /// Stops watching and resets the run as `failed` if nothing ended it first; a second call does nothing.
    func end() {
        disarm()
        armed = []
        sources = []
        progress?.writer.reset()
    }

    /// Watches every signal still at its default disposition, ending `writer`'s run with `128 + signal` when one arrives.
    static func arm(ending writer: RunProgressWriter) -> RunProgressInterruptions {
        let interruptions = RunProgressInterruptions()
        let armed = watched.filter(isDefault)
        interruptions.armed = armed
        interruptions.sources = armed.map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: interruptions.queue)
            source.setEventHandler { handle(number, armed: armed, writer: writer) }
            source.resume()
            signal(number, SIG_IGN)
            return source
        }
        return interruptions
    }

    /// What a watched signal does: every armed signal back to its default, the run ended as `failed` with the shell's code for the signal, then the signal again, which the default turns into the process's end.
    static func handle(_ number: Int32, armed: [Int32], writer: RunProgressWriter, resend: (Int32) -> Void = { kill(getpid(), $0) }) {
        for other in armed {
            signal(other, SIG_DFL)
        }
        writer.finish(exitCode: 128 + number, phase: .failed)
        resend(number)
    }

    /// Puts every armed signal back to its default, lets a handler already queued run, then stops listening.
    func disarm() {
        for number in armed {
            signal(number, SIG_DFL)
        }
        queue.sync {}
        sources.forEach { $0.cancel() }
    }

    private static func isDefault(_ number: Int32) -> Bool {
        var current = sigaction()
        return sigaction(number, nil, &current) == 0 && current.__sigaction_u.__sa_handler == nil
    }
}
