//
// Copyright © Agulhas Labs
//

/// Why a line stream stopped reading.
///
/// The distinction is the whole point: only one of these two is the client going away, and a read loop with no way to say which has happened has no account to give of why it stopped.
enum InputClosure: Equatable, Sendable {
    /// `read` returned zero: the writer really has gone.
    case endOfInput
    /// `read` failed for a reason that is not end of input, carrying the `errno` that said so.
    case readFailed(code: Int32)
}
