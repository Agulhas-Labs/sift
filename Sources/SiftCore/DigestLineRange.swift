//
// Copyright © Agulhas Labs
//

/// A `digest` target naming lines of a file rather than a declaration — `File.swift:12`, `File.swift:12-40`, `File.swift:12:5`, or a compiler diagnostic's `File.swift:12:5:` — split into the path and the lines.
///
/// Public because four readers have to agree on what the shape is: the renderer that answers it, the root resolver that finds the repository holding its file, the audit that credits the file it names, and the argument healing that accepts it as a name. A second spelling of the pattern in any of them would be a target one reader answers and another does not recognise.
public struct DigestLineRange: Sendable, Equatable {
    /// The file, as written.
    public let path: String
    /// The first line asked for, never after `end`: a reversed range is read the right way round, since it names the same lines.
    public let start: Int
    public let end: Int
    /// Everything after the path, as written — what a suggested call has to carry to ask for the same lines.
    public let suffix: String

    /// The column in the third form is read and discarded — a digest resolves to a declaration, not to a column inside one — and so is the trailing colon a diagnostic prints after it.
    ///
    /// `nonisolated(unsafe)` because `Regex` is not `Sendable`, not because access here needs serializing: matching against an already-compiled `Regex` reads it and mutates no shared state, so concurrent calls are safe. Unlike the `ShellQuery`/`SwiftSourcePath` precedent this reasoning stands on, "every caller is serial" would be false to claim here — `DigestTargetsTests` is not `.serialized`, and several of its tests call `parse` at once.
    nonisolated(unsafe) static let pattern = /^(?<path>.+\.swift)(?<suffix>:(?<start>\d+)(?:-(?<end>\d+)|:\d+)?:?)$/

    /// `target` read as a line range, or `nil` when it is not shaped like one.
    public static func parse(_ target: String) -> DigestLineRange? {
        guard let match = target.wholeMatch(of: pattern), let first = Int(match.output.start) else { return nil }
        let second = match.output.end.flatMap { Int($0) } ?? first
        return DigestLineRange(
            path: String(match.output.path),
            start: min(first, second),
            end: max(first, second),
            suffix: String(match.output.suffix)
        )
    }

    /// The lines as a reader would say them: `line 12`, or `lines 12-40`.
    public var spoken: String {
        start == end ? "line \(start)" : "lines \(start)-\(end)"
    }
}
