//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers what a `--without` refusal says when the change it was asked to set aside is already committed: it names the flag that sets committed work aside, and the revision to give it.
@Suite(.temporaryDirectories)
struct SetAsideCommittedHintTests {
    private static var oldWording: String {
        "every file it matches is as HEAD has it"
    }

    /// A branch whose commit changes a file under the pathspec, with a clean tree, is told the base to pass to the since flag.
    @Test
    func aCommittedChangeUnderThePathspecNamesTheMergeBase() throws {
        let root = try Self.repositoryWithSources()
        let base = try TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        try TestSources.runGit(["checkout", "-q", "-b", "feature"], in: root)
        try TestSources.write("one, fixed\n", to: "Sources/one.txt", in: root)
        try TestSources.commitAll(in: root, message: "fix")

        let message = try Self.refusal(in: root)

        let short = String(base.prefix(10))

        #expect(message.contains("the commits since \(short) change it: to set those aside, add --since \(short)."), "\(message)")
        #expect(!message.contains(Self.oldWording), "\(message)")
    }

    /// On the default branch the merge-base is HEAD itself, so the refusal keeps its wording.
    @Test
    func theDefaultBranchItselfKeepsTheOldWording() throws {
        let root = try Self.repositoryWithSources()

        let message = try Self.refusal(in: root)

        #expect(message.contains(Self.oldWording), "\(message)")
        #expect(!message.contains("--since"), "\(message)")
    }

    /// Commits that change only files outside the pathspec leave the refusal as it was.
    @Test
    func commitsOutsideThePathspecKeepTheOldWording() throws {
        let root = try Self.repositoryWithSources()
        try TestSources.runGit(["checkout", "-q", "-b", "feature"], in: root)
        try TestSources.write("elsewhere\n", to: "Other/two.txt", in: root)
        try TestSources.commitAll(in: root, message: "elsewhere")

        let message = try Self.refusal(in: root)

        #expect(message.contains(Self.oldWording), "\(message)")
        #expect(!message.contains("--since"), "\(message)")
    }

    /// The text of the refusal a clean tree gets for a pathspec of `Sources`.
    private static func refusal(in root: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let store = SetAsideStore(repositoryRoot: root)
        do {
            _ = try SetAside.capture(pathspecs: ["Sources"], from: root, into: store)
        } catch let error as SetAsideError {
            return error.description
        }
        Issue.record("a clean tree was not refused", sourceLocation: sourceLocation)
        return ""
    }

    /// A repository on its default branch with one commit holding a file under the sources directory and one outside it.
    private static func repositoryWithSources() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("one\n", to: "Sources/one.txt", in: root)
        try TestSources.write("two\n", to: "Other/two.txt", in: root)
        try TestSources.commitAll(in: root, message: "base")
        return root
    }
}
