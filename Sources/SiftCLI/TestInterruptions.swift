//
// Copyright © Agulhas Labs
//

import Foundation

/// The signals a sharded run ends on, each one turned into the one cancellation that deletes its devices.
///
/// A source rather than a handler, on a queue of its own, because the cancellation this arms locks, spawns `simctl` and waits on it — none of which a signal handler may do — and because `TestRun.run()` holds the main thread for the length of the run, so the already-running thread the cancellation needs cannot be that one. `signal(…, SIG_IGN)` comes first for the reason `DispatchSource` documents: the default disposition ends the process before a source ever fires.
final class TestInterruptions {
    private static let watched: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    private var sources: [any DispatchSourceSignal] = []

    /// Hands every watched signal to `cancel`, for as long as this object is alive.
    func arm(_ cancel: @escaping @Sendable (Int32) -> Void) {
        let queue = DispatchQueue(label: "sift.test.signals")
        sources = TestInterruptions.watched.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { cancel(number) }
            source.resume()
            return source
        }
    }
}
