//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `digest --at` and `where --at`: answers read from a past revision's tree through git, never from the store or the working tree.
@Suite(.temporaryDirectories)
struct RevisionQueryTests {
    /// The type as the first commit declares it: one member, at line 4.
    static var first: String {
        """
        /// A widget.
        public struct Widget {
            /// Polishes it.
            public func polish() {}
        }
        """
    }

    /// The second commit: a member added ahead of the first, whose doc comment changed, so it moves to line 7.
    static var second: String {
        """
        /// A widget.
        public struct Widget {
            /// Shines it.
            public func shine() {}

            /// Polishes it, and says so.
            public func polish() {}
        }
        """
    }

    /// A repository with both commits and an uncommitted third member, which no `--at` answer may show.
    static func makeRepo() throws -> (root: URL, commits: [String]) {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(first, to: "Sources/Lib/Widget.swift", in: root)
        try TestSources.write("struct Other {}\n", to: "Sources/Lib/Other.swift", in: root)
        try TestSources.commitAll(in: root, message: "first")
        let firstHash = try TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        try TestSources.write(second, to: "Sources/Lib/Widget.swift", in: root)
        try TestSources.commitAll(in: root, message: "second")
        let secondHash = try TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        try TestSources.write(second.replacingOccurrences(of: "public struct Widget {", with: "public struct Widget {\n    public func buff() {}"), to: "Sources/Lib/Widget.swift", in: root)
        return (root, [String(firstHash.prefix(8)), String(secondHash.prefix(8))])
    }

    @Test func aDigestAtTheFirstCommitShowsItsOneMemberAtThatCommitsLine() throws {
        let repo = try Self.makeRepo()
        let answer = try SiftEngine(directory: repo.root).digest(targets: ["Widget"], at: repo.commits[0], options: DigestOptions())

        #expect(answer.contains("Widget — Sources — Sources/Lib/Widget.swift:2-5"), "\(answer)")
        #expect(answer.contains("public func polish() {}"), "\(answer)")
        #expect(!answer.contains("shine"), "\(answer)")
        #expect(!answer.contains("buff"), "\(answer)")
    }

    @Test func aDigestAtTheSecondCommitShowsBothMembersAndNotTheWorkingTreesThird() throws {
        let repo = try Self.makeRepo()
        let answer = try SiftEngine(directory: repo.root).digest(targets: ["Widget"], at: repo.commits[1], options: DigestOptions())

        #expect(answer.contains("Widget — Sources — Sources/Lib/Widget.swift:2-8"), "\(answer)")
        #expect(answer.contains("public func shine() {}"), "\(answer)")
        #expect(answer.contains("public func polish() {}"), "\(answer)")
        #expect(!answer.contains("buff"), "\(answer)")
    }

    @Test func aMemberDigestAtARevisionServesThatRevisionsSource() throws {
        let repo = try Self.makeRepo()
        let answer = try SiftEngine(directory: repo.root).digest(targets: ["Widget.polish"], at: repo.commits[0], options: DigestOptions())

        #expect(answer.contains("Widget.polish() — func — Sources/Lib/Widget.swift:4"), "\(answer)")
        #expect(!answer.contains("Widget.swift:7"), "\(answer)")
    }

    @Test func whereAtTheFirstCommitResolvesToThatCommitsFileAndLine() async throws {
        let repo = try Self.makeRepo()
        let answer = try await SiftEngine(directory: repo.root).lookup(symbol: "Widget.polish", at: repo.commits[0])

        #expect(answer.contains("Sources/Lib/Widget.swift:4"), "\(answer)")
        #expect(!answer.contains("Sources/Lib/Widget.swift:7"), "\(answer)")
    }

    @Test func theHeaderNamesTheRevisionAndSaysSyntacticAndTheNextLineCountsTheFilesParsed() async throws {
        let repo = try Self.makeRepo()
        let engine = try SiftEngine(directory: repo.root)
        for answer in try await [
            engine.digest(targets: ["Widget"], at: repo.commits[0], options: DigestOptions()),
            engine.lookup(symbol: "Widget.polish", at: repo.commits[0]),
        ] {
            let lines = answer.split(separator: "\n", omittingEmptySubsequences: false)

            #expect(lines.first?.hasSuffix("at: \(repo.commits[0]) (syntactic, from git)") == true, "\(answer)")
            #expect(lines.first?.hasPrefix("tree: ") == true, "\(answer)")
            #expect(lines.dropFirst().first?.hasPrefix("read: parsed 1 of 2 Swift files at \(repo.commits[0])") == true, "\(answer)")
        }
    }

    @Test func aRevisionWrittenAsARefIsNamedWithTheCommitItResolvedTo() throws {
        let repo = try Self.makeRepo()
        let answer = try SiftEngine(directory: repo.root).digest(targets: ["Widget"], at: "HEAD~1", options: DigestOptions())

        #expect(answer.split(separator: "\n").first?.hasSuffix("at: HEAD~1 = \(repo.commits[0]) (syntactic, from git)") == true, "\(answer)")
    }

    /// `--at HEAD` on a dirty tree says so, in the header, since the answer names `HEAD` but a caller reading it as the working tree would be wrong; any other revision — even one on the same dirty tree — says nothing, since it names a commit whatever the tree holds.
    @Test func atHeadOnADirtyTreeNotesTheWorkingTreeDiffersButNoOtherRevisionDoes() throws {
        let repo = try Self.makeRepo()
        let engine = try SiftEngine(directory: repo.root)

        let headAnswer = try engine.digest(targets: ["Widget"], at: "HEAD", options: DigestOptions())
        #expect(headAnswer.split(separator: "\n").first?.contains("(syntactic, from git; the working tree differs)") == true, "\(headAnswer)")

        let parentAnswer = try engine.digest(targets: ["Widget"], at: "HEAD~1", options: DigestOptions())
        #expect(!parentAnswer.contains("the working tree differs"), "\(parentAnswer)")
    }

    /// A clean tree gets no clause at `HEAD` either.
    @Test func atHeadOnACleanTreeHasNoDirtyNote() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.first, to: "Sources/Lib/Widget.swift", in: root)
        try TestSources.commitAll(in: root, message: "first")

        let answer = try SiftEngine(directory: root).digest(targets: ["Widget"], at: "HEAD", options: DigestOptions())

        #expect(!answer.contains("the working tree differs"), "\(answer)")
    }

    @Test func whereAtARevisionNeverClaimsToHaveReadTheWorkingTree() async throws {
        let repo = try Self.makeRepo()
        let answer = try await SiftEngine(directory: repo.root).lookup(symbol: "Widget.polish", at: repo.commits[0])

        #expect(!answer.contains("working tree,"), "\(answer)")
        #expect(!answer.contains("over the working tree"), "\(answer)")
        #expect(answer.contains("over the files parsed at \(repo.commits[0])"), "\(answer)")
    }

    @Test func aBadRevisionIsRefusedInGitsOwnWords() async throws {
        let repo = try Self.makeRepo()
        let engine = try SiftEngine(directory: repo.root)
        let digestError = #expect(throws: EngineError.self) {
            try engine.digest(targets: ["Widget"], at: "nosuchrev", options: DigestOptions())
        }
        #expect(digestError?.description.contains("fatal: Not a valid object name nosuchrev") == true, "\(String(describing: digestError))")
        await #expect(throws: EngineError.self) {
            try await engine.lookup(symbol: "Widget", at: "nosuchrev")
        }
    }

    @Test func aTargetNoFewFilesCanAnswerIsRefusedRatherThanAnsweredFromPartOfTheTree() throws {
        let repo = try Self.makeRepo()
        let engine = try SiftEngine(directory: repo.root)
        for target in [".", "Docs/Notes.md"] {
            let error = #expect(throws: EngineError.self) {
                try engine.digest(targets: [target], at: repo.commits[0], options: DigestOptions())
            }
            #expect(error?.description.contains("digest --at answers a type, a member or a Swift file") == true, "\(String(describing: error))")
        }
    }

    @Test func theFilesReadForAnAnswerAreGoneOnceItIsBuilt() throws {
        let repo = try Self.makeRepo()
        _ = try SiftEngine(directory: repo.root).digest(targets: ["Widget", "Sources/Lib/Other.swift"], at: repo.commits[0], options: DigestOptions())

        #expect(!FileManager.default.fileExists(atPath: SiftPaths.cache(in: repo.root).appendingPathComponent("at").path))
    }

    @Test func aFileTargetAtARevisionIsThatRevisionsFile() throws {
        let repo = try Self.makeRepo()
        let answer = try SiftEngine(directory: repo.root).digest(targets: ["Sources/Lib/Widget.swift"], at: repo.commits[0], options: DigestOptions())

        #expect(answer.contains("Polishes it."), "\(answer)")
        #expect(!answer.contains("shine"), "\(answer)")
    }

    /// With no index built, `--at` must resolve modules from the revision's own files, never from the (empty) store — a bare module target is refused just as consistently, whether or not an index happens to exist.
    @Test func withNoIndexBuiltAModuleTargetAnswersFooAndABareModuleIsRefused() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("public struct Foo {\n    public func go() {}\n}\n", to: "A/Foo.swift", in: root)
        try TestSources.write("public struct Bar {}\n", to: "B/Bar.swift", in: root)
        try TestSources.commitAll(in: root, message: "two modules")
        let head = try TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".sift").path))

        let engine = try SiftEngine(directory: root)
        let fooAnswer = try engine.digest(targets: ["A.Foo"], at: head, options: DigestOptions())
        #expect(fooAnswer.contains("public func go() {}"), "\(fooAnswer)")
        #expect(!fooAnswer.contains("no type or member"), "\(fooAnswer)")

        let moduleError = #expect(throws: EngineError.self) {
            try engine.digest(targets: ["A"], at: head, options: DigestOptions())
        }
        #expect(moduleError?.description.contains("digest --at answers a type, a member or a Swift file") == true, "\(String(describing: moduleError))")
    }

    /// A miss says "in the index" about the working tree's own store; under `--at` there is no such store, so it says which revision was parsed and what that cost instead.
    @Test func aMissedSymbolAtARevisionNamesTheRevisionAndTheParseCountRatherThanTheIndex() throws {
        let repo = try Self.makeRepo()
        let answer = try SiftEngine(directory: repo.root).digest(targets: ["Nonesuch"], at: repo.commits[0], options: DigestOptions())

        #expect(!answer.contains("in the index"), "\(answer)")
        #expect(answer.contains("no symbol named Nonesuch at \(repo.commits[0]) — parsed 0 of 2 Swift files naming it"), "\(answer)")
    }

    /// A file real at the revision but kept out of today's `.sift.json` answers with the rule, not with a miss that reads as "there is no such file" — the same distinction `unindexedFileAnswer` draws for the working tree, made here from the revision's own tracked paths since the snapshot never writes an excluded file to disk at all.
    @Test func aFileExcludedByTodaysConfigNamesTheRuleRatherThanClaimingNoFileMatches() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("public struct Foo {}\n", to: "Sources/Gen/Foo.swift", in: root)
        try TestSources.commitAll(in: root, message: "generated")
        let head = try TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        try TestSources.write(#"{"exclude": ["Gen"]}"#, to: ".sift.json", in: root)

        let answer = try SiftEngine(directory: root).digest(targets: ["Sources/Gen/Foo.swift"], at: head, options: DigestOptions())

        #expect(!answer.contains("no indexed file matches"), "\(answer)")
        #expect(!answer.contains("parsed 0 of"), "\(answer)")
        #expect(answer.contains("Sources/Gen/Foo.swift exists at \(head.prefix(8)) but today's config excludes it (.sift.json excludes paths containing \"Gen\")"), "\(answer)")
    }

    /// `path(_:answers:)`'s file-name-only fallback must never let an excluded file of the same name stand in for a target that names a different, included file exactly.
    @Test func digestAtARevisionAnswersTheNamedFileNotAnExcludedFileOfTheSameName() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("public struct Foo {}\n", to: "Sources/Gen/Foo.swift", in: root)
        try TestSources.write("public struct Foo {\n    public func go() {}\n}\n", to: "Sources/Lib/Foo.swift", in: root)
        try TestSources.commitAll(in: root, message: "two Foos")
        let head = try TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        try TestSources.write(#"{"exclude": ["Gen"]}"#, to: ".sift.json", in: root)
        let engine = try SiftEngine(directory: root)

        let libAnswer = try engine.digest(targets: ["Sources/Lib/Foo.swift"], at: head, options: DigestOptions())
        #expect(libAnswer.contains("public func go() {}"), "\(libAnswer)")
        #expect(!libAnswer.contains("today's config excludes it"), "\(libAnswer)")

        let genAnswer = try engine.digest(targets: ["Sources/Gen/Foo.swift"], at: head, options: DigestOptions())
        #expect(genAnswer.contains("Sources/Gen/Foo.swift exists at \(head.prefix(8)) but today's config excludes it"), "\(genAnswer)")
    }

    /// A non-config exclusion — a build manifest, a hidden or vendored path, a non-Swift file — is worded from the reason the enumerator actually gives, not the config wording that does not apply to it.
    @Test func anExcludedFileNotKeptOutByConfigNamesItsOwnReason() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("public struct Foo {}\n", to: "Sources/Lib/Foo.swift", in: root)
        try TestSources.write("// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"Lib\")\n", to: "Package.swift", in: root)
        try TestSources.commitAll(in: root, message: "with manifest")
        let head = try TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)

        let answer = try SiftEngine(directory: root).digest(targets: ["Package.swift"], at: head, options: DigestOptions())

        #expect(!answer.contains("today's config excludes it"), "\(answer)")
        #expect(answer.contains("Package.swift exists at \(head.prefix(8)) but is excluded: it is a build manifest"), "\(answer)")
    }

    /// The excluded-file notice applies per target inside a multi-target digest too, not only when the excluded file is the sole target.
    @Test func aMultiTargetDigestNamesAnExcludedTargetBesideAnAnsweredOne() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("public struct Foo {}\n", to: "Sources/Gen/Foo.swift", in: root)
        try TestSources.write(Self.first, to: "Sources/Lib/Widget.swift", in: root)
        try TestSources.commitAll(in: root, message: "gen and widget")
        let head = try TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        try TestSources.write(#"{"exclude": ["Gen"]}"#, to: ".sift.json", in: root)

        let answer = try SiftEngine(directory: root).digest(targets: ["Sources/Gen/Foo.swift", "Widget"], at: head, options: DigestOptions())

        #expect(!answer.contains("no indexed file matches"), "\(answer)")
        #expect(answer.contains("Sources/Gen/Foo.swift exists at \(head.prefix(8)) but today's config excludes it"), "\(answer)")
        #expect(answer.contains("Polishes it."), "\(answer)")
    }
}
