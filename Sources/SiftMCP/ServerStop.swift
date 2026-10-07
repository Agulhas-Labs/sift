//
// Copyright © Agulhas Labs
//

import Foundation

/// Why an MCP stdio server stopped serving.
///
/// The point of naming these apart is that they have different culprits and different repairs, and without the names every one of them reaches the agent as the same thing: four tools that stopped being there. A client that closed the pipe is the session ending normally; a signal is something on the machine killing the server out from under a live session; a read failure is the pipe itself going wrong. Nothing can tell them apart after the fact unless something writes them down.
public enum ServerStop: Equatable, Sendable {
    /// The client closed its end, which is the session ending normally.
    case inputClosed
    /// Reading the client's end failed, carrying the `errno` that said so.
    case inputFailed(code: Int32)
    /// A write to the client's end failed, so there is no longer anyone to answer.
    case outputClosed(detail: String)
    /// The process was signalled — `pkill`, a supervisor reaping it, a terminal hanging up.
    case signalled(number: Int32)
    /// The process that spawned this server exited, so nothing is left holding the other end of the pipe.
    ///
    /// Distinct from ``inputClosed`` on purpose, and the distinction is the finding: a client that closes its end is a session ending tidily, while a parent that dies without closing it is a client that went away *without* ending anything — the shape an orphaned server has. Reading a month of stops, the two answer different questions about the host.
    case parentExited(pid: Int32)

    /// The stable word this goes into the log under.
    ///
    /// Grouping a month of stops by cause is then a `sort | uniq -c` rather than a reading exercise.
    public var reason: String {
        switch self {
        case .inputClosed: "input-closed"
        case .inputFailed: "input-failed"
        case .outputClosed: "output-closed"
        case .signalled: "signalled"
        case .parentExited: "parent-exited"
        }
    }

    /// What a reader needs beyond the reason, in words rather than numbers.
    public var detail: String? {
        switch self {
        case .inputClosed:
            nil
        case let .inputFailed(code):
            "errno \(code): \(String(cString: strerror(code)))"
        case let .outputClosed(detail):
            detail
        case let .signalled(number):
            Self.signalName(number)
        case let .parentExited(pid):
            "parent pid \(pid)"
        }
    }

    /// One line saying what happened, for `sift status` and for a human reading the log.
    public var summary: String {
        guard let detail else { return reason }
        return "\(reason) (\(detail))"
    }

    /// The signal's name, since `15` is a number an agent has to go and look up and `SIGTERM` is an answer.
    static func signalName(_ number: Int32) -> String {
        switch number {
        case SIGTERM: "SIGTERM"
        case SIGINT: "SIGINT"
        case SIGHUP: "SIGHUP"
        case SIGQUIT: "SIGQUIT"
        case SIGUSR1: "SIGUSR1"
        case SIGUSR2: "SIGUSR2"
        default: "signal \(number)"
        }
    }
}
