//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A whole read of a file the context has already had digested is let through, because the refusal would offer the digest it holds.
///
/// Everything else about a whole read is refused as it always was: a file never digested, one digested in another session, one digested by another context in this session, one whose digest failed, a file of the same name digested in another repository, and one whose digest call was answered with something other than its digest. Each of those refusals offers the context something it does not have.
@Suite(.temporaryDirectories)
struct DigestedFilesTests {
    private static var session: String {
        "session-1"
    }

    /// The repository the reads are in — a directory holding a `.git`, which is all that makes one to the check.
    ///
    /// Shared by every test in the suite for the life of the process, so it is filed with the process rather than with any one test.
    private static let root: String = {
        guard let directory = try? TemporaryDirectory.makeForProcess("digested-repo") else { return "" }
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        return directory.path
    }()

    private static var path: String {
        file("SummaryState")
    }

    private static func file(_ name: String) -> String {
        root + "/Sources/App/\(name).swift"
    }

    /// A usage line for one `digest` call, written the way the server writes it.
    ///
    /// `measured` is a type or file digest, which weighs itself against the source it stands in for and records both sides; every other answer to a digest call — a member's source, a candidate list, a miss — records only what it served. A failed call records neither.
    private static func digest(
        _ target: String,
        session: String = session,
        agent: String? = nil,
        answered: Bool = true,
        measured: Bool = true,
        root: String = root
    ) -> [String: Any] {
        var entry: [String: Any] = ["tool": "digest", "target": target, "root": root, "ms": 3, "ok": answered, "session": session]
        if let agent {
            entry["agent"] = agent
        }
        if answered {
            entry["outBytes"] = 900
            if measured {
                entry["srcBytes"] = 12000
            }
        }
        return entry
    }

    /// A `where` answer resolving `SummaryState` to its declaration, and listing `CatalogueStore.swift` only among the sites it matched by name.
    private static var whereAnswer: String {
        """
        tree: App  head: 0000000  dirty: 0  parse_errors: 0  semantic: syntactic-only
        where SummaryState
        declarations (1):
          App.SummaryState — struct — struct SummaryState — Sources/App/SummaryState.swift:3-40

        syntactic call sites — matched on written name over the working tree: never stale, but a name is not a symbol.

        "SummaryState" (1 call sites in 1 files — for App.SummaryState):
          Sources/App/CatalogueStore.swift:12  in CatalogueStore.load()
        """
    }

    /// A `search` answer listing one match in `SummaryState.swift`.
    private static var searchAnswer: String {
        """
        tree: App  source: working tree, read live — nothing stored to go stale
        search kind:struct name:SummaryState
        1 declaration(s) in 1 file(s) — scanned 3 file(s)
        syntactic shape match over the working tree — never stale, never refuses.

        Sources/App/SummaryState.swift:
          :3-40  SummaryState — struct SummaryState
        """
    }

    /// A usage line for one answered `where` or `search` call, recording the files `text` located the way the server records them.
    private static func answered(_ tool: String, text: String, session: String = session, root: String = root) -> [String: Any] {
        [
            "tool": tool, "target": "SummaryState", "root": root, "ms": 3, "ok": true, "session": session, "outBytes": 400,
            "located": DigestedFiles.locatedFiles(inAnswer: text, tool: tool),
        ]
    }

    private static func read(_ path: String = path, session: String = session, agent: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["tool_name": "Read", "tool_input": ["file_path": path], "session_id": session]
        if let agent {
            payload["agent_id"] = agent
        }
        return payload
    }

    private static func lookup(
        _ payload: [String: Any],
        log: UsageLogFile,
        noting recording: AdviceAgreementTests.Recording
    ) -> PreToolUseCommand.Lookup? {
        // The fixture is a repository nobody has indexed, which draws no nudge of its own; what this suite
        // pins is the digest the context holds, so that judgement is stated rather than read off the fixture —
        // including, here, what the index would have resolved a bare name to: every type in this fixture is
        // imagined to live in `Sources/App/<name>.swift`, one file per name, which is what `resolve` states.
        PreToolUseCommand.lookup(
            command: nil,
            payload: payload,
            noting: recording.log,
            digested: log.digested,
            couldAnswer: { _, _ in true },
            resolvingDigests: resolve
        )
    }

    /// What this suite states the index would resolve a bare name to: `Sources/App/<baseName>.swift`, the one file per type name every fixture in it assumes.
    private static func resolve(_ target: String, atRoot root: String) -> String? {
        guard root == Self.root else { return nil }
        guard let baseName = target.split(separator: ".").last.map(String.init) else { return nil }
        return "Sources/App/\(baseName).swift"
    }

    /// The case the rule exists for: digested, then read whole, and the read goes through unrefused — with the withholding logged like every other.
    @Test
    func aWholeReadOfAFileThisContextDigestedIsNotRefused() throws {
        let log = try UsageLogFile([Self.digest("SummaryState")])
        let recording = try AdviceAgreementTests.Recording()
        defer {
            log.cleanup()
            recording.cleanup()
        }

        #expect(Self.lookup(Self.read(), log: log, noting: recording) == nil)
        #expect(recording.rules == ["alreadyDigested"])
    }

    /// A window of a file this context digested — a ranged `Read`, or a shell window — is the loop working: no lookup, and nothing noted, where a whole read of it is logged `alreadyDigested`; the same window of a file it never digested is the lookup, offered the file's digest.
    @Test(arguments: [true, false])
    func aWindowOfAFileThisContextDigestedIsNoLookup(ranged: Bool) throws {
        let payload: [String: Any] = ranged
            ? ["tool_name": "Read", "tool_input": ["file_path": Self.path, "offset": 10, "limit": 20], "session_id": Self.session]
            : ["tool_name": "Bash", "tool_input": ["command": "sed -n '10,30p' \(Self.path)"], "session_id": Self.session]
        let digested = try UsageLogFile([Self.digest("SummaryState")])
        let cold = try UsageLogFile([Self.digest("CatalogueStore")])
        let recording = try AdviceAgreementTests.Recording()
        defer {
            digested.cleanup()
            cold.cleanup()
            recording.cleanup()
        }

        #expect(Self.lookup(payload, log: digested, noting: recording) == nil)
        #expect(recording.rules.isEmpty)
        #expect(Self.lookup(payload, log: cold, noting: recording)?.suggestion.call == "digest SummaryState")
    }

    /// A file this context never digested is refused with the digest, as before.
    @Test
    func aWholeReadOfAFileNeverDigestedIsStillRefused() throws {
        let log = try UsageLogFile([Self.digest("CatalogueStore")])
        let recording = try AdviceAgreementTests.Recording()
        defer {
            log.cleanup()
            recording.cleanup()
        }

        #expect(Self.lookup(Self.read(), log: log, noting: recording)?.suggestion.call == "digest SummaryState")
        #expect(recording.rules.isEmpty)
    }

    /// A digest another session had never reached this context, so the refusal is news to it.
    @Test
    func aDigestInAnotherSessionDoesNotExcuseTheRead() throws {
        let log = try UsageLogFile([Self.digest("SummaryState", session: "session-2")])
        let recording = try AdviceAgreementTests.Recording()
        defer {
            log.cleanup()
            recording.cleanup()
        }

        #expect(Self.lookup(Self.read(), log: log, noting: recording)?.suggestion.call == "digest SummaryState")
    }

    /// Nor does one made by another context in the same session: a subagent's window never held its parent's digest, nor a parent its subagent's.
    @Test
    func aDigestByAnotherContextInTheSessionDoesNotExcuseTheRead() throws {
        let log = try UsageLogFile([Self.digest("SummaryState"), Self.digest("CatalogueStore", agent: "a1")])
        let recording = try AdviceAgreementTests.Recording()
        defer {
            log.cleanup()
            recording.cleanup()
        }

        #expect(Self.lookup(Self.read(agent: "a1"), log: log, noting: recording) != nil)
        #expect(Self.lookup(Self.read(Self.file("CatalogueStore")), log: log, noting: recording) != nil)
        #expect(Self.lookup(Self.read(Self.file("CatalogueStore"), agent: "a1"), log: log, noting: recording) == nil)
        #expect(Self.lookup(Self.read(agent: "a2"), log: log, noting: recording) != nil)
    }

    /// A digest that failed answered nothing, so there is nothing the context holds.
    @Test
    func aFailedDigestDoesNotExcuseTheRead() throws {
        let log = try UsageLogFile([Self.digest("SummaryState", answered: false)])
        let recording = try AdviceAgreementTests.Recording()
        defer {
            log.cleanup()
            recording.cleanup()
        }

        #expect(Self.lookup(Self.read(), log: log, noting: recording) != nil)
    }

    /// A file's name is not its identity: a digest answered from another repository is of that repository's file, and the refusal offers this one's.
    ///
    /// The same repository under another spelling of its path is still the same one.
    @Test
    func aDigestInAnotherRepositoryDoesNotExcuseTheRead() throws {
        let sibling = try UsageLogFile([Self.digest("SummaryState", root: Self.root + "-sibling")])
        let respelled = try UsageLogFile([Self.digest("SummaryState", root: CanonicalPath.of(Self.root) + "/")])
        let recording = try AdviceAgreementTests.Recording()
        defer {
            sibling.cleanup()
            respelled.cleanup()
            recording.cleanup()
        }

        #expect(Self.lookup(Self.read(), log: sibling, noting: recording)?.suggestion.call == "digest SummaryState")
        #expect(Self.lookup(Self.read(), log: respelled, noting: recording) == nil)
    }

    /// The digest a refusal would offer is the one that counts: the type the file is named for, however qualified, or the file itself, by any path the renderer resolves to it.
    @Test
    func theFilesOwnDigestIsMatchedToIt() throws {
        let targets = ["SummaryState", "App.SummaryState", "Sources/App/SummaryState.swift", "App/SummaryState.swift", "SummaryState.swift", Self.path]
        for target in targets {
            let log = try UsageLogFile([Self.digest(target)])
            defer { log.cleanup() }

            #expect(log.digested.contains(Self.path, session: Self.session, agent: nil, resolve: Self.resolve), "\(target)")
        }
        let log = try UsageLogFile([
            Self.digest("Summary.State"),
            Self.digest("Sources/App/Summary.swift"),
            Self.digest("Sources/Other/SummaryState.swift"),
        ])
        defer { log.cleanup() }

        #expect(!log.digested.contains(Self.path, session: Self.session, agent: nil))
    }

    /// A digest call answered with anything but the file's digest leaves the context without what the refusal offers, so it excuses nothing: one member's source, one type nested in the file, the candidates for a file name several files share, and a miss on the type's name.
    @Test
    func anAnswerThatIsNotTheFilesDigestDoesNotExcuseTheRead() throws {
        let answers = [
            Self.digest("SummaryState.refresh", measured: false),
            Self.digest("SummaryState.Inner"),
            Self.digest("SummaryState.swift", measured: false),
            Self.digest("SummaryState", measured: false),
        ]
        for answer in answers {
            let log = try UsageLogFile([answer])
            let recording = try AdviceAgreementTests.Recording()
            defer {
                log.cleanup()
                recording.cleanup()
            }

            #expect(
                Self.lookup(Self.read(), log: log, noting: recording)?.suggestion.call == "digest SummaryState",
                "\(answer["target"] as? String ?? "")"
            )
        }
    }

    /// No log, an empty session, or a line cut short mid-write reads as nothing digested — the read is refused as it would have been.
    @Test
    func whatCannotBeReadExcusesNothing() throws {
        let missing = try DigestedFiles(usageLog: TemporaryDirectory.make("absent").appendingPathComponent("absent.jsonl"))
        #expect(!missing.contains(Self.path, session: Self.session, agent: nil))

        let log = try UsageLogFile([Self.digest("SummaryState")])
        defer { log.cleanup() }
        #expect(!log.digested.contains(Self.path, session: "", agent: nil))

        let handle = try FileHandle(forWritingTo: log.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"ok":true,"session":"session-1","target":"CatalogueStore","tool":"digest","ro"#.utf8))
        try handle.close()
        #expect(!log.digested.contains(Self.file("CatalogueStore"), session: Self.session, agent: nil))
        #expect(log.digested.contains(Self.path, session: Self.session, agent: nil, resolve: Self.resolve))
    }

    /// The log is never rotated, so only its end is read: a digest in the tail of a log well past the bound is found, and one written before the tail is not — which refuses the read, the side a miss is allowed to fall on.
    @Test
    func onlyTheTailOfALongLogIsRead() throws {
        let log = try UsageLogFile(
            [Self.digest("CatalogueStore")],
            paddedPast: DigestedFiles.tailBytes + 4096,
            with: Self.digest("SummaryState", session: "session-2"),
            then: [Self.digest("SummaryState")]
        )
        defer { log.cleanup() }

        #expect(log.digested.contains(Self.path, session: Self.session, agent: nil, resolve: Self.resolve))
        #expect(!log.digested.contains(Self.file("CatalogueStore"), session: Self.session, agent: nil))
    }

    /// A window of a file a `where` answer of this context located is the loop working, as it is after a digest: no lookup, nothing noted.
    ///
    /// A file the answer lists only among its name-matched call sites is not located, and is still answered with its digest, as is a file the answer never named — and a whole read of the located file is still refused, since a location is not the file's digest.
    @Test(arguments: [true, false])
    func aWindowOfAFileAWhereAnswerLocatedIsNoLookup(ranged: Bool) throws {
        func window(_ name: String) -> [String: Any] {
            ranged
                ? ["tool_name": "Read", "tool_input": ["file_path": Self.file(name), "offset": 10, "limit": 20], "session_id": Self.session]
                : ["tool_name": "Bash", "tool_input": ["command": "sed -n '10,30p' \(Self.file(name))"], "session_id": Self.session]
        }
        let log = try UsageLogFile([Self.answered("where", text: Self.whereAnswer)])
        let recording = try AdviceAgreementTests.Recording()
        defer {
            log.cleanup()
            recording.cleanup()
        }

        #expect(Self.lookup(window("SummaryState"), log: log, noting: recording) == nil)
        #expect(recording.rules.isEmpty)
        #expect(Self.lookup(window("CatalogueStore"), log: log, noting: recording)?.suggestion.call == "digest CatalogueStore")
        #expect(Self.lookup(window("DepotStore"), log: log, noting: recording)?.suggestion.call == "digest DepotStore")
        #expect(Self.lookup(Self.read(), log: log, noting: recording)?.suggestion.call == "digest SummaryState")
    }

    /// A `search` answer locates the files it lists matches in, and neither answer locates anything from another repository, in another session, or where the line predates the field that records what it located.
    @Test
    func aSearchAnswerLocatesItsFilesAndNothingElseDoes() throws {
        let window: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "sed -n '10,30p' \(Self.path)"], "session_id": Self.session]
        let searched = try UsageLogFile([Self.answered("search", text: Self.searchAnswer)])
        var bare = Self.answered("where", text: Self.whereAnswer)
        bare["located"] = nil
        let elsewhere = try UsageLogFile([
            Self.answered("where", text: Self.whereAnswer, root: Self.root + "-sibling"),
            Self.answered("where", text: Self.whereAnswer, session: "session-2"),
            bare,
        ])
        let recording = try AdviceAgreementTests.Recording()
        defer {
            searched.cleanup()
            elsewhere.cleanup()
            recording.cleanup()
        }

        #expect(DigestedFiles.locatedFiles(inAnswer: Self.searchAnswer, tool: "search") == ["Sources/App/SummaryState.swift"])
        #expect(Self.lookup(window, log: searched, noting: recording) == nil)
        #expect(Self.lookup(window, log: elsewhere, noting: recording)?.suggestion.call == "digest SummaryState")
    }

    /// A shell window no answered shape covers — a subshell, an environment assignment, output sent to `/dev/null` — is no lookup once this context digested the file, as the plain window is.
    @Test(arguments: ["(sed -n '10,30p' %@)", "LC_ALL=C sed -n '10,30p' %@", "sed -n '10,30p' %@ > /dev/null"])
    func aWindowOfAFileThisContextDigestedIsNoLookupInAnyShellShape(shape: String) throws {
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": String(format: shape, Self.path)], "session_id": Self.session]
        let digested = try UsageLogFile([Self.digest("SummaryState")])
        let cold = try UsageLogFile([Self.digest("CatalogueStore")])
        let recording = try AdviceAgreementTests.Recording()
        defer {
            digested.cleanup()
            cold.cleanup()
            recording.cleanup()
        }

        #expect(Self.lookup(payload, log: digested, noting: recording) == nil)
        #expect(recording.rules.isEmpty)
        #expect(Self.lookup(payload, log: cold, noting: recording)?.suggestion.call == "digest SummaryState")
    }

    /// A digest locates the one file its target resolves to, and no same-named file elsewhere: a path is the file at that exact path where one is there — the renderer's own first choice — so a digest of the root's `Shell.swift`, or of `Sources/App/Shell.swift`, leaves a deeper file ending in the same components unlocated, as an absolute path and a type name do; in the usage log and in the ledger alike.
    @Test(arguments: [
        ("Shell.swift", "Shell.swift", "Sources/App/Shell.swift"),
        ("Sources/App/Shell.swift", "Sources/App/Shell.swift", "Other/Sources/App/Shell.swift"),
        ("/Sources/App/Shell.swift", "Sources/App/Shell.swift", "Other/Sources/App/Shell.swift"),
        ("Shell", "Sources/App/Shell.swift", "Shell.swift"),
    ])
    func aDigestLocatesOnlyTheFileItsTargetResolvesTo(written: String, resolved: String, sameNamed: String) throws {
        for file in ["Shell.swift", "Sources/App/Shell.swift", "Other/Sources/App/Shell.swift"] {
            let url = URL(fileURLWithPath: Self.root + "/" + file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "struct Widget {}\n".write(to: url, atomically: true, encoding: .utf8)
        }
        // An absolute target is spelled here from the root the fixture only knows at run time.
        let target = written.hasPrefix("/") ? Self.root + written : written
        let log = try UsageLogFile([Self.digest(target)])
        defer { log.cleanup() }
        let ledger = [Self.root: Set([target])]

        for (file, located) in [(resolved, true), (sameNamed, false)] {
            let path = Self.root + "/" + file
            #expect(log.digested.locates(path, session: Self.session, agent: nil, resolve: Self.resolve) == located, "\(target) → \(file)")
            #expect(log.digested.contains(path, session: Self.session, agent: nil, resolve: Self.resolve) == located, "\(target) → \(file)")
            #expect(DigestedFiles.isLocated(path, among: ledger, resolve: Self.resolve) == located, "\(target) → \(file)")
            #expect(DigestedFiles.isDigested(path, among: ledger, resolve: Self.resolve) == located, "\(target) → \(file)")
        }
    }

    /// The renderer shows no file at all where several indexed files end in the target — "ambiguous" — so a suffix match must not credit either candidate: both stay cold, in the usage log and in the ledger alike.
    @Test
    func anAmbiguousSuffixLocatesNeitherCandidate() throws {
        let target = "Nested/Widget.swift"
        for file in ["Sources/Alpha/Nested/Widget.swift", "Sources/Beta/Nested/Widget.swift"] {
            let url = URL(fileURLWithPath: Self.root + "/" + file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "struct Widget {}\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let log = try UsageLogFile([Self.digest(target)])
        defer { log.cleanup() }
        let ledger = [Self.root: Set([target])]

        for file in ["Sources/Alpha/Nested/Widget.swift", "Sources/Beta/Nested/Widget.swift"] {
            let path = Self.root + "/" + file
            #expect(!log.digested.locates(path, session: Self.session, agent: nil, resolve: Self.resolve), "\(file) stayed cold")
            #expect(!log.digested.contains(path, session: Self.session, agent: nil, resolve: Self.resolve), "\(file) stayed cold")
            #expect(!DigestedFiles.isLocated(path, among: ledger, resolve: Self.resolve), "\(file) stayed cold")
            #expect(!DigestedFiles.isDigested(path, among: ledger, resolve: Self.resolve), "\(file) stayed cold")
        }
    }

    /// A repository of its own holding `files`, each declaring `Widget`, for a test that must not share the suite's tree.
    private static func repository(holding files: [String]) throws -> URL {
        let repository = try TemporaryDirectory.make("digested-twins")
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        for file in files {
            let url = repository.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "struct Widget {}\n".write(to: url, atomically: true, encoding: .utf8)
        }
        return repository
    }

    /// The index holds the Swift files inside a package directory — a `.playground`, a `.swiftpm` app — so a same-named file in one makes a suffix target ambiguous to the renderer, and neither file is credited.
    @Test(arguments: ["Book.playground/Sources", "Book.swiftpm/Sources"])
    func aTwinInsideAPackageDirectoryKeepsASuffixTargetAmbiguous(package: String) throws {
        let files = ["App/Widget.swift", "\(package)/App/Widget.swift"]
        let repository = try Self.repository(holding: files)
        let log = try UsageLogFile([Self.digest("Widget.swift", root: repository.path)])
        defer { log.cleanup() }

        for file in files {
            let path = repository.path + "/" + file
            #expect(!log.digested.locates(path, session: Self.session, agent: nil, resolve: Self.resolve), "\(file) stayed cold")
            #expect(!log.digested.contains(path, session: Self.session, agent: nil, resolve: Self.resolve), "\(file) stayed cold")
        }
    }

    /// Six answered lines for one suffix target, asked about for two files, walk the tree once within one hook call, and lines answered from another repository walk it not at all: a walk per line once cost a hook call its time budget.
    @Test
    func aSuffixTargetIsWalkedOncePerHookCall() throws {
        let files = ["App/Widget.swift", "Other/Widget.swift"]
        let repository = try Self.repository(holding: files)
        let here = try UsageLogFile(Array(repeating: Self.digest("Widget.swift", root: repository.path), count: 6))
        let elsewhere = try UsageLogFile(Array(repeating: Self.digest("Widget.swift", root: repository.path + "-sibling"), count: 6))
        defer {
            here.cleanup()
            elsewhere.cleanup()
        }
        let digested = here.digested
        let sibling = elsewhere.digested
        let located = files.map { file in
            let path = repository.path + "/" + file
            return digested.locates(path, session: Self.session, agent: nil, resolve: Self.resolve)
                || sibling.locates(path, session: Self.session, agent: nil, resolve: Self.resolve)
        }

        #expect(located == [false, false])
        #expect(digested.suffixWalks.walksMade == 1)
        #expect(sibling.suffixWalks.walksMade == 0)
    }

    /// Every entry the suffix walk visits counts toward its bound, not only the Swift files: a tree of build output past the bound credits nothing rather than walking on.
    @Test
    func theSuffixWalkCountsEveryEntryTowardItsBound() throws {
        let repository = try Self.repository(holding: ["App/Widget.swift"])
        let build = repository.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        for index in 0 ..< 8 {
            try "".write(to: build.appendingPathComponent("\(index).o"), atomically: true, encoding: .utf8)
        }
        let file = repository.appendingPathComponent("App/Widget.swift")
        func locates(bound: Int) -> Bool {
            DigestedFiles.FileNaming(file: file, repository: repository.path, walks: SameSuffixFiles(entryLimit: bound))
                .locates(by: "Widget.swift", resolvedBy: { _, _ in nil })
        }

        #expect(locates(bound: 100))
        #expect(!locates(bound: 5))
    }
}

extension DigestedFilesTests {
    /// A member's digest, which records no source weight, locates the file its type resolves to for a window and never stands for its whole digest; a same-named file elsewhere, and a member of an unresolved type, locate nothing.
    @Test
    func aMemberDigestLocatesTheFileDeclaringItsType() throws {
        let log = try UsageLogFile([Self.digest("SummaryState.save(_:to:)", measured: false), Self.digest("Missing.go", measured: false)])
        defer { log.cleanup() }
        let ledger = [Self.root: Set(["SummaryState.save(_:to:)"])]
        let resolve: (String, String) -> String? = { target, root in target == "Missing" ? nil : Self.resolve(target, atRoot: root) }

        #expect(log.digested.locates(Self.path, session: Self.session, agent: nil, resolve: resolve))
        #expect(DigestedFiles.isLocated(Self.path, among: ledger, resolve: resolve))
        #expect(!log.digested.contains(Self.path, session: Self.session, agent: nil, resolve: resolve))
        #expect(!DigestedFiles.isDigested(Self.path, among: ledger, resolve: resolve))
        #expect(!log.digested.locates(Self.root + "/Other/SummaryState.swift", session: Self.session, agent: nil, resolve: resolve))
        #expect(!log.digested.locates(Self.file("Missing"), session: Self.session, agent: nil, resolve: resolve))
    }

    /// A module digest's answer records the files it lists under their headings, and a window of one of them is located by that line, as a `search` answer's is; a same-named file it did not list is not.
    @Test
    func aModuleDigestLocatesTheFilesItLists() throws {
        let listing = "module App — 1 top-level declaration\n\nSources/App/SummaryState.swift:\n  struct SummaryState  :2-5\n"
        var line = Self.answered("digest", text: listing)
        line["target"] = "App"
        let log = try UsageLogFile([line])
        defer { log.cleanup() }

        #expect(DigestedFiles.locatedFiles(inAnswer: listing, tool: "digest") == ["Sources/App/SummaryState.swift"])
        #expect(log.digested.locates(Self.path, session: Self.session, agent: nil, resolve: { _, _ in nil }))
        #expect(!log.digested.locates(Self.root + "/Other/SummaryState.swift", session: Self.session, agent: nil, resolve: { _, _ in nil }))
        #expect(!log.digested.contains(Self.path, session: Self.session, agent: nil, resolve: { _, _ in nil }))
    }

    /// A path digest the renderer answered with the one indexed file of that path's name records the file it served, and the hook lets a later window of that file run as located; a window of another file is still answered.
    @Test
    func aPathDigestServedAnotherFileLocatesTheFileItServed() throws {
        let asked = "Sources/Old/SummaryState.swift"
        let answer = """
        no indexed file at \(asked) — served Sources/App/SummaryState.swift, the one indexed file of that name
        Sources/App/SummaryState.swift — module: App
        struct SummaryState — 1 members  :2-5
        """
        var line = Self.digest(asked)
        line["located"] = DigestedFiles.locatedFiles(inAnswer: answer, tool: "digest")
        let log = try UsageLogFile([line])
        let recording = try AdviceAgreementTests.Recording()
        defer {
            log.cleanup()
            recording.cleanup()
        }
        func window(_ name: String) -> [String: Any] {
            ["tool_name": "Bash", "tool_input": ["command": "sed -n '10,30p' \(Self.file(name))"], "session_id": Self.session]
        }

        #expect(line["located"] as? [String] == ["Sources/App/SummaryState.swift"])
        #expect(Self.lookup(window("SummaryState"), log: log, noting: recording) == nil)
        #expect(recording.rules.isEmpty)
        #expect(Self.lookup(window("CatalogueStore"), log: log, noting: recording)?.suggestion.call == "digest CatalogueStore")
        // The answer handed over the served file's whole digest, so a whole read of it is the one already held.
        #expect(Self.lookup(Self.read(), log: log, noting: recording) == nil)
        #expect(recording.rules == ["alreadyDigested"])
    }

    /// A digest does not lapse when its file is written after it was served: the whole read is still let through as `alreadyDigested`, by either record, since a modification time cannot tell an edit from a rewrite of the same text.
    @Test
    func aDigestServedBeforeTheFileChangedStillExcusesTheWholeRead() throws {
        let repository = try Self.repository(holding: ["Sources/App/Widget.swift"])
        let file = repository.appendingPathComponent("Sources/App/Widget.swift")
        var line = Self.digest("Widget.swift", root: repository.path)
        let served = Date().addingTimeInterval(-3600)
        line["ts"] = ISO8601DateFormatter().string(from: served)
        let log = try UsageLogFile([line])
        let recording = try AdviceAgreementTests.Recording()
        defer {
            log.cleanup()
            recording.cleanup()
        }
        // Past the digest floor, so the read is one a digest would have stood in for rather than one let through on its size.
        let members = (1 ... 120).map { "    var edited\($0) = \($0)\n" }.joined()
        try "struct Widget {\n\(members)}\n".write(to: file, atomically: true, encoding: .utf8)
        let changed = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)

        #expect(changed > served)
        #expect(Self.lookup(Self.read(file.path), log: log, noting: recording) == nil)
        #expect(recording.rules == ["alreadyDigested"])
        #expect(DigestedFiles.isDigested(file.path, among: [repository.path: ["Widget.swift"]], resolve: Self.resolve))
    }
}

extension DigestedFilesTests {
    /// A usage log holding `entries`, one JSON line each, in a directory of its own.
    struct UsageLogFile {
        let url: URL

        init(_ entries: [[String: Any]]) throws {
            try self.init(entries, paddedPast: 0, with: [:], then: [])
        }

        /// `entries`, then copies of `padding` until the log is longer than `bytes`, then `tail`.
        init(_ entries: [[String: Any]], paddedPast bytes: Int, with padding: [String: Any], then tail: [[String: Any]]) throws {
            let directory = try TemporaryDirectory.make("digested")
            url = directory.appendingPathComponent("usage.jsonl")
            var data = Data()
            for entry in entries {
                try data.append(Self.line(entry))
            }
            if bytes > 0 {
                let line = try Self.line(padding)
                while data.count <= bytes {
                    data.append(line)
                }
            }
            for entry in tail {
                try data.append(Self.line(entry))
            }
            try data.write(to: url)
        }

        private static func line(_ entry: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(0x0A)
            return data
        }

        var digested: DigestedFiles {
            DigestedFiles(usageLog: url)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }
}
