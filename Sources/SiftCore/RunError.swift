//
// Copyright © Agulhas Labs
//

/// The one thing `run` refuses outright — everything else fails open, because the wrapped command is the point.
public enum RunError: Error, CustomStringConvertible, Sendable {
    case nothingToRun

    public var description: String {
        switch self {
        case .nothingToRun:
            "sift run needs a command to run — try `sift run -- swift test`."
        }
    }
}
