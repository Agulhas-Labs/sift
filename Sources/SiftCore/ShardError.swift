//
// Copyright © Agulhas Labs
//

/// What a sharded run refuses to go on from, said as a sentence a person can act on.
///
/// Deleting a device never throws — a failed delete is a result carrying the command to run by hand, because the run has to go on and report every one of them.
public enum ShardError: Error, CustomStringConvertible, Sendable {
    /// The record of this run's devices could not be read or written.
    case ledger(String)
    /// A device could not be resolved, created or booted.
    case devices(String)
    /// The watcher that deletes this run's devices after a kill could not be started, so no device may be created.
    case watcher(String)

    public var description: String {
        switch self {
        case let .ledger(detail), let .devices(detail), let .watcher(detail):
            detail
        }
    }
}
