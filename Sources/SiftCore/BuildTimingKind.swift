//
// Copyright © Agulhas Labs
//

/// Which of the compiler's two timers printed a line: a whole function body, or one type-checked expression.
///
/// A body's time includes the time of every expression inside it, so the two are totalled apart and never added.
public enum BuildTimingKind: Sendable, Equatable, Hashable {
    case body
    case expression
}
