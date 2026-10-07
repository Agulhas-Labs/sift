//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// The shape a refused call is judged to be, and what followed it — unit-level, against `TranscriptScan`'s own shape and follow-up classifiers, since a full transcript is more machinery than a shape rule needs.
struct RefusalShapeTests {
    @Test
    func conflictMarkersShape() {
        let shape = TranscriptScan.refusedCallShape(searchTool: "Grep", input: ["pattern": "<<<<<<<", "path": "Sources/App"])

        #expect(shape.kind == .conflictMarkers)
    }

    @Test
    func anotherRevisionShapeFromGitShow() {
        let shape = TranscriptScan.refusedCallShape(bash: "git show HEAD~1:Sources/App/Foo.swift")

        #expect(shape.kind == .anotherRevision)
    }

    @Test
    func anotherRevisionShapeFromGitLogPatch() {
        let shape = TranscriptScan.refusedCallShape(bash: "git log -p abc1234 -- Sources/App/Foo.swift")

        #expect(shape.kind == .anotherRevision)
    }

    @Test
    func outsideIndexedSourcesShape() {
        let shape = TranscriptScan.refusedCallShape(bash: "grep -n Foo .build/checkouts/Foo.swift")

        #expect(shape.kind == .outsideIndexedSources)
    }

    /// A lone re-run of a whole `Read` the hook let through — because `cwd` puts the file inside a repository that merely sits in a directory named `checkouts` — must be filed under the shape the hook actually served (`wholeFileRead`), not under `outsideIndexedSources`: the hook and the scan judge this same call through the same predicate (``SwiftTree/isOutsideIndexedSources(_:)``), so they cannot disagree about it.
    @Test
    func wholeFileReadShapeAgreesWithTheHookAboutARepositoryNamedLikeAnExcludedDirectory() {
        let path = "/Users/x/checkouts/App/Sources/View.swift"
        let cwd = "/Users/x/checkouts/App"

        // The hook's own verdict: this call is not outside the indexed sources at all.
        #expect(TextSearch.reason(forWholeRead: path, cwd: cwd) == nil)

        let shape = TranscriptScan.refusedCallShape(read: path, cwd: cwd)
        #expect(shape.kind == .wholeFileRead)
    }

    /// The mirror case: a `cwd` genuinely inside `.build/checkouts/` is outside, and the scan must file it that way too — the shared prefix stops at `.build` (a `neverAnAncestor`), so it is never shared away and the excluded components stay in the judged path whether or not `cwd` is given at all.
    @Test
    func outsideIndexedSourcesShapeRespectsTheCallsCwd() {
        let path = "/repo/.build/checkouts/kit/Sources/Big.swift"
        let cwd = "/repo/.build/checkouts/kit"

        #expect(TextSearch.reason(forWholeRead: path, cwd: cwd) != nil)

        let shape = TranscriptScan.refusedCallShape(read: path, cwd: cwd)
        #expect(shape.kind == .outsideIndexedSources)
    }

    @Test
    func fixedStringShape() {
        let shape = TranscriptScan.refusedCallShape(bash: "grep -F 'Foo.bar()' Sources/App/Foo.swift")

        #expect(shape.kind == .fixedString)
    }

    @Test
    func phraseShape() {
        let shape = TranscriptScan.refusedCallShape(searchTool: "Grep", input: ["pattern": "func go", "path": "Sources/App"])

        #expect(shape.kind == .phrase)
    }

    @Test
    func alternationShape() {
        let shape = TranscriptScan.refusedCallShape(bash: "grep -E 'Foo|Bar' Sources/App/Foo.swift")

        #expect(shape.kind == .alternation)
    }

    /// `-E` still reads as extended when it sits inside a short-flag cluster, not only on its own.
    @Test
    func alternationShapeFromAnExtendedFlagCluster() {
        let shape = TranscriptScan.refusedCallShape(bash: "grep -rnE 'Foo|Bar' Sources/App/")

        #expect(shape.kind == .alternation)
    }

    /// `-F` inside a cluster is a fixed-string search too, not only on its own.
    @Test
    func fixedStringShapeFromAFixedStringFlagCluster() {
        let shape = TranscriptScan.refusedCallShape(bash: "grep -rnF 'Foo.bar()' Sources/App/")

        #expect(shape.kind == .fixedString)
    }

    /// `egrep` is `grep -E` by another name.
    @Test
    func alternationShapeFromEgrep() {
        let shape = TranscriptScan.refusedCallShape(bash: "egrep 'Foo|Bar' Sources/App/Foo.swift")

        #expect(shape.kind == .alternation)
    }

    /// `fgrep` is `grep -F` by another name.
    @Test
    func fixedStringShapeFromFgrep() {
        let shape = TranscriptScan.refusedCallShape(bash: "fgrep 'Foo.bar()' Sources/App/Foo.swift")

        #expect(shape.kind == .fixedString)
    }

    /// The `Grep` tool is ripgrep underneath, so an unescaped `|` is alternation with no flag at all.
    @Test
    func alternationShapeFromTheGrepTool() {
        let shape = TranscriptScan.refusedCallShape(searchTool: "Grep", input: ["pattern": "Foo|Bar", "path": "Sources/App"])

        #expect(shape.kind == .alternation)
    }

    /// In ripgrep (the `Grep` tool included) `\|` is a literal pipe, not alternation — the opposite of what it means to plain `grep`.
    @Test
    func notAlternationShapeFromAnEscapedPipeInTheGrepTool() {
        let shape = TranscriptScan.refusedCallShape(searchTool: "Grep", input: ["pattern": #"Foo\|Bar"#, "path": "Sources/App"])

        #expect(shape.kind == .other)
    }

    /// `rg` is ripgrep too, so its patterns are extended by default with no `-E` to ask for it.
    @Test
    func alternationShapeFromRipgrepCommand() {
        let shape = TranscriptScan.refusedCallShape(bash: "rg 'Foo|Bar' Sources/App/")

        #expect(shape.kind == .alternation)
    }

    /// Plain `grep`, with no `-E`, reads the opposite way: an escaped `\|` is alternation and a bare `|` is not.
    @Test
    func alternationShapeFromAnEscapedPipeInBasicGrep() {
        let shape = TranscriptScan.refusedCallShape(bash: #"grep 'Foo\|Bar' Sources/App/Foo.swift"#)

        #expect(shape.kind == .alternation)
    }

    /// The mirror of the case above: a bare `|` in basic (non-extended) `grep` is not alternation.
    @Test
    func notAlternationShapeFromABarePipeInBasicGrep() {
        let shape = TranscriptScan.refusedCallShape(bash: "grep 'Foo|Bar' Sources/App/Foo.swift")

        #expect(shape.kind == .other)
    }

    @Test
    func shellWindowShape() {
        let shape = TranscriptScan.refusedCallShape(bash: "sed -n '120,160p' Sources/App/Foo.swift")

        #expect(shape.kind == .shellWindow)
    }

    @Test
    func wholeFileReadShapeFromRead() {
        let shape = TranscriptScan.refusedCallShape(read: "/repo/Sources/App/Foo.swift")

        #expect(shape.kind == .wholeFileRead)
    }

    @Test
    func wholeFileReadShapeFromCat() {
        let shape = TranscriptScan.refusedCallShape(bash: "cat Sources/App/Foo.swift")

        #expect(shape.kind == .wholeFileRead)
    }

    @Test
    func otherShape() {
        let shape = TranscriptScan.refusedCallShape(searchTool: "Grep", input: ["pattern": "Foo", "path": "Sources/App"])

        #expect(shape.kind == .other)
    }

    /// First match wins: a phrase grep under `.build/` is `outsideIndexedSources`, not `phrase` — the earlier rule in `RefusalShape`'s declared order takes it.
    @Test
    func firstMatchWinsPhraseUnderBuildIsOutsideIndexedSources() {
        let shape = TranscriptScan.refusedCallShape(bash: "grep -n 'func go' .build/checkouts/Foo.swift")

        #expect(shape.kind == .outsideIndexedSources)
    }

    @Test
    func reRunFollowUpIsTheIdenticalToolAndInput() {
        let shape = TranscriptScan.refusedCallShape(bash: "grep -n 'func go' Sources/App/Foo.swift")
        let followUp = TranscriptScan.followUp(after: shape, name: "Bash", input: ["command": "grep -n 'func go' Sources/App/Foo.swift"])

        guard case let .reRun(kind, call) = followUp else {
            Issue.record("expected a re-run, got \(followUp)")
            return
        }

        #expect(kind == .phrase)
        #expect(call == "Bash: grep -n 'func go' Sources/App/Foo.swift")
    }

    /// A `Grep` re-run is judged on its whole input, not the fields the display text happens to carry — adding `-i` is a different call, even though `pattern`/`path`/`glob`/`type` are unchanged.
    @Test
    func aGrepFollowUpThatAddsAFlagIsNotAReRun() {
        let shape = TranscriptScan.refusedCallShape(searchTool: "Grep", input: ["pattern": "Foo", "path": "Sources/App"])
        let followUp = TranscriptScan.followUp(
            after: shape,
            name: "Grep",
            input: ["pattern": "Foo", "path": "Sources/App", "-i": true]
        )

        #expect(followUp == .other)
    }

    /// The identical `Grep` input, down to every field, is a re-run.
    @Test
    func anIdenticalGrepInputIsAReRun() {
        let input: [String: Any] = ["pattern": "Foo", "path": "Sources/App"]
        let shape = TranscriptScan.refusedCallShape(searchTool: "Grep", input: input)
        let followUp = TranscriptScan.followUp(after: shape, name: "Grep", input: input)

        guard case .reRun = followUp else {
            Issue.record("expected a re-run, got \(followUp)")
            return
        }
    }

    /// A ranged `Read` is never identical to a refused whole-file one, even of the same file — the hook never refuses a ranged read in the first place, and the follow-up classifier holds that distinction on its own.
    @Test
    func aRangedReadOfTheSameFileIsNeverAReRun() {
        let shape = TranscriptScan.refusedCallShape(read: "/repo/Sources/App/Foo.swift")
        let followUp = TranscriptScan.followUp(
            after: shape,
            name: "Read",
            input: ["file_path": "/repo/Sources/App/Foo.swift", "offset": 1, "limit": 20]
        )

        #expect(followUp == .other)
    }

    @Test
    func indexFollowUpFromAnMCPTool() {
        let shape = TranscriptScan.refusedCallShape(bash: "grep -n Foo Sources/App/Foo.swift")
        let followUp = TranscriptScan.followUp(after: shape, name: "mcp__sift__where", input: ["symbol": "Foo"])

        #expect(followUp == .index)
    }

    @Test
    func indexFollowUpFromTheCLI() {
        let shape = TranscriptScan.refusedCallShape(bash: "grep -n Foo Sources/App/Foo.swift")
        let followUp = TranscriptScan.followUp(after: shape, name: "Bash", input: ["command": "sift digest Foo"])

        #expect(followUp == .index)
    }

    /// `sift run` is the CLI, but not one of the four lookup subcommands, so a refusal followed by a wrapped build redirects to nothing the index answered.
    @Test
    func aWrappedBuildIsNotAnIndexFollowUp() {
        let shape = TranscriptScan.refusedCallShape(bash: "grep -n Foo Sources/App/Foo.swift")
        let followUp = TranscriptScan.followUp(after: shape, name: "Bash", input: ["command": "sift run -- swift build"])

        #expect(followUp == .other)
    }

    @Test
    func otherFollowUpForAnUnrelatedCall() {
        let shape = TranscriptScan.refusedCallShape(bash: "grep -n Foo Sources/App/Foo.swift")
        let followUp = TranscriptScan.followUp(after: shape, name: "Edit", input: ["file_path": "/repo/Sources/App/Bar.swift"])

        #expect(followUp == .other)
    }

    /// A `ToolSearch` naming this server's tools directly is the deferred-tools door a refusal redirects through just as an `mcp__sift__*` call would.
    @Test
    func indexFollowUpFromAToolSearchSelectingSiftTools() {
        let shape = TranscriptScan.refusedCallShape(bash: "grep -n Foo Sources/App/Foo.swift")
        let followUp = TranscriptScan.followUp(
            after: shape,
            name: "ToolSearch",
            input: ["query": "select:mcp__sift__digest,mcp__sift__where"]
        )

        #expect(followUp == .index)
    }

    /// A `ToolSearch` keyword query naming the server by a whole word — `+sift digest`, `sift where` — is the same door.
    @Test
    func indexFollowUpFromAToolSearchKeywordQuery() {
        let shape = TranscriptScan.refusedCallShape(bash: "grep -n Foo Sources/App/Foo.swift")
        let followUp = TranscriptScan.followUp(after: shape, name: "ToolSearch", input: ["query": "sift where"])

        #expect(followUp == .index)
    }

    /// A `ToolSearch` for an unrelated tool is not this server's door, whatever it went looking for.
    @Test
    func otherFollowUpFromAToolSearchForAnUnrelatedTool() {
        let shape = TranscriptScan.refusedCallShape(bash: "grep -n Foo Sources/App/Foo.swift")
        let followUp = TranscriptScan.followUp(after: shape, name: "ToolSearch", input: ["query": "select:WebFetch"])

        #expect(followUp == .other)
    }
}
