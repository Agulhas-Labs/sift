//
// Copyright © Agulhas Labs
//

import Foundation

/// Which repository a query ran against, and whether that took resolving.
public enum ResolvedRoot: Sendable {
    /// The repository enclosing the working directory — the ordinary case, and silent.
    case enclosing(URL)
    /// No repository encloses the working directory, but exactly one indexed *repository* matches the target — `within` when only among the roots the working directory encloses, which the note must say or it claims a global uniqueness that is false.
    case adopted(URL, matching: RootEvidence, from: String, within: Bool)
    /// No repository encloses the working directory and no index could be asked about the target, but exactly one indexed repository sits *under* it — a container folder naming a subtree with one repository in it.
    case enclosedSole(URL, from: String)

    public var url: URL {
        switch self {
        case let .enclosing(url), let .adopted(url, _, _, _), let .enclosedSole(url, _): url
        }
    }

    /// The line an adopted answer carries directly under its header, so the caller is never misled about which repository replied.
    public var note: String? {
        switch self {
        case .enclosing:
            nil
        case let .adopted(url, evidence, from, within):
            // "repository" rather than "root": several roots may match and still be one repository with its worktrees, which `RepositoryIdentity` collapses before anything gets here. Saying "the only indexed root" would then be false.
            "\(Self.noteOpening)\(from)\(Self.resolvedTo)\(url.path)\(Self.onlyRepository) \(within ? "under it " : "")\(evidence.phrase))"
        case let .enclosedSole(url, from):
            // No evidence phrase, and deliberately none invented: this root was chosen for where it sits, not for anything it was asked. The note says so, because a caller who meant a different repository needs to see that the answer is about this one.
            "\(Self.noteOpening)\(from)\(Self.resolvedTo)\(url.path)\(Self.onlyRepository) under it)"
        }
    }

    /// The repository a finished answer says it resolved to, read back out of its ``note``; `nil` for an answer that carries none.
    ///
    /// Kept beside the note so the wording and its reader cannot drift. A reader of the finished answer — the transcript scan — has no other way to know which repository answered a call made from above every repository, and the answer's paths are relative to that one.
    public static func adoptedRoot(inAnswer answer: String) -> String? {
        for line in answer.split(separator: "\n").prefix(SourcePassthrough.headerSearchDepth) where line.hasPrefix(noteOpening) {
            guard let start = line.firstRange(of: resolvedTo),
                  let end = line[start.upperBound...].firstRange(of: onlyRepository)
            else {
                continue
            }
            return String(line[start.upperBound ..< end.lowerBound])
        }
        return nil
    }

    private static var noteOpening: String {
        "(no repository encloses "
    }

    private static var resolvedTo: String {
        " — resolved to "
    }

    private static var onlyRepository: String {
        ", the only indexed repository"
    }
}
