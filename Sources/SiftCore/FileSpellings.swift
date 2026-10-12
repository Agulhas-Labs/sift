//
// Copyright © Agulhas Labs
//

import Foundation

/// The absolute spellings a build may have recorded a repo-relative file under a root by, in the order they are tried: as given, under `/private`, and as the filesystem spells it.
///
/// The filesystem's spelling is asked for only once the others are spent, and at most once, since asking walks every component of the path: a file a store holds a unit for under the root as given, nearly every file, never pays for it. The `/private` spelling is offered only for a path under one of the directories macOS links into `/private`, the only paths a build can have recorded under it.
struct FileSpellings {
    /// The spellings tried before the filesystem is asked, without repeats.
    private let given: [String]
    private let absolute: String
    private var canonical: String??

    /// The spellings of the repo-relative `path` under `root`, led by `leading` where the caller already holds one.
    init(ofFile path: String, under root: URL, leading: String? = nil) {
        absolute = root.appendingPathComponent(path).path
        var given = leading.map { [$0] } ?? []
        for spelling in [absolute] + Self.privateSpelling(of: absolute) where !given.contains(spelling) {
            given.append(spelling)
        }
        self.given = given
    }

    /// Whether the filesystem has been asked for its spelling, which is what makes the cost claim checkable.
    var askedTheFilesystem: Bool {
        canonical != nil
    }

    /// Every spelling, the filesystem asked.
    mutating func all() -> [String] {
        given + [filesystemSpelling()].compactMap(\.self)
    }

    /// The first spelling `matches` accepts, the filesystem asked only where none of the others is accepted.
    mutating func first(where matches: (String) -> Bool) -> String? {
        if let spelling = given.first(where: matches) {
            return spelling
        }
        return filesystemSpelling().flatMap { matches($0) ? $0 : nil }
    }

    /// Whether `matches` accepts any spelling, the filesystem asked only where none of the others is accepted.
    mutating func contains(where matches: (String) -> Bool) -> Bool {
        first(where: matches) != nil
    }
}

private extension FileSpellings {
    /// The directories macOS links into `/private`.
    static let linkedIntoPrivate = ["/tmp", "/var", "/etc"]

    static func privateSpelling(of absolute: String) -> [String] {
        linkedIntoPrivate.contains { absolute == $0 || absolute.hasPrefix($0 + "/") } ? ["/private" + absolute] : []
    }

    /// The filesystem's spelling, `nil` where it repeats one already tried.
    mutating func filesystemSpelling() -> String? {
        if let known = canonical {
            return known
        }
        let spelling = CanonicalPath.of(absolute)
        let found = given.contains(spelling) ? nil : spelling
        canonical = .some(found)
        return found
    }
}
