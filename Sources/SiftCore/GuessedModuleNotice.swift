//
// Copyright © Agulhas Labs
//

import Foundation

/// Names the files in an answer whose module nothing declared.
///
/// Without it, this is a failure with no in-band warning at all. Module resolution reads SwiftPM manifests, XcodeGen specs (any file name, identified by shape) and `.xcodeproj` targets; anything else falls back to the first path component, and those files still answer — they just answer about a module that does not exist. `sift init` reports it, but only to whoever runs `init`, and the answer that acts on the wrong module says nothing.
///
/// Deliberately a *notice*, not a refusal. The declarations are correct; only the module label is a guess, so withholding the answer would cost more than it saves. It follows `ParseErrorNotice` exactly — same banner shape, same "only when this answer's own files are affected" rule — because a reader who has learned to read one should not have to learn another.
public struct GuessedModuleNotice: Sendable {
    /// Paths named in an answer's banner before the remainder is counted instead.
    static var bannerPathCap: Int {
        8
    }

    /// Files named in the `status` listing before the remainder is counted instead.
    static var statusListCap: Int {
        20
    }

    /// The consequence, worded once — every surface states the same risk in the same words.
    public static var consequence: String {
        "`digest <Module>` and `Module.Type` are wrong for them"
    }

    /// The affected paths, deduplicated and ordered.
    public let paths: [String]
    /// Why these files' module is a guess, which decides what the banner tells its reader to do.
    public let reason: Reason

    public init(paths: [String], reason: Reason = .undeclared) {
        self.paths = Set(paths).sorted()
        self.reason = reason
    }

    public var isEmpty: Bool {
        paths.isEmpty
    }

    /// The remedy, worded as an instruction to pass on rather than a note to absorb.
    ///
    /// A banner addressed to the agent can fire on every answer from a repository and never reach the person who could act on it. That is not a banner too quiet; it is one addressed to the wrong reader. The reader of a tool result is the agent, `init` is a CLI command with no MCP tool behind it, and an agent handed advice it cannot execute drops it silently rather than relaying it. So the banner names who has to do it, and says that no amount of querying will.
    ///
    /// It does not *lead* with `init`: SwiftPM packages, XcodeGen specs and `.xcodeproj` targets are all read automatically, and a per-repository setup step nobody remembers to run across ten checkouts is not a remedy. What reaches this banner is a build system the tool cannot read, so the honest first line is that these files belong to no build file it understands — and a hand-written `moduleMap` is the escape hatch for that, not a setup step anybody should be performing per repository.
    static var remedy: String {
        "No query can fix this, and no build file this tool reads (SwiftPM, XcodeGen, .xcodeproj) declares them — if they do belong to a target, tell the user to run `sift init` here and take its `moduleMap` proposals"
    }

    /// The same remedy addressed to the person who can carry it out, for the one surface a human reads directly.
    ///
    /// ``remedy`` says "tell the user", because its reader is the agent relaying it. The `report` page has no relay in it, and agent-facing wording on a page written for the user is the same mistake inverted — a message addressed past its reader. Kept here rather than in the page so that the three wordings this condition has sit in one file: the day one changes, the others are on the screen.
    public static var humanRemedy: String {
        "No build file this tool reads (SwiftPM, XcodeGen, .xcodeproj) declares these files. Check the binary is current first — an upgraded one re-attributes an existing index without being asked — then, if the files do belong to a target, run `sift init` there and take its `moduleMap` proposals."
    }

    /// The line an answer carries when its own files are among the affected.
    public var banner: String? {
        banner(unnamed: 0, isUpperBound: false)
    }

    /// The words every banner for files nothing declares opens with, up to the paths it names.
    static var bannerOpening: String {
        Reason.undeclared.opening
    }

    /// Whether `line` is the first line of a banner of either reason.
    static func opensBanner(_ line: some StringProtocol) -> Bool {
        Reason.allCases.contains { line.hasPrefix($0.opening) }
    }

    /// ``banner``, with `unnamed` files counted in its remainder beside the ones ``paths`` holds past the cap.
    ///
    /// Where the count is only an upper bound and some file was only counted, the remainder is said as "up to" that many.
    private func banner(unnamed: Int, isUpperBound: Bool) -> String? {
        guard !isEmpty else { return nil }
        let named = paths.prefix(Self.bannerPathCap).joined(separator: Self.pathSeparator)
        let remainder = paths.count - min(Self.bannerPathCap, paths.count) + unnamed
        let bound = isUpperBound && unnamed > 0 ? "up to " : ""
        let tail = remainder > 0 ? " (+\(bound)\(remainder) more)" : ""
        return "\(reason.opening)\(named)\(tail) — \(Self.consequence). \(reason.remedy)."
    }

    /// What sets one path apart from the next in a banner's named list — not a bare space, which a path can hold itself.
    static var pathSeparator: String {
        ", "
    }

    /// `answers` with the banners any of them opens on taken out, and one banner per reason naming every file those banners named, for answers printed as one.
    ///
    /// A path counted in a banner's remainder rather than named is not recovered, but its count is carried into the one banner's remainder, so no file a banner counted goes unsaid; a file one banner only counted may be one another names or counts too, so where more than one banner of a reason was taken out and any file was only counted, the remainder is said as an upper bound. Where banners of both reasons were taken out, the two are returned one under the other with a blank line between, as one answer carries them.
    public static func hoisted(from answers: [String]) -> (answers: [String], banner: String?) {
        var gathered: [Reason: Gathered] = [:]
        let stripped = answers.map { answer -> String in
            var rest = Substring(answer)
            while let reason = Reason.allCases.first(where: { rest.hasPrefix($0.opening) }) {
                let line = rest.prefix { $0 != "\n" }
                gathered[reason, default: Gathered()].take(line.dropFirst(reason.opening.count))
                rest = rest.dropFirst(line.count)
                for _ in 0 ..< 2 where rest.first == "\n" {
                    rest = rest.dropFirst()
                }
            }
            return String(rest)
        }
        let banners = Reason.allCases.compactMap { reason in
            gathered[reason].flatMap { Self(paths: $0.paths, reason: reason).banner(unnamed: $0.unnamed, isUpperBound: $0.banners > 1) }
        }
        return (stripped, banners.isEmpty ? nil : banners.joined(separator: "\n\n"))
    }

    /// The `status` listing: every affected file, with the module each was guessed to be in.
    public static func statusLines(files: [FileRow]) -> [String] {
        guard !files.isEmpty else { return [] }
        var lines = ["⚠ \(files.count) file(s) have a guessed module — \(consequence):"]
        for file in files.prefix(statusListCap) {
            lines.append("  \(file.path) (guessed: \(file.module))")
        }
        if files.count > statusListCap {
            lines.append("  truncated: \(files.count - statusListCap) more files")
        }
        return lines
    }
}

public extension GuessedModuleNotice {
    /// Why a file's module is a guess.
    ///
    /// Two causes with two remedies. Where no build file this tool reads claims a file, `sift init` drafts a `moduleMap` entry from its directory name. Where a build file claims it but renames its module through a setting this tool cannot read — `PRODUCT_MODULE_NAME: $(FOO)`, an xcconfig with an `#include` — the module carries the target's name, which the build is known to replace: a banner saying no build file declares these files would be false, and `init`'s draft would be that same target name, confirming the wrong module to whoever follows it.
    enum Reason: Sendable, CaseIterable {
        case undeclared
        case unreadableRename

        /// The words a banner of this reason opens with, up to the paths it names.
        var opening: String {
            switch self {
            case .undeclared: "⚠ module guessed — no build file declares: "
            case .unreadableRename: "⚠ module guessed — a build file renames the module through a setting this tool cannot read: "
            }
        }

        /// What a count told apart by a module guessed for this reason says of it, in brackets.
        var countNote: String {
            switch self {
            case .undeclared: "module guessed from the path"
            case .unreadableRename: "module renamed by a setting this tool cannot read"
            }
        }

        /// The bracketed note for a count told apart by modules guessed for `reasons`, or nothing where none was.
        static func countNote(for reasons: Set<Self>) -> String {
            let notes = allCases.filter(reasons.contains).map(\.countNote)
            return notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))"
        }

        /// What a banner of this reason tells its reader to do.
        var remedy: String {
            switch self {
            case .undeclared: GuessedModuleNotice.remedy
            case .unreadableRename: GuessedModuleNotice.renameRemedy
            }
        }
    }
}

extension GuessedModuleNotice {
    /// The remedy for a module a build file renames unreadably: only someone who knows the real name can supply it, so `init` is named for what it cannot do rather than offered as the fix.
    static var renameRemedy: String {
        "No query can fix this, and `sift init` cannot propose the name — tell the user to map these files to the module the build really produces with a `moduleMap` entry in `.sift.json`"
    }

    /// Each file whose module is a guess, by why it is one.
    static func reasons(for guessed: [FileRow], isUnreadablyRenamed: (String) -> Bool) -> [String: Reason] {
        Dictionary(guessed.map { ($0.path, isUnreadablyRenamed($0.path) ? Reason.unreadableRename : .undeclared) }, uniquingKeysWith: { first, _ in first })
    }

    /// The lines an answer drawing on the `guessed` files opens with: one banner per reason their modules are guesses, each followed by a blank line.
    static func bannerLines(for guessed: [String], isUnreadablyRenamed: (String) -> Bool) -> [String] {
        let renamed = guessed.filter(isUnreadablyRenamed)
        let notices = [
            Self(paths: guessed.filter { !renamed.contains($0) }),
            Self(paths: renamed, reason: .unreadableRename),
        ]
        return notices.compactMap(\.banner).flatMap { [$0, ""] }
    }

    /// The banners of one reason that ``hoisted(from:)`` took out of a set of answers.
    struct Gathered {
        var paths: [String] = []
        var unnamed = 0
        var banners = 0

        /// Records one banner, read from just past its opening.
        mutating func take(_ text: Substring) {
            banners += 1
            let named = text.components(separatedBy: " — ").first ?? ""
            let pieces = named.components(separatedBy: " (+")
            let listed = pieces.first ?? named
            unnamed += pieces.dropFirst().first.flatMap { Int($0.prefix { $0.isNumber }) } ?? 0
            paths += listed.components(separatedBy: GuessedModuleNotice.pathSeparator).filter { !$0.isEmpty && !paths.contains($0) }
        }
    }
}
