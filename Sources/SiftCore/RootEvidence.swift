//
// Copyright © Agulhas Labs
//

/// What identified a repository as the one a rootless query meant.
///
/// Kept as a type rather than a bare string because the two shapes call for different verbs and getting that wrong is a small lie in an answer whose whole job is to say which repository replied: a repository *declares* a name, and it *contains* a file. "the only indexed repository declaring ProductKit/Sources/.../RecordService.swift" describes something that does not happen.
public enum RootEvidence: Sendable, Equatable {
    /// A symbol name the repository's index records — `Depot`, `Depot.value`.
    case declaring(String)
    /// A type name the repository's index records only as an extension target — the declaration lives in a dependency this registry never indexed, and saying "declaring" would be a lie about exactly the thing the caller is trying to locate.
    case extending(String)
    /// A repo-relative file path the repository's index records — `Sources/Lib/Depot.swift`.
    case containing(String)

    /// The evidence as it reads mid-sentence, after "the only indexed repository …".
    public var phrase: String {
        switch self {
        case let .declaring(name): "declaring \(name)"
        case let .extending(name): "extending \(name)"
        case let .containing(path): "containing \(path)"
        }
    }

    /// The evidence as it reads with the target first — "… is declared in 3 indexed repositories".
    public var ambiguityPhrase: String {
        switch self {
        case let .declaring(name): "\(name) is declared in"
        case let .extending(name): "\(name) is extended in"
        case let .containing(path): "\(path) is contained by"
        }
    }
}
