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

    public init(paths: [String]) {
        self.paths = Set(paths).sorted()
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

    /// The words every banner opens with, up to the paths it names.
    static var bannerOpening: String {
        "⚠ module guessed — no build file declares: "
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
        return "\(Self.bannerOpening)\(named)\(tail) — \(Self.consequence). \(Self.remedy)."
    }

    /// What sets one path apart from the next in a banner's named list — not a bare space, which a path can hold itself.
    static var pathSeparator: String {
        ", "
    }

    /// `answers` with the banner any of them opens on taken out, and one banner naming every file those banners named, for answers printed as one.
    ///
    /// A path counted in a banner's remainder rather than named is not recovered, but its count is carried into the one banner's remainder, so no file a banner counted goes unsaid; a file one banner only counted may be one another names or counts too, so where more than one banner was taken out and any file was only counted, the remainder is said as an upper bound.
    public static func hoisted(from answers: [String]) -> (answers: [String], banner: String?) {
        var paths: [String] = []
        var unnamed = 0
        var banners = 0
        let stripped = answers.map { answer -> String in
            guard answer.hasPrefix(bannerOpening) else { return answer }
            banners += 1
            let line = answer.prefix { $0 != "\n" }
            let named = line.dropFirst(bannerOpening.count).components(separatedBy: " — ").first ?? ""
            let pieces = named.components(separatedBy: " (+")
            let listed = pieces.first ?? named
            unnamed += pieces.dropFirst().first.flatMap { Int($0.prefix { $0.isNumber }) } ?? 0
            paths += listed.components(separatedBy: pathSeparator).filter { !$0.isEmpty && !paths.contains($0) }
            var rest = answer.dropFirst(line.count)
            for _ in 0 ..< 2 where rest.first == "\n" {
                rest = rest.dropFirst()
            }
            return String(rest)
        }
        return (stripped, Self(paths: paths).banner(unnamed: unnamed, isUpperBound: banners > 1))
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
