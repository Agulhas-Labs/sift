//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// Covers the names this repository is permitted to *say* — the gate that permits rather than forbids.
///
/// ``ShippedDocumentsTests`` and `Distribution/verify-private.sh` are the other half of the privacy gate, and both are blocklists: a short list of generic phrases, plus the names of the directories sitting beside the checkout, discovered at run time so they never have to be written down. That shape has one blind spot, and it is structural — the guard checks the names it can enumerate, and a leak can sit in something it cannot name. A fixture naming a private application survives an identifier sweep, because prose has no vocabulary to grep for. A masked product, a reproduced type or a set of real measurements is nobody's neighbouring directory, so each of them clears the gate. A codebase belonging to somebody else is not a neighbour either, and it reads *more* ordinary than an invention rather than less, so no reviewer's eye stops on it.
///
/// Inverting it closes that. Every compound identifier standing in an example position — a fixture, a string literal, a doc comment, a document — has to be one of the names `Distribution/example-names.txt` carries, and that file holds only invented placeholders and public framework API. A name arriving from anywhere else fails the suite on the day it is written, which is the only day anybody still remembers where it came from.
///
/// *Written*, and not staged: the tree ``tree(in:)`` reads is what git tracks **plus** what it neither tracks nor ignores, so a file that has never been added is inside the gate, a scratch file included. The one way out is the one git already has — a path `.gitignore` covers is a path the gate does not read, which is somebody's decision rather than a new file's default.
///
/// This does not replace the blocklist and is not meant to. The two miss opposite things: a neighbouring project's name in a sentence of prose is invisible here the moment it is spelled like permitted vocabulary, and is exactly what the term check reads every file for.
@Suite(.temporaryDirectories)
struct ExampleNamesTests {
    static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent() // SiftCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // the repository root

    private static var listPath: String {
        "Distribution/example-names.txt"
    }

    /// The directory holding the captured tool output, which is the one exemption from the name check.
    ///
    /// These files are byte-exact output of `xcodebuild` and `swift`, and `Fixtures/RunOutput/PROVENANCE.md` records what each was captured from. They cannot be held to a permit list: thousands of the names in them are the build system's own vocabulary, and holding them to it would mean either an unreadable list or hand-editing the captures — and a hand-edited capture is a file claiming to be a real transcript that is in fact a written one. The `.md` beside them is prose, is not exempt, and is read like every other document.
    private static var capturesDirectory: String {
        "Tests/SiftCoreTests/Fixtures/RunOutput/"
    }

    /// The permitted home directory, and the only one a capture may name.
    private static var placeholderHome: String {
        "/Users/dev"
    }

    /// Where an exported `PATH` may point in a capture: the toolchain that printed it, and the system.
    ///
    /// Deliberately shorter than any real machine's. Everything a person installs — a language version manager, a package manager, an editor's helper, a plugin cache — is a fingerprint of who they are and what else they run, and none of it is anything a reader of a build log needs.
    private static let permittedPathEntries: Set<String> = ["/usr/local/bin", "/usr/local/sbin", "/usr/bin", "/usr/sbin", "/bin", "/sbin"]

    private static var permittedPathPrefix: String {
        "/Applications/Xcode.app/"
    }

    /// Every path the gate reads: what git tracks, plus what git neither tracks nor ignores.
    ///
    /// **A file nobody has committed yet is inside the gate, and reading two lists is what puts it there.** From `ls-files` alone the gate would be blind rather than strict: a name arriving in a new file would pass the suite until the day somebody ran `git add`, and the promise above is that it fails on the day it is *written*. The two halves would also disagree about the same file — write a fixture and add its permit line together, which is exactly what the refusal below asks for, and the staleness check would call the new line dead, because the file using it is not tracked yet. One set read once answers both halves, so neither can be told something the other would deny.
    ///
    /// A scratch file somebody never means to commit is read like any other, deliberately. The way out is the one git already has: `--exclude-standard` drops whatever `.gitignore` covers, so `.build/`, `.sift/` and `.claude/` are outside — a file leaves the gate by being ignored on purpose, never by being merely new.
    ///
    /// `-z` because every other spelling quotes a path holding a space, a newline or a byte outside ASCII, and a quoted path is not the path. What `--deleted` names comes back out: the index still carries a file the working tree no longer holds, and reading one throws in the middle of an ordinary rename, where the suite owes a verdict rather than an error. The result is a set, so an unmerged path listed once per stage arrives once, and sorted, so a verdict reads the same twice.
    ///
    /// Not private: ``CommentHistoryTests`` reads the same set, for the same reason.
    static func tree(in root: URL = repository) throws -> [String] {
        let deleted = try Set(paths(["ls-files", "-z", "--deleted"], in: root))
        let listed = try paths(["ls-files", "-z"], in: root)
            + paths(["ls-files", "-z", "--others", "--exclude-standard"], in: root)

        return Set(listed).subtracting(deleted).sorted()
    }

    /// What one `ls-files` spelling names, split on the NUL `-z` puts between paths rather than on a newline a path may itself hold.
    private static func paths(_ arguments: [String], in root: URL) throws -> [String] {
        try TestSources.runGit(arguments, in: root)
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// The exemption is from the *names* and from nothing else.
    ///
    /// What stands in its place is ``noCapturesExportedPathLeavesTheToolchain``, ``noCaptureNamesAHomeOtherThanThePlaceholder`` and ``noCaptureCarriesAMachineIdentifier``, because an exemption is exactly where a leak can sit: `xcodebuild` dumps the environment it ran under, so a capture can carry an `export PATH` line that is a verbatim dump of one person's shell — no credentials in it, and a fingerprint of a machine all the same.
    private static func captures(in root: URL = repository) throws -> [String] {
        try tree(in: root).filter { $0.hasPrefix(capturesDirectory) && $0.hasSuffix(".txt") }
    }

    /// Every file in the tree the name check reads, which is every one of them but the captures.
    private static func scanned() throws -> [String] {
        let exempt = try Set(captures())

        return try tree().filter { !exempt.contains($0) }
    }

    /// Reading a file in the tree that is not UTF-8 throws, and that is the intended direction: a file this cannot read is a file it cannot clear.
    private static func bytes(of path: String, in root: URL = repository) throws -> [UInt8] {
        try [UInt8](Data(contentsOf: root.appending(path: path)))
    }

    private static func text(of path: String) throws -> String {
        try String(contentsOf: repository.appending(path: path), encoding: .utf8)
    }

    /// The permitted names in the order the file writes them, so the sortedness claim has something to read.
    private static func permittedInFileOrder() throws -> [String] {
        try text(of: listPath)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Declarations come from every Swift file's code half — the captures included, had any been Swift — and example names from every scanned file.
    private static func readTheTree(in root: URL = repository) throws -> Survey {
        let exempt = try Set(captures(in: root))
        var survey = Survey()
        for path in try tree(in: root) {
            let content = try bytes(of: path, in: root)
            let example: [UInt8]
            if path.hasSuffix(".swift") {
                let split = ExampleNameScanner.split(swift: content)
                survey.absorb(split, from: path)
                example = split.literals
            } else {
                example = ExampleNameScanner.exampleText(ofDocument: content, path: path)
            }
            guard !exempt.contains(path) else { continue }
            for sighting in ExampleNameScanner.sightings(in: example) {
                survey.sightings.append((path: path, sighting: sighting))
            }
        }

        return survey
    }

    // MARK: - The permit

    /// Nothing in the tree says a name the list does not carry.
    ///
    /// This is the gate; everything else in this suite is a property of it.
    @Test
    func everyExampleNameInTheTreeIsOneTheListPermits() throws {
        let firstSighting = try Self.findings(against: Set(Self.permittedInFileOrder()))
        // Reduced to a `Bool` before it is asserted on: a failure otherwise prints the captured
        // sub-expression, and the sub-expression is every name in the repository.
        let saysOnlyPermittedNames = firstSighting.isEmpty

        #expect(saysOnlyPermittedNames, Comment(rawValue: Self.refusal(firstSighting)))
    }

    /// Nothing on the list is a name the tree has stopped saying.
    ///
    /// The list is readable only while it is short, and reviewable only while every line on it is load-bearing: an entry matching nothing is an entry nobody re-reads, quietly pre-authorising a name for a use that has not happened yet. Deleting the fixture that used a name means deleting its line here, in the same commit.
    @Test
    func everyNameOnTheListIsOneTheTreeStillUses() throws {
        let stale = try Self.namesNothingSaysAnyMore(among: Set(Self.permittedInFileOrder()))
        let everyLineIsUsed = stale.isEmpty

        #expect(everyLineIsUsed, Comment(rawValue: """
        \(stale.count) name\(stale.count == 1 ? " on" : "s on") \(Self.listPath) \(stale.count == 1 ? "is" : "are") no longer said anywhere in the tree:
        \(stale.map { "  \($0)" }.joined(separator: "\n"))

        Delete those lines. A permit list is reviewable only while every line on it is one somebody would notice going.

        A fixture written and not yet committed counts as a use, so this is not asking you to delete a line you have just correctly added. A file git *ignores* does not count, and never did.
        """))
    }

    /// The first sighting of every name the tree says that neither `permitted` nor the tree's own declarations account for.
    ///
    /// Split out from the gate so the property can be run over a fixture repository of three files, which is the only way to establish what the gate does with a file git has not been told about yet. Over this repository it is the gate itself, called with the published list.
    private static func findings(against permitted: Set<String>, in root: URL = repository) throws -> [String: (path: String, line: Int)] {
        let survey = try readTheTree(in: root)
        var firstSighting: [String: (path: String, line: Int)] = [:]
        for found in survey.sightingsOwingAPermit {
            let name = found.sighting.name
            guard !permitted.contains(name), !survey.declared.contains(name), firstSighting[name] == nil else { continue }
            firstSighting[name] = (path: found.path, line: found.sighting.line)
        }

        return firstSighting
    }

    /// The names on `permitted` that nothing in the tree says any more — the staleness verdict, over the same set of files the finding above reads.
    private static func namesNothingSaysAnyMore(among permitted: Set<String>, in root: URL = repository) throws -> [String] {
        try permitted.subtracting(readTheTree(in: root).unaccountedFor).sorted()
    }

    /// A line on the list is not itself a use of the name on it.
    ///
    /// Asserted against a made-up survey rather than the tree, because there is no name in the repository today whose only site is the list — which is the point: the property has to hold *before* one exists. Were the list its own evidence, pasting a name onto it to silence the permit check would satisfy the staleness check in the same stroke, and nothing anywhere would ever say the line was doing no work.
    @Test
    func theListIsNotEvidenceOfItsOwnNames() {
        var onlyTheListSaysIt = Survey()
        onlyTheListSaysIt.sightings = [
            (path: Self.listPath, sighting: ExampleNameScanner.Sighting(name: "GizmoKit", line: 3)),
        ]
        var somethingElseSaysItToo = onlyTheListSaysIt
        somethingElseSaysItToo.sightings.append(
            (path: "Tests/Widget.txt", sighting: ExampleNameScanner.Sighting(name: "GizmoKit", line: 1))
        )

        #expect(onlyTheListSaysIt.unaccountedFor.isEmpty, "a line on the list counted as its own use — the staleness check could never fail")
        #expect(somethingElseSaysItToo.unaccountedFor == ["GizmoKit"])
    }

    /// Sorted and free of duplicates, which is what makes a commit that adds a line legible as the thing to look at.
    @Test
    func theListIsSortedAndCarriesNoNameTwice() throws {
        let permitted = try Self.permittedInFileOrder()

        let inOrder = permitted == permitted.sorted()
        let eachOnce = permitted.count == Set(permitted).count

        #expect(inOrder, "\(Self.listPath) is not sorted — a reviewer cannot see what a commit added")
        #expect(eachOnce, "\(Self.listPath) carries a name twice")
    }

    // MARK: - What counts as the tree

    /// A file git does not track yet is read like any other, so a name fails on the day it is written.
    ///
    /// Reading tracked files alone, the same fixture would pass the suite while it was untracked and fail it one `git add` later, which leaves the gate blind rather than strict for exactly as long as nobody has staged anything — and *blind until staged* is a smaller copy of the blocklist's own blind spot.
    ///
    /// Run over a fixture repository rather than this one, because what has to be established is what the gate does with a file git has not been told about, and there is no such file here on a clean tree. The unpermitted name is assembled at run time for the reason ``aNameTheListDoesNotCarryIsNamedWithItsLine`` gives: written down, this file would say the name it is asserting nobody can say.
    @Test
    func aFileGitDoesNotTrackYetIsReadLikeAnyOther() throws {
        let unknown = "Qzx" + "Untracked" + "Sighting"
        let root = try TestSources.makeTempRepo()
        try TestSources.write("says \(unknown)\n", to: "Tests/scratch.txt", in: root)

        let found = try Self.findings(against: [], in: root)

        #expect(found[unknown]?.path == "Tests/scratch.txt")
        #expect(found[unknown]?.line == 1)
    }

    /// A permit line whose only user is a file git does not track yet is not stale.
    ///
    /// The other half of the same set, and the half that would give wrong advice: write the fixture and add its line in one go — which is what the refusal asks for — and a staleness check blind to untracked files tells the author to delete the line they have just correctly added. Both halves read ``tree(in:)``, so a file cannot be a use for one and not for the other.
    @Test
    func aPermitLineUsedOnlyByAnUntrackedFileIsNotStale() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("GizmoKit\n", to: "Tests/scratch.txt", in: root)

        #expect(try Self.namesNothingSaysAnyMore(among: ["GizmoKit"], in: root).isEmpty)
    }

    /// A file git is told to ignore is outside the gate, which is the only way out of it.
    ///
    /// `.build/` and the agent worktrees under `.claude/` are the two that matter in practice: both are full of names nobody wrote, and neither is anything this repository publishes.
    @Test
    func aFileGitIgnoresIsNotReadAtAll() throws {
        let unknown = "Qzx" + "Ignored" + "Sighting"
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n.claude/\n", to: ".gitignore", in: root)
        try TestSources.write("says \(unknown)\n", to: ".build/log.txt", in: root)
        try TestSources.write("says \(unknown)\n", to: ".claude/worktrees/agent/scratch.txt", in: root)

        #expect(try Self.findings(against: [], in: root).isEmpty)
    }

    /// A path the index still names and the working tree no longer holds is not read.
    ///
    /// Halfway through an ordinary rename that path is in `ls-files` and gone from disk. Read, it throws — and an error is not a verdict: the suite would report that it could not run rather than that the tree is clean or dirty.
    @Test
    func aPathDeletedFromTheWorkingTreeIsNotRead() throws {
        let unknown = "Qzx" + "Deleted" + "Sighting"
        let root = try TestSources.makeTempRepo()
        try TestSources.write("says \(unknown)\n", to: "Tests/gone.txt", in: root)
        try TestSources.commitAll(in: root, message: "add")
        try FileManager.default.removeItem(at: root.appending(path: "Tests/gone.txt"))

        #expect(try Self.findings(against: [], in: root).isEmpty)
    }

    /// The two listings arrive as one list, each path once and in order.
    ///
    /// They can name the same path in odd states — an unmerged path is listed once per stage — and a verdict that names a file twice, or names files in whatever order two commands happened to print them, is a verdict a reader cannot compare with yesterday's.
    @Test
    func theTreeNamesEachPathOnceAndInOrder() throws {
        let paths = try Self.tree()

        #expect(paths == paths.sorted())
        #expect(paths.count == Set(paths).count)
    }

    // MARK: - The exemption

    /// The captures are exempt from the names, and they are the only files that are.
    ///
    /// Asserted as a partition rather than as a hand-kept list, because the exemption is a rule about one directory and a list can fall behind the tree. What a capture arriving tomorrow must not be able to do is join the exemption without joining the environment check, and ``everyCaptureIsReadByTheEnvironmentCheck`` is the other half of that.
    @Test
    func theCapturesAreTheOnlyFilesExemptFromTheList() throws {
        let inTheTree = try Set(Self.tree())
        let scanned = try Set(Self.scanned())
        let captures = try Set(Self.captures())

        let partitionsTheTree = inTheTree.subtracting(scanned) == captures
        let allUnderTheCaptures = captures.allSatisfy { $0.hasPrefix(Self.capturesDirectory) }
        let noneOutsideTheTree = scanned.subtracting(inTheTree).isEmpty

        #expect(partitionsTheTree, "a file in the tree is exempt from the name check and is not a capture")
        #expect(allUnderTheCaptures, "a file outside \(Self.capturesDirectory) is exempt from the name check")
        #expect(noneOutsideTheTree, "the name check reads a path the tree does not track")
    }

    /// A Swift file is read as code and a fixture is read as content.
    ///
    /// Nothing today is both, and this is what says so.
    ///
    /// The two readings disagree about the same bytes, and the disagreement is not academic: declarations are harvested from Swift code and then permitted everywhere, so a `.swift` file placed among the fixtures would hand every type it declared a permit. There are none. If one arrives, this fails rather than the gate quietly widening.
    @Test
    func noSwiftFileInTheTreeSitsUnderAFixturesDirectory() throws {
        for path in try Self.tree() where path.hasSuffix(".swift") {
            let isAFixture = path.contains("/Fixtures/")
            #expect(!isAFixture, "\(path) is Swift source under Fixtures — the gate reads it as code, not as content")
        }
    }

    // MARK: - What the gate reads, and what it refuses

    /// A name written in code is not read; the same name in a string literal or a comment is.
    @Test
    func aNameInCodeIsNotReadAndOneInAStringIs() {
        let source = Array("""
        struct GizmoKit {
            let sample = "OrchardApp"
            // and DepotStore
        }
        """.utf8)
        let split = ExampleNameScanner.split(swift: source)

        #expect(ExampleNameScanner.declaredNames(inCode: split.code).contains("GizmoKit"))
        #expect(Set(ExampleNameScanner.sightings(in: split.example).map(\.name)) == ["OrchardApp", "DepotStore"])
    }

    /// An escape and the byte it escapes are both blanked, so a literal's text is never joined to the letter naming the escape.
    ///
    /// A newline escape at the head of a literal otherwise joins its own letter to the name after it, and produces a name nothing wrote on a list a human has to review line by line. The source here is assembled from pieces rather than written out for that exact reason: written out, this file would say the name it is asserting nobody can say.
    @Test
    func anEscapeAndTheByteItEscapesAreBothBlanked() {
        let escape = #"\"#
        let source = Array(("let line = \"" + escape + "n" + "WidgetRow" + escape + "t" + "GizmoTools\"").utf8)
        let split = ExampleNameScanner.split(swift: source)

        #expect(Set(ExampleNameScanner.sightings(in: split.example).map(\.name)) == ["WidgetRow", "GizmoTools"])
    }

    /// A raw string is closed only by its own delimiter, so a quotation mark inside one does not end it.
    ///
    /// Were it read as ending there, the tail of the literal would be read as code — the names in it lost, and `let` and the identifier after it harvested as a declaration that would then be permitted everywhere.
    @Test
    func aRawStringIsClosedOnlyByItsOwnDelimiter() {
        let source = Array(##"let raw = #"BayCard "ChuteTap" TileCard"#, let after = "SummaryCard""##.utf8)
        let split = ExampleNameScanner.split(swift: source)

        #expect(Set(ExampleNameScanner.sightings(in: split.example).map(\.name)) == ["BayCard", "ChuteTap", "TileCard", "SummaryCard"])
    }

    /// A nested block comment closes at its own depth rather than at the first `*/`.
    @Test
    func aNestedBlockCommentClosesAtItsOwnDepth() {
        let source = Array("/* AxisRail /* BayFloor */ ChuteTap */ let sample = 1".utf8)
        let split = ExampleNameScanner.split(swift: source)

        #expect(Set(ExampleNameScanner.sightings(in: split.example).map(\.name)) == ["AxisRail", "BayFloor", "ChuteTap"])
        #expect(ExampleNameScanner.declaredNames(inCode: split.code).contains("sample"))
    }

    /// A labelled Swift signature spelled in backticks in a doc comment is a code reference, and its argument labels are not names the list needs to permit.
    ///
    /// The same shape of word in ordinary prose, unbackticked, is not shielded by anything nearby and still has to clear the list. The labels are assembled from pieces that are not themselves compound, the way the rest of this suite invents an unpermitted name — written whole, this file would need a permit line for the exact fixture it is proving the gate does not need one for.
    @Test
    func aBacktickedSignaturesLabelsAreExemptAndPlainProseIsNot() {
        let firstLabel = "for" + "Gizmo" + "Bay"
        let secondLabel = "below" + "Chute"
        let thirdLabel = "consult" + "Tile" + "Card"
        let source = Array("""
        /// See `events(\(firstLabel):on:state:\(secondLabel):probes:\(thirdLabel):)`, described below.
        /// TanagerWidget is not backticked, and still has to clear the list.
        struct Sample {}
        """.utf8)
        let split = ExampleNameScanner.split(swift: source)
        let names = Set(ExampleNameScanner.sightings(in: split.example).map(\.name))

        #expect(!names.contains(firstLabel))
        #expect(!names.contains(secondLabel))
        #expect(!names.contains(thirdLabel))
        #expect(names.contains("TanagerWidget"))
    }

    /// A backticked word with no `(` beside it is not a signature, and the exemption never reaches it — wrapping a name in backticks alone is not a way to clear the list.
    ///
    /// It guards a *wider* exemption than the one that exists: a span with no parentheses in it is a sighting whether or not backticks are read at all, so this passes either way and pins nothing about today's rule. `aBacktickedSignaturesLabelsAreExemptAndPlainProseIsNot` is the test that pins it.
    @Test
    func aBareBacktickedWordWithNoParensIsNotExempt() {
        let source = Array("/// `TanagerWidget` names the type.".utf8)
        let split = ExampleNameScanner.split(swift: source)

        #expect(Set(ExampleNameScanner.sightings(in: split.example).map(\.name)) == ["TanagerWidget"])
    }

    /// A name neither list accounts for is a finding, and the finding carries the line it was read on.
    ///
    /// The name is assembled at run time rather than written down, because writing it down would put it in this file's own example half and the gate would then be reporting on its own test.
    @Test
    func aNameTheListDoesNotCarryIsNamedWithItsLine() {
        let unknown = "Qzx" + "Never" + "Permitted"
        let source = Array("""
        struct GizmoKit {
            let sample = "\(unknown)"
        }
        """.utf8)

        let found = ExampleNameScanner.unpermittedNames(
            in: source,
            isSwift: true,
            permitted: ["GizmoKit"],
            declared: ["GizmoKit"]
        )

        #expect(found == [ExampleNameScanner.Sighting(name: unknown, line: 2)])
    }

    /// The refusal names both legitimate repairs and rules out the third.
    ///
    /// A gate is worth what its failure message is worth. The repair this exists to prevent is the cheapest one — paste the name onto the list, watch the suite go green — and it is cheapest precisely when somebody is in a hurry, which is when it happens. So the message says out loud that the file is published, and that a real name on it is the leak rather than the fix.
    @Test
    func theRefusalSaysBothLegitimateRepairs() {
        let refusal = Self.refusal(["Qzx" + "Something": (path: "Tests/Widget.txt", line: 12)])

        #expect(refusal.contains("Tests/Widget.txt:12"))
        #expect(refusal.contains("rename"))
        #expect(refusal.contains("published"))
        #expect(refusal.contains(Self.listPath))
    }

    /// What the gate says when it finds something: the verdict, then the residue, then the two moves that answer it.
    private static func refusal(_ findings: [String: (path: String, line: Int)]) -> String {
        let named = findings.keys.sorted()
        // Every name, however many: the list is the fix's input, and a capped one costs a build-and-test round per page.
        let shown = named.map { name in
            let site = findings[name]
            return "  \(site?.path ?? "?"):\(site?.line ?? 0)  \(name)"
        }

        return """
        \(named.count) name\(named.count == 1 ? "" : "s") said in the tree \(named.count == 1 ? "is" : "are") not permitted by \(listPath):
        \(shown.joined(separator: "\n"))

        Two answers to this are legitimate:
          * rename the fixture to a placeholder the list already carries — Gizmo, Depot, Orchard, Catalogue and the warehouse vocabulary are what the examples here are built from, and reusing one costs nothing;
          * the name is newly invented, so add it to \(listPath) in this commit, sorted, where a reviewer sees the line it adds.

        Adding a name that belongs to something real is not one of them. \(listPath) is published: a line on it is a name this repository has decided to say out loud.
        """
    }

    // MARK: - The captures, which the names do not cover

    /// No capture names a home directory but the placeholder.
    ///
    /// Read over the captures alone. `/Users/you`, `/Users/someone` and `/Users/nobody` are deliberate stand-ins elsewhere in this repository's documents and tests, where a second name makes an example clearer. A capture has no such need: everything in one came off a single machine.
    @Test
    func noCaptureNamesAHomeOtherThanThePlaceholder() throws {
        var found: [String] = []
        for path in try Self.captures() {
            let content = try Self.text(of: path)
            for site in Self.homeDirectories(in: content) where site.home != Self.placeholderHome {
                found.append("\(path):\(site.line) names '\(site.home)'")
            }
        }

        let onlyThePlaceholder = found.isEmpty

        #expect(onlyThePlaceholder, Comment(rawValue: """
        a capture names a home directory that is not \(Self.placeholderHome):
        \(found.prefix(10).joined(separator: "\n"))
        Replace it, and record the substitution in \(Self.capturesDirectory)PROVENANCE.md beside the others.
        """))
    }

    /// No capture's exported `PATH` names anything outside the toolchain and the system.
    ///
    /// `xcodebuild` dumps the shell `PATH` into a capture verbatim, and a permit list of *names* can never look at it, because a capture is exempt from that by necessity. An exemption from one check is a reason to write the other, not a reason to stop looking.
    @Test
    func noCapturesExportedPathLeavesTheToolchain() throws {
        var found: [String] = []
        for path in try Self.captures() {
            let content = try Self.text(of: path)
            for site in Self.exportedPathEntries(in: content) {
                guard !Self.permittedPathEntries.contains(site.entry),
                      !site.entry.hasPrefix(Self.permittedPathPrefix) else { continue }
                found.append("\(path):\(site.line) exports a PATH naming '\(site.entry)'")
            }
        }

        let toolchainAndSystemOnly = found.isEmpty

        #expect(toolchainAndSystemOnly, Comment(rawValue: """
        a capture's exported PATH names a directory that is neither the toolchain nor the system:
        \(found.prefix(10).joined(separator: "\n"))
        Cut the PATH back to the Xcode entries plus \(Self.permittedPathEntries.sorted().joined(separator: ":")), leaving the line count alone, and record the substitution in \(Self.capturesDirectory)PROVENANCE.md.
        """))
    }

    /// No capture carries an identifier of the machine it was taken on — only the placeholder standing in for one.
    ///
    /// The home-directory check cannot see them, since none is the name of a home: a destination's identifier in either of its shapes, on `xcodebuild`'s destination lines or in a `-destination`, a simulator's device directory, the per-user temporary directory, and the hash Xcode names a DerivedData folder with — derived from the project's path, so it can be checked against a guessed one. Each has a placeholder of the same shape, so a parser still reads a well-formed line.
    @Test
    func noCaptureCarriesAMachineIdentifier() throws {
        var found: [String] = []
        for path in try Self.captures() {
            let content = try Self.text(of: path)
            for site in Self.machineIdentifiers(in: content) {
                found.append("\(path):\(site.line) carries \(site.kind) '\(site.value)'")
            }
        }

        let onlyPlaceholders = found.isEmpty

        #expect(onlyPlaceholders, Comment(rawValue: """
        a capture carries an identifier of the machine it was taken on:
        \(found.prefix(10).joined(separator: "\n"))
        Replace each with its placeholder — \(Self.machineIdentifierShapes.map { "\($0.kind): \($0.placeholder)" }.joined(separator: "; ")) — and record the substitution in \(Self.capturesDirectory)PROVENANCE.md.
        """))
    }

    /// A real-looking identifier of each shape is a finding, and the placeholder standing in for it is not.
    @Test
    func aMachineIdentifierIsFoundAndItsPlaceholderIsNot() {
        let planted = """
        { platform:macOS, arch:arm64, id:00008103-001C3D5A2E90801E, name:My Mac }
        xcodebuild -scheme Depot-Package -destination id=5E2B9C41-7A03-4F6D-9E18-C2D47B8A0F35 test
        -I /Users/dev/Library/Developer/Xcode/DerivedData/Gizmo-fqhzvnrkeymtplacsdubjgoiwxle/Build/Products/Debug
        export CCHROOT\\=/var/folders/k2/r8vq1m0zt5c9wpl3hx7ydn4b0000gn/C
        { platform:iOS Simulator, arch:arm64, id:3C9A17E2-55B0-4D8F-A1C6-0E7B92F4D318, OS:26.0, name:iPhone 17 }
        xcodebuild -scheme Depot-Package -destination 'platform=macOS,id=00008112-001A2B3C4D5E6F70' test
        /Users/dev/Library/Developer/CoreSimulator/Devices/9B41E7D2-0C58-4A3F-8E16-5D2F70C9A4B1/data/tmp
        """
        let placeholders = """
        { platform:macOS, arch:arm64, id:00000000-0000000000000000, name:My Mac }
        xcodebuild -scheme Depot-Package -destination id=00000000-0000-0000-0000-000000000000 test
        -I /Users/dev/Library/Developer/Xcode/DerivedData/Gizmo-xxxxxxxxxxxxxxxxxxxxxxxxxxxx/Build/Products/Debug
        export CCHROOT\\=/var/folders/00/0000000000000000000000000000gn/C
        { platform:iOS Simulator, arch:arm64, id:00000000-0000-0000-0000-000000000000, OS:26.0, name:iPhone 17 }
        xcodebuild -scheme Depot-Package -destination 'platform=macOS,id=00000000-0000000000000000' test
        /Users/dev/Library/Developer/CoreSimulator/Devices/00000000-0000-0000-0000-000000000000/data/tmp
        """

        let findings = Self.machineIdentifiers(in: planted)

        #expect(findings.map(\.line) == [1, 2, 3, 4, 5, 6, 7])
        #expect(findings.map(\.value) == [
            "00008103-001C3D5A2E90801E",
            "5E2B9C41-7A03-4F6D-9E18-C2D47B8A0F35",
            "fqhzvnrkeymtplacsdubjgoiwxle",
            "k2/r8vq1m0zt5c9wpl3hx7ydn4b0000gn",
            "3C9A17E2-55B0-4D8F-A1C6-0E7B92F4D318",
            "00008112-001A2B3C4D5E6F70",
            "9B41E7D2-0C58-4A3F-8E16-5D2F70C9A4B1",
        ])
        #expect(Self.machineIdentifiers(in: placeholders).isEmpty)
    }

    /// Every exempt file is read by the checks that stand in place of the exemption.
    ///
    /// The claims above are about the captures. This is the claim that the captures are what they were run over — so a capture added to the exempt directory tomorrow cannot arrive checked by nothing at all.
    @Test
    func everyCaptureIsReadByTheEnvironmentCheck() throws {
        let captures = try Self.captures()

        let thereAreSome = !captures.isEmpty
        #expect(thereAreSome, "no capture was found under \(Self.capturesDirectory) — the environment check read nothing")
        for path in captures {
            let readable = (try? Self.text(of: path)) != nil
            #expect(readable, "\(path) is exempt from the name check and could not be read for the environment check")
        }
    }

    /// The home directory each `/Users/<name>` in the text names, with its line.
    private static func homeDirectories(in text: String) -> [(line: Int, home: String)] {
        var found: [(line: Int, home: String)] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var rest = line
            while let marker = rest.range(of: "/Users/") {
                let after = rest[marker.upperBound...]
                let name = after.prefix { $0 != "/" && $0 != ":" && $0 != "\\" && !$0.isWhitespace }
                found.append((line: offset + 1, home: "/Users/" + name))
                rest = after
            }
        }

        return found
    }

    /// The entries of every exported `PATH` in the text, with the line each came from.
    ///
    /// `xcodebuild` writes its environment dump with the `=` escaped, so both spellings are read. `PATH_PREFIXES_EXCLUDED_FROM_HEADER_DEPENDENCIES` is a different variable and neither spelling reaches it.
    private static func exportedPathEntries(in text: String) -> [(line: Int, entry: String)] {
        var found: [(line: Int, entry: String)] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let value: String
            if trimmed.hasPrefix("export PATH\\=") {
                value = String(trimmed.dropFirst("export PATH\\=".count))
            } else if trimmed.hasPrefix("export PATH=") {
                value = String(trimmed.dropFirst("export PATH=".count))
            } else {
                continue
            }
            for entry in value.split(separator: ":") where !entry.isEmpty {
                found.append((line: offset + 1, entry: String(entry)))
            }
        }

        return found
    }
}

extension ExampleNamesTests {
    /// The machine identifiers a capture can carry, each with the one value it may take there.
    ///
    /// Each shape is anchored on the context that makes it an identifier — `id:` on a destination line, `id=` in a `-destination`, a simulator's device directory, the DerivedData directory, `/var/folders/` — so a hex run anywhere else in a build log is not read as one. A destination's identifier comes in two shapes whichever way it is spelled: 8 and 16 hex digits for Apple silicon hardware, and a UUID for a simulator or an Intel Mac. `xcodebuild` prints the colon form for every available destination and takes the equals form in `-destination`, so each shape is read after both.
    private static var machineIdentifierShapes: [MachineIdentifierShape] {
        [
            MachineIdentifierShape(
                kind: "a hardware identifier",
                markers: ["id:", "id="],
                pattern: #/id[:=]([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})\b/#,
                placeholder: "00000000-0000000000000000"
            ),
            MachineIdentifierShape(
                kind: "a destination UUID",
                markers: ["id:", "id="],
                pattern: #/id[:=]([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\b/#,
                placeholder: "00000000-0000-0000-0000-000000000000"
            ),
            MachineIdentifierShape(
                kind: "a simulator device directory",
                markers: ["CoreSimulator/Devices/"],
                pattern: #/CoreSimulator\/Devices\/([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\b/#,
                placeholder: "00000000-0000-0000-0000-000000000000"
            ),
            MachineIdentifierShape(
                kind: "a DerivedData hash",
                markers: ["DerivedData/"],
                pattern: #/DerivedData\/[^\/\s]+-([a-z]{28})(?=[\/\s]|$)/#,
                placeholder: String(repeating: "x", count: 28)
            ),
            MachineIdentifierShape(
                kind: "a per-user temporary directory",
                markers: ["/var/folders/"],
                pattern: #/\/var\/folders\/([^\/\s]+\/[^\/\s]+)/#,
                placeholder: "00/0000000000000000000000000000gn"
            ),
        ]
    }

    /// Every machine identifier in the text that is not its placeholder, with its line.
    private static func machineIdentifiers(in text: String) -> [MachineIdentifierSite] {
        let shapes = machineIdentifierShapes
        var found: [MachineIdentifierSite] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            for shape in shapes where shape.markers.contains(where: { line.contains($0) }) {
                for match in line.matches(of: shape.pattern) where match.output.1 != shape.placeholder {
                    found.append(MachineIdentifierSite(line: offset + 1, kind: shape.kind, value: String(match.output.1)))
                }
            }
        }

        return found
    }

    /// One kind of machine identifier, and the placeholder that is the only value a capture may give it.
    struct MachineIdentifierShape {
        /// What the identifier is, as a finding names it.
        let kind: String
        /// Text a line has to contain one of before the identifier can be on it, so most lines never reach the pattern.
        let markers: [String]
        /// The identifier in the context that makes it one; the capture is its value.
        let pattern: Regex<(Substring, Substring)>
        let placeholder: String
    }

    /// A machine identifier read off a capture, with the line it was read on.
    struct MachineIdentifierSite {
        let line: Int
        let kind: String
        let value: String
    }

    /// What the tree says and what it declares, read in one pass because both claims below need both halves.
    struct Survey {
        var declared: Set<String> = []
        /// Every compound identifier any Swift file's code half mentions, which the compiler governs whether this repository declares it or a framework does.
        var referenced: Set<String> = []
        var sightings: [(path: String, sighting: ExampleNameScanner.Sighting)] = []
        /// The names a Swift file's comments say, kept apart because a comment naming a type some code mentions is a reference to it, which a string literal naming it is not.
        var commentSightings: [(path: String, sighting: ExampleNameScanner.Sighting)] = []

        /// Takes in what one Swift file's halves say: the names its code declares and mentions, and the names its comments say.
        mutating func absorb(_ split: ExampleNameScanner.Split, from path: String) {
            declared.formUnion(ExampleNameScanner.declaredNames(inCode: split.code))
            referenced.formUnion(ExampleNameScanner.referencedNames(inCode: split.code))
            commentSightings += ExampleNameScanner.sightings(in: split.comment).map { (path: path, sighting: $0) }
        }

        /// Every sighting but a comment's naming a type some code mentions, which refers to the type rather than inventing a name.
        var sightingsOwingAPermit: [(path: String, sighting: ExampleNameScanner.Sighting)] {
            sightings + commentSightings.filter { !referenced.contains($0.sighting.name) }
        }

        /// The names said in an example position, by something other than the list itself, that this repository's own code does not already account for.
        ///
        /// **The list is not evidence of its own names, and without that exclusion the staleness check could never fail.** Every line on it is a compound identifier standing in a file the gate reads, so a name pasted onto it would thereby be said by it, and ``everyNameOnTheListIsOneTheTreeStillUses`` would read its own subject as its own justification. `private-terms.txt` carries exactly this exemption for exactly this reason. The permit check still reads the list like every other file, which is what governs the names its *header* uses.
        var unaccountedFor: Set<String> {
            Set((sightings + commentSightings.filter { !referenced.contains($0.sighting.name) }).filter { $0.path != listPath }.map(\.sighting.name)).subtracting(declared)
        }
    }

    /// The compound identifiers a Swift source's example half sights, for a fixture too small to be worth a variable of its own at each call site.
    private static func exampleNames(of source: [UInt8]) -> Set<String> {
        Set(ExampleNameScanner.sightings(in: ExampleNameScanner.split(swift: source).example).map(\.name))
    }

    /// A backtick with no closing partner on the same line opens no span at all — it must not reach across a newline to a backtick that belongs to something else, and blank a name it was never near.
    @Test
    static func anUnpairedBacktickDoesNotExemptANameOnALaterLine() {
        let source = Array("/// A stray ` mark opens here, with a ( for company,\n/// but TanagerWidget: plain prose that should still be read.\n/// the next backtick ` lands down here, unrelated.\nstruct Sample {}".utf8)

        #expect(exampleNames(of: source).contains("TanagerWidget"))
    }

    /// A fenced code block's three backticks pair 1-2 within themselves, leaving the third to pair with whatever backtick comes next — an unrelated one, when the fence is never closed.
    ///
    /// That leftover pairing must not reach past prose and blank a name it was never near.
    @Test
    static func aFencedBlockDoesNotExemptANameBetweenTwoFences() {
        let source = Array("/// ```\n/// first(x: 1)\n/// TanagerKit: prose that follows the unterminated fence.\n/// end`\nstruct Sample {}".utf8)

        #expect(exampleNames(of: source).contains("TanagerKit"))
    }

    // MARK: - What the reader does not mistake for an invented name

    /// A JSON escape sequence is not the head of a word, and a name written out beside one is still refused.
    ///
    /// The escape is assembled from pieces for the reason ``anEscapeAndTheByteItEscapesAreBothBlanked`` gives, and the names are built at run time for the reason ``aNameTheListDoesNotCarryIsNamedWithItsLine`` gives.
    @Test
    func aJSONEscapeIsNotReadAsAWordAndAnInventedNameBesideItStillIs() throws {
        let unknown = "Qzx" + "Json" + "Sighting"
        let escape = #"\"#
        let json = "{\"text\": \"first" + escape + "n" + unknown + escape + "tsecond" + escape + "u00" + "E9\"}\n"
        let root = try TestSources.makeTempRepo()
        try TestSources.write(json, to: "Tests/Fixtures/sample.json", in: root)
        try TestSources.write(json, to: "Tests/Fixtures/sample.jsonl", in: root)

        let found = try Self.findings(against: [], in: root)

        #expect(Set(found.keys) == [unknown])
        #expect(found[unknown]?.path == "Tests/Fixtures/sample.json")
    }

    /// A type a file's code mentions is not an invented example when a comment names it, and a name beside it that no code mentions still is.
    @Test
    func aTypeNamedInCodeIsNotInventedWhenACommentNamesItToo() throws {
        let framework = "Qzx" + "Framework" + "Type"
        let unknown = "Qzx" + "Invented" + "Sighting"
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "/// Reads a \(framework), not a \(unknown).\nfunc read(_ value: \(framework)) {}\n",
            to: "Sources/Reader.swift",
            in: root
        )

        let found = try Self.findings(against: [], in: root)

        #expect(Set(found.keys) == [unknown])
    }

    /// Being mentioned in code grants a name nothing in a string literal: a fixture's text is example content however the code around it reads, including code that mentions the very same name.
    @Test
    func aNameInAStringLiteralStillCostsAPermit() throws {
        let unknown = "Qzx" + "Quoted" + "Sighting"
        let root = try TestSources.makeTempRepo()
        try TestSources.write("let sample = \"says \(unknown)\"\nlet made = \(unknown).make()\n", to: "Sources/Quoted.swift", in: root)

        let found = try Self.findings(against: [], in: root)

        #expect(Set(found.keys) == [unknown])
    }

    /// The refusal lists every name it found, so a tree with seventy is repaired from one failing run.
    @Test
    func theRefusalListsEveryName() {
        let findings = Dictionary(uniqueKeysWithValues: (1 ... 70).map { ("Qzx" + "Name\($0)", (path: "Tests/Widget.txt", line: $0)) })
        let refusal = Self.refusal(findings)

        #expect(findings.keys.allSatisfy { refusal.contains("  \($0)\n") })
    }
}
