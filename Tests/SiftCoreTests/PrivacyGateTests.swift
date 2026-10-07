//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the release-time gate itself — the check that decides whether a bundle may leave this machine.
///
/// ``ShippedDocumentsTests`` asserts that what ships names nothing private. This asserts that the thing making that judgement judges correctly, which is a separate claim: a gate is worth what its verdict is worth, and the two ways it can be worth nothing are opposite. One is clearing a leak. The other is failing content that is clean, which is the one that arrives quietly — the repair it argues for is an exception, and a gate with exceptions is a gate nobody trusts.
@Suite(.temporaryDirectories)
struct PrivacyGateTests {
    private static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent() // SiftCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // the repository root

    /// The check itself and the list it reads — what a fixture needs to run the gate over one file.
    private static let theCheck = ["Distribution/verify-private.sh", "Distribution/private-terms.txt"]

    /// The same, plus the two files that make it happen on every push: the tree-wide entry point and the hook that calls it.
    private static let theCheckAndItsCaller = theCheck + ["Distribution/verify-tree.sh", "githooks/pre-push"]

    /// A checkout for the gate to run in: the files it is given, and one neighbour beside it to discover.
    ///
    /// Built rather than borrowed. Pointing the gate at this machine's real parent directory would make the verdict depend on which projects happen to sit beside the checkout today, and on a clone with no neighbours at all the gate refuses to run — correctly, and the test would read that refusal as a failure of the property it was asking about.
    ///
    /// `named` is what the checkout directory is called, which matters only where the repository's shape is the subject: a bare repository is conventionally `<name>.git` and has no checkout to be named after at all.
    private static func checkout(
        in root: URL,
        named name: String = "Subject",
        neighbours: [String] = ["Neighbour"],
        carrying files: [String] = theCheck
    ) throws -> URL {
        let subject = root.appending(path: "Parent/\(name)")
        try FileManager.default.createDirectory(at: subject, withIntermediateDirectories: true)
        for neighbour in neighbours {
            try FileManager.default.createDirectory(at: root.appending(path: "Parent/\(neighbour)"), withIntermediateDirectories: true)
        }

        for file in files {
            let destination = subject.appending(path: file)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: repository.appending(path: file), to: destination)
        }

        return subject
    }

    /// The same checkout as a git repository with everything in it committed — which is what `verify-tree.sh` has a tree to read, and what a linked worktree can hang off.
    ///
    /// The identity it commits under is the fixture's own, set on the repository rather than taken from the machine: the gate reads `user.email` off the checkout it is run in and turns it into a needle, so a fixture that inherited the real address would be checking this machine's owner against files that could never name them.
    private static func gitCheckout(in root: URL, neighbours: [String] = ["Neighbour"], carrying files: [String] = theCheck) throws -> URL {
        let subject = try checkout(in: root, neighbours: neighbours, carrying: files)
        try TestSources.runGit(["init", "-b", "main"], in: subject)
        try TestSources.runGit(["config", "user.email", "tester@example.invalid"], in: subject)
        try TestSources.runGit(["config", "user.name", "Tester"], in: subject)
        try TestSources.commitAll(in: subject, message: "seed")

        return subject
    }

    /// Whether two spellings of a path reach one directory, which is what makes the misspelling possible at all.
    private static func sameDirectory(_ one: URL, _ other: URL) -> Bool {
        let identity = { (url: URL) in
            try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        }
        guard let one = identity(one), let other = identity(other) else { return false }

        return one == other
    }

    /// Runs the gate over one file and reports only whether it cleared it; its diagnostics are not this suite's subject.
    private static func gateClears(_ subject: URL, invokedAt checkout: URL, environment: [String: String]? = nil) throws -> Bool {
        try gateStatus(subject, invokedAt: checkout, environment: environment) == 0
    }

    /// The gate's exit code, for the one property that is about which nonzero it chose.
    private static func gateStatus(_ subject: URL, invokedAt checkout: URL, environment: [String: String]? = nil) throws -> Int32 {
        try gateRun([subject], invokedAt: checkout, environment: environment).status
    }

    /// The gate over several paths at once, keeping what it printed — for the properties that are about how far the walk got.
    private static func gateRun(_ subjects: [URL], invokedAt checkout: URL, environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
        try shell(
            checkout.appending(path: "Distribution/verify-private.sh"),
            arguments: subjects.map(\.path),
            environment: environment
        )
    }

    /// Runs a shell script and reports its exit code and everything it printed, both streams together.
    private static func shell(
        _ script: URL,
        arguments: [String] = [],
        in directory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [script.path] + arguments
        if let directory {
            process.currentDirectoryURL = directory
        }
        // Assigned only when the caller has one. `Process` treats an explicitly-set `nil` as an empty
        // environment rather than an inherited one, and the gate reads `$HOME` under `set -u`.
        if let environment {
            process.environment = environment
        }
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        // Read before waiting. A pipe holds 64 KB, and a gate that finds something prints three sample
        // lines per needle per file — so the runs this exists for are exactly the ones that fill it, and
        // waiting first would deadlock on the failure and never on the pass.
        let output = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // A gate's output quotes the lines it found, in whatever encoding their file was in. Latin-1 maps
        // every byte to a character, so where the output is not UTF-8 an assertion on the rest of it still
        // has text to read rather than an empty string.
        return (process.terminationStatus, String(data: output, encoding: .utf8) ?? String(data: output, encoding: .isoLatin1) ?? "")
    }

    /// An environment whose `PATH` leads to `root/bin` first, for the commands a fixture answers for itself.
    ///
    /// `$HOME` and the rest of it stay as they are: the gate reads the machine's identity off the environment, and a fixture that scrubbed it would be exercising a check with half its needles missing.
    private static func stubbing(_ command: String, with script: String, in root: URL) throws -> [String: String] {
        let binaries = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let stub = binaries.appending(path: command)
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        var environment = ProcessEnvironment.withoutGit()
        environment["PATH"] = "\(binaries.path):/usr/bin:/bin"
        // The hook reads this, and a suite run under it would otherwise test the caller's shell rather than
        // the hook: every branch below decides for itself whether the escape hatch is set.
        environment["SIFT_PRE_PUSH_RAW"] = nil

        return environment
    }

    /// The gate learns the private names from the directories beside the checkout, and skips the checkout itself.
    ///
    /// Skipping it by basename compares against a name `pwd` reports as the caller spelled it — so a shell that reached the repository through a differently-cased path discovers the checkout as a stranger, and the tool's own name becomes a private one. Every shipped file names the tool, so the whole release gate fails, on content that has not changed and was never private. Device and inode are the same pair however the path was spelled.
    @Test
    func theCheckoutIsNeverOneOfItsOwnNeighboursHoweverTheInvokingPathWasSpelled() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root)
        // The spelling the failure needs, and the one a case-insensitive filesystem serves alike. Where it
        // is case-sensitive these are two different directories and the situation cannot arise.
        let aliased = subject.deletingLastPathComponent().appending(path: subject.lastPathComponent.lowercased())
        guard Self.sameDirectory(subject, aliased) else { return }
        let document = root.appending(path: "names-the-checkout.txt")
        // Naming the checkout and nothing else. The sibling's name is matched as a substring, so prose
        // about neighbours in general would trip this gate on its own wording.
        try "\(subject.lastPathComponent) is the checkout itself.\n"
            .write(to: document, atomically: true, encoding: .utf8)

        #expect(try Self.gateClears(document, invokedAt: aliased))
    }

    /// A discovered name is a name, not a pattern — and it fails in both directions when matched as one.
    ///
    /// The needles are read off the filesystem, so whatever punctuation a project happens to be named with arrives unescaped. As a regular expression `Client.Web` also matches `ClientXWeb`, which fails the gate on content that is clean; a bracketed name like `App[2]` is the dangerous half, matching only `App2` so that the real name it exists to catch is never looked for at all.
    @Test
    func aNeighbourWhoseNameCarriesPunctuationIsMatchedLiterally() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["Client.Web"])
        let nearMiss = root.appending(path: "near-miss.txt")
        try "ClientXWeb is a different project entirely.\n".write(to: nearMiss, atomically: true, encoding: .utf8)
        let real = root.appending(path: "the-real-name.txt")
        try "Client.Web is the project next door.\n".write(to: real, atomically: true, encoding: .utf8)

        #expect(try Self.gateClears(nearMiss, invokedAt: subject), "the dot was read as a wildcard")
        #expect(try !Self.gateClears(real, invokedAt: subject), "the name itself went unmatched")
    }

    /// Every shell script under `Distribution/`.
    private static func distributionScripts() throws -> [URL] {
        let distribution = repository.appending(path: "Distribution")
        let files = FileManager.default.enumerator(at: distribution, includingPropertiesForKeys: nil)

        return (files?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "sh" }
    }

    /// A build that maps `$REPO` away has to be the build whose sources are actually under `$REPO`.
    ///
    /// `-ffile-prefix-map` is a literal prefix comparison, and a prefix that matches nothing is not an error — it maps nothing, silently, and the binary ships the builder's home directory in the assertion strings its C dependencies compile in. Left to a default `.build`, the dependency checkouts are reached by a path SwiftPM resolved for itself, which need not be spelled the way `$REPO` is; that directory is also shared with every unmapped `swift build` anyone runs, and for a C dependency the last compile wins. Naming a scratch path under `$REPO` settles both, because the map's prefix and the sources it must reach then come from the same string.
    ///
    /// Note what will *not* save a mismatch: `pwd -P` resolves symlinks but does not canonicalise case under `/bin/sh`, whatever zsh's builtin does interactively. The agreement has to be built in, not spelled out.
    @Test
    func everyPrefixMappedBuildCompilesUnderTheRootItMapsAway() throws {
        let mapping = try Self.distributionScripts().filter {
            try String(contentsOf: $0, encoding: .utf8).contains("-ffile-prefix-map=$REPO")
        }
        // The same principle the gate itself insists on: a check with nothing to check must not report
        // the same word as one that checked.
        #expect(!mapping.isEmpty, "no script builds a prefix map from REPO — this check would pass whatever it was given")

        for script in mapping {
            let text = try String(contentsOf: script, encoding: .utf8)
            let scratch = try #require(
                text.split(separator: "\n").first { $0.hasPrefix("SCRATCH=") },
                "\(script.lastPathComponent) maps $REPO away without building into a scratch path under it"
            )

            #expect(scratch.contains("\"$REPO/"), "\(script.lastPathComponent) builds outside the root it maps away")
            #expect(text.contains("--scratch-path \"$SCRATCH\""), "\(script.lastPathComponent) never passes the scratch path it defines")
        }
    }

    /// A directory name and the way people write it are two strings, and the gate has to hold both.
    ///
    /// The needles are discovered from the filesystem, so they arrive in the filesystem's spelling — and prose does not use it. `TanagerWidget` on disk is `Tanager Widget` in a sentence, and a literal match for the directory name walks straight past every sentence that mentions the project; that is precisely how a test fixture naming a sibling would pass this gate and the suite beside it. The acronym form is the second substitution's job, because `HTMLParser` has no lower-case letter at the boundary to hinge on.
    ///
    /// The names are invented, as every fixture name in this suite is. Writing a real neighbour's name down here to prove the gate catches it would put the leak in the repository in order to test the check that exists to keep it out.
    @Test
    func aNeighbourIsNamedInTheSpellingsProseUsesAndNotOnlyTheOneOnDisk() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["TanagerWidget", "HTMLParser"])

        for (index, prose) in ["TanagerWidget", "Tanager Widget", "Tanager-Widget", "HTML Parser", "HTML-Parser"].enumerated() {
            let document = root.appending(path: "prose-\(index).txt")
            try "a screenshot taken in \(prose) on launch.\n".write(to: document, atomically: true, encoding: .utf8)

            #expect(try !Self.gateClears(document, invokedAt: subject), "the gate cleared a file naming '\(prose)'")
        }
    }

    /// The one file that defines the check is not evidence about itself.
    ///
    /// `private-terms.txt` *is* the list of forbidden terms, so a gate that reads it fails on its own definition and on nothing else. A staged bundle contains neither file, so it arises only when the subject is the checkout — which is what publishing the repository makes it.
    @Test
    func theCheckDoesNotFailOnTheListItChecksAgainst() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root)

        let terms = subject.appending(path: "Distribution/private-terms.txt")

        #expect(try Self.gateClears(terms, invokedAt: subject), "the gate failed on the list of terms, which defines it")
    }

    /// …and it is exempt from its own words and from nothing else.
    ///
    /// A skip that returns before both scans leaves the discovered project names, `$HOME`, the username, the address and the handle unlooked-for in that file too. It is tracked, it ships, and its own header is prose about the sibling projects — so a maintainer extending that prose with "do not mention <a real neighbour>", or adding a contact address to it, is cleared by the two gates that exist to catch exactly those sentences. A private name in the word list is a leak like a private name anywhere else; only the words are its own definition.
    @Test
    func theListOfTermsIsExemptFromItsOwnWordsAndFromNothingElse() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["Kestrel"])
        let terms = subject.appending(path: "Distribution/private-terms.txt")

        // A comment: the file is a list of needles read line by line, so what is planted has to be inert
        // to the reader as well as visible to the scan.
        let planted = try String(contentsOf: terms, encoding: .utf8) + "# for example, a screenshot taken in Kestrel on launch\n"
        try planted.write(to: terms, atomically: true, encoding: .utf8)

        #expect(try !Self.gateClears(terms, invokedAt: subject), "the gate cleared a neighbour's name written into the list of terms")
    }

    /// A tracked path that is not on disk is a state this reports, not a wound the run dies of.
    ///
    /// `git ls-files` lists index entries, so `rm Docs/Something.md` without the `git rm` leaves the tree gate a path `stat` cannot answer for. Under `set -e` that kills the run where it stands — every path after it unscanned — and what reaches the pusher is one bare `stat:` line, indistinguishable from a finding and arriving in the place a finding arrives. So the walk carries on, and the path it could not read is named and counted out of the verdict rather than passed over.
    @Test
    func aPathThatIsTrackedAndNotOnDiskIsReportedRatherThanFatal() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["Kestrel"])

        let clean = root.appending(path: "clean.txt")
        try "nothing private here.\n".write(to: clean, atomically: true, encoding: .utf8)
        let absent = root.appending(path: "deleted-but-still-tracked.txt")
        let leak = root.appending(path: "names-a-neighbour.txt")
        try "a screenshot taken in Kestrel on launch.\n".write(to: leak, atomically: true, encoding: .utf8)

        let run = try Self.gateRun([clean, absent, leak], invokedAt: subject)
        // Reduced to a `Bool` before it is asserted on, as everything in this suite is: a failure prints
        // the captured sub-expression, and this one is a whole run's output.
        let reachedTheLastPath = run.output.contains("names 'Kestrel'")
        let saidWhatItCouldNotRead = run.output.contains("deleted-but-still-tracked.txt")

        #expect(run.status == 1)
        #expect(reachedTheLastPath, "the walk stopped at the path that was not there")
        #expect(saidWhatItCouldNotRead, "a path the gate did not read went unmentioned")
    }

    /// The script's own prose is checked, with no exemption.
    ///
    /// An exemption would cover the whole file, so any illustration of what the gate catches — and one written as a real sibling project name is the illustrative kind — would sit in the one file a reader of a public repository opens first, cleared by a gate that never read a byte of it and by the suite beside it.
    ///
    /// Asserted at the script's *own* inode rather than on a copy, because that is exactly what a skip would turn on: a copy proves the needles work and says nothing about which files the gate reads. So the file the gate is invoked as is the file given a neighbour's name, and clearing it is the failure.
    @Test
    func theScriptsOwnProseIsReadLikeEveryOtherFiles() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        // Not this suite's usual `Neighbour`, and not its `Tanager` either: a name is matched as a
        // substring, and the script's prose explains what neighbours are and illustrates the spellings
        // with the Tanager family. Both would fail it on clean content — which is a fair statement of
        // what scanning the file costs, and cheaper than the alternative by the width of this branch.
        let subject = try Self.checkout(in: root, neighbours: ["Kestrel"])
        let script = subject.appending(path: "Distribution/verify-private.sh")

        #expect(try Self.gateClears(script, invokedAt: subject), "the gate failed on its own prose, which names nothing private")

        // A trailing comment: the gate is still executed from this file, so what is appended has to be
        // inert to `sh` as well as visible to the scan.
        let planted = try String(contentsOf: script, encoding: .utf8) + "\n# for example, a screenshot taken in Kestrel on launch\n"
        try planted.write(to: script, atomically: true, encoding: .utf8)

        #expect(try !Self.gateClears(script, invokedAt: subject), "the gate cleared its own file naming a neighbour")
    }

    /// The identity needles are read off the machine, so the two that travel furthest are read off it too.
    ///
    /// A username in a path is a build artifact of where something was compiled; an address and a handle are contact details, and both survive the copy-paste that strips the path around them. Both are exercised against a fabricated environment rather than the real one, so the property is stated without either real value being written down here.
    @Test
    func anAddressAndAHandleReadOffTheEnvironmentAreBothPrivateNames() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root)

        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home.appending(path: ".config/gh"), withIntermediateDirectories: true)
        try "github.com:\n    user: octocat\n    git_protocol: ssh\n"
            .write(to: home.appending(path: ".config/gh/hosts.yml"), atomically: true, encoding: .utf8)
        let gitconfig = home.appending(path: ".gitconfig")
        try "[user]\n\temail = nobody@example.invalid\n".write(to: gitconfig, atomically: true, encoding: .utf8)

        // `GIT_CONFIG_GLOBAL` is set after the scrub, not before it: `withoutGit` drops the whole `GIT_`
        // namespace, which is the point of it, and this one variable is how the address is fabricated.
        var environment = ProcessEnvironment.withoutGit()
        environment["HOME"] = home.path
        environment["GIT_CONFIG_GLOBAL"] = gitconfig.path

        for (index, identity) in ["octocat", "nobody@example.invalid"].enumerated() {
            let document = root.appending(path: "identity-\(index).txt")
            try "reported by \(identity)\n".write(to: document, atomically: true, encoding: .utf8)

            #expect(try !Self.gateClears(document, invokedAt: subject, environment: environment), "the gate cleared a file naming '\(identity)'")
        }
    }

    /// The other direction of the same rule: skipping the checkout by identity must not blunt the check.
    @Test
    func aNeighbourIsStillNamedThroughTheSamePathSpelling() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root)
        let aliased = subject.deletingLastPathComponent().appending(path: subject.lastPathComponent.lowercased())
        guard Self.sameDirectory(subject, aliased) else { return }
        let document = root.appending(path: "names-a-neighbour.txt")
        try "Neighbour is the other project on this machine.\n"
            .write(to: document, atomically: true, encoding: .utf8)

        #expect(try !Self.gateClears(document, invokedAt: aliased))
    }

    /// The check that discovers private names runs without anyone remembering to run it.
    ///
    /// It is the only one that knows them — the Swift suite beside it checks the generic terms and the builder's identity, and a sibling project's name is neither — and reached only from the three bundle builders, its subject would be seven documents and a binary, where the leak it exists to catch is as likely to be a test fixture. So the artifact is the tracked tree and the caller is `pre-push`: what a hook does is what happens, and what a usage comment says is what someone remembers.
    ///
    /// **Executed, not matched.** Every substring worth asserting appears in those files' *comments* as well as in their code — so a substring check passes with the line that invokes the gate commented out, and with the branch that propagates the exit code deleted. So this runs `verify-tree.sh`. The hook's first act is `swift test`, which cannot run inside itself: a stub earlier on `PATH` answers for that one command, and everything after it is the real hook running the real tree gate over a real `git ls-files`.
    ///
    /// It has to pass the clean tree before it blocks the dirty one. "The hook exited nonzero" says nothing on its own — a hook that blocks everything blocks this too.
    @Test
    func everyPushRunsTheGateOverTheWholeTrackedTree() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.gitCheckout(in: root, neighbours: ["Kestrel"], carrying: Self.theCheckAndItsCaller)
        let hook = subject.appending(path: "githooks/pre-push")
        let environment = try Self.stubbing("swift", with: "#!/bin/sh\nexit 0\n", in: root)

        let clean = try Self.shell(hook, in: subject, environment: environment)
        #expect(clean.status == 0, "the hook blocked a push over a tree that names nothing private")

        try TestSources.write("a screenshot taken in Kestrel on launch.\n", to: "Docs/Capture.md", in: subject)
        try TestSources.commitAll(in: subject, message: "a fixture that names a neighbour")

        let blocked = try Self.shell(hook, in: subject, environment: environment)
        // Reduced to a `Bool` before it is asserted on: the sub-expression is a whole run's output.
        let namedTheFile = blocked.output.contains("Docs/Capture.md")
        #expect(blocked.status != 0, "the hook let a push through over a tracked file naming a neighbour")
        #expect(namedTheFile, "the hook blocked, but not over the file it was meant to find")
    }

    /// The suite's six thousand lines are read by whichever agent pushed, so where the machine has `sift` the hook runs the suite through it — and a clone without one, or a caller who asks, still gets the bare run.
    ///
    /// The suite is also not run at all where the ledger already has this exact tree proved green, which is the whole point of the record: asked, and then not run.
    @Test
    func thePushRunsTheSuiteThroughSiftWhereThereIsOne() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "pre-push-suite")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.gitCheckout(in: root, neighbours: ["Kestrel"], carrying: Self.theCheckAndItsCaller)
        let hook = subject.appending(path: "githooks/pre-push")
        let withoutSift = try Self.shell(hook, in: subject, environment: Self.stubbing("swift", with: "#!/bin/sh\necho \"bare $*\"\nexit 0\n", in: root))
        // The stub answers `run --help` with the flag's name, because the hook looks for it there before
        // using it — a binary older than the ledger would otherwise be handed `--proved` as part of the
        // command it wraps. `--proved` exiting nonzero is the ledger knowing nothing about this tree, which
        // is what a fixture repository nothing has ever run in is; every other invocation of the stub
        // succeeds, so the branch under test is the hook's and never the stub's. An unproved tree is refused
        // outright unless `SIFT_PRE_PUSH_RUN=1` asks for the run here (PrePushUnprovedTests pins the refusal),
        // so the wrapped run is asked for.
        var wrapped = try Self.stubbing("sift", with: "#!/bin/sh\necho \"wrapped $*\"\ncase \"$2\" in --help) echo -- --proved ;; --proved) exit 1 ;; esac\nexit 0\n", in: root)
        let withSift = try Self.shell(hook, in: subject, environment: wrapped.merging(["SIFT_PRE_PUSH_RUN": "1"]) { $1 })
        let skipped = try Self.shell(hook, in: subject, environment: Self.stubbing("sift", with: "#!/bin/sh\necho \"wrapped $*\"\ncase \"$2\" in --help) echo -- --proved ;; esac\nexit 0\n", in: root))
        wrapped["SIFT_PRE_PUSH_RAW"] = "1"
        let askedForBare = try Self.shell(hook, in: subject, environment: wrapped)

        #expect(withoutSift.output.contains("bare test"))
        #expect(withSift.output.contains("wrapped run --proved -- swift test"))
        #expect(withSift.output.contains("wrapped run -- swift test"))
        #expect(!withSift.output.contains("bare test"))
        // Asked, and then not run: a hook that asked and ran anyway passes the first of these, one that
        // skipped without asking passes the second, and neither stands for the property on its own.
        #expect(skipped.output.contains("wrapped run --proved -- swift test"))
        #expect(!skipped.output.contains("wrapped run -- swift test"))
        #expect(skipped.status == 0)
        #expect(askedForBare.output.contains("bare test"))
        // The escape hatch defeats the ledger by the wider route: no `sift` runs at all, so the question is
        // never put and no record can answer it.
        #expect(!askedForBare.output.contains("--proved"))
    }

    /// A file naming a neighbour fails the tree gate before anyone has staged it, and an ignored one does not.
    ///
    /// With `git ls-files` as the whole listing, a file in the root reading `a screenshot taken in <a real sibling project> on launch` — the exact class of leak this gate exists to catch — clears it at `verified: N of M paths name nothing private`, exit 0, for as long as it is untracked: a leak has only to be new.
    ///
    /// Both halves in one run, because the escape hatch is what makes the strictness bearable and a gate that reads an ignored file is one somebody switches off: the same bytes under a `.gitignore`d path must clear it in the same tree, and `.build/` is the path that matters — a checkout that failed its own push over a build artefact naming a neighbour would be repaired by an exception, and a gate with exceptions is a gate nobody trusts.
    ///
    /// The neighbour is named in the spelling prose uses rather than the one on disk, for the reason ``aNeighbourIsNamedInTheSpellingsProseUsesAndNotOnlyTheOneOnDisk`` gives: that is the spelling the leak arrived in.
    @Test
    func theTreeGateReadsAFileGitDoesNotTrackYetAndNotOneItIgnores() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.gitCheckout(in: root, neighbours: ["Kestrel"], carrying: Self.theCheckAndItsCaller)
        let gate = subject.appending(path: "Distribution/verify-tree.sh")
        let leak = "a screenshot taken in Kestrel on launch.\n"

        try TestSources.write(".build/\n", to: ".gitignore", in: subject)
        try TestSources.write(leak, to: ".build/log.txt", in: subject)
        let ignored = try Self.shell(gate, in: subject)
        #expect(ignored.status == 0, "the tree gate read a path git ignores:\n\(ignored.output)")

        try TestSources.write(leak, to: "Docs/Capture.md", in: subject)
        let untracked = try Self.shell(gate, in: subject)
        // Reduced to a `Bool` before it is asserted on, as everything in this suite is: the
        // sub-expression is a whole run's output.
        let namedTheFile = untracked.output.contains("Docs/Capture.md")

        #expect(untracked.status == 1, "the tree gate cleared an untracked file naming a neighbour")
        #expect(namedTheFile, "the tree gate blocked, but not over the file it was meant to find")
    }

    /// A path git quotes is refused rather than half-checked, and the untracked listing is read for one too.
    ///
    /// `git ls-files` quotes a path holding a newline, a control character or a byte outside ASCII, and a quoted path is not the path: walked, it is a `stat` that fails somewhere in the middle of the tree, leaving a nonzero exit that reads exactly like a finding. The refusal is deliberate and its whole point is that it is *loud* — the gate says it cannot pass the path through, rather than clearing a tree it only partly read.
    ///
    /// The half that matters is which listing it reads. Refusing over the tracked listing alone would let a quoted *untracked* path into the walk unexamined — the same failure, in the one file where nobody would think to look for it. So the check reads the union, and this is a file git has not been told about.
    ///
    /// The cost is stated rather than hidden: an uncommitted scratch file with an accent in its name stops a push. That is the same answer the gate gives for a tracked one, it names the file, and `.gitignore` is the way out.
    @Test
    func aQuotedPathIsRefusedEvenWhenGitDoesNotTrackIt() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.gitCheckout(in: root, neighbours: ["Kestrel"], carrying: Self.theCheckAndItsCaller)

        // Nothing private in it: what the gate must refuse over is the *name*, and a leak in the
        // content would fail the run for the other reason and prove nothing.
        try TestSources.write("nothing private here.\n", to: "Docs/caf\u{e9}.md", in: subject)
        let run = try Self.shell(subject.appending(path: "Distribution/verify-tree.sh"), in: subject)
        // Reduced to a `Bool` before it is asserted on: the sub-expression is a whole run's output.
        let saidWhy = run.output.contains("quoted by git ls-files")

        #expect(run.status == 1, "the gate walked a tree holding a path it cannot pass through")
        #expect(saidWhy, "the gate refused without saying the path was quoted")
    }

    /// A path the index still names and the working tree no longer holds is left out of the listing, not skipped in it.
    ///
    /// ``aPathThatIsTrackedAndNotOnDiskIsReportedRatherThanFatal`` is the other end of this and stays exactly as it is: handed such a path, `verify-private.sh` names it, counts it out of the verdict, and walks on. The tree entry point simply never hands it one. Halfway through an ordinary rename the index names the old path and the working tree does not, and what this gate reads is the working tree — so the path is not a hole in the check, it is not part of the subject.
    ///
    /// The difference shows up in the verdict, which is where it matters: `verified: N of M paths … (1 skipped)` is a release gate saying out loud that it did not read everything it was given. Handing it one would spend one of those on every rename, on a file that was never in the tree being published, and a number a reader has to discount is a number that stops being read.
    @Test
    func aRenamedAwayPathIsNotCountedAgainstTheTreeGatesVerdict() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.gitCheckout(in: root, neighbours: ["Kestrel"], carrying: Self.theCheckAndItsCaller)
        try TestSources.write("nothing private here.\n", to: "Docs/Moved.md", in: subject)
        try TestSources.commitAll(in: subject, message: "a document about to move")
        try FileManager.default.removeItem(at: subject.appending(path: "Docs/Moved.md"))

        let run = try Self.shell(subject.appending(path: "Distribution/verify-tree.sh"), in: subject)
        // Reduced to a `Bool` before it is asserted on: the sub-expression is a whole run's output.
        let countedItOut = run.output.contains("Docs/Moved.md")

        #expect(run.status == 0, "the tree gate found something in a fixture that names nothing private")
        #expect(!countedItOut, "the tree gate listed a path the working tree does not hold, and then reported skipping it")
    }

    /// The gate takes every temporary file it made away with it.
    ///
    /// The tree gate's last act is `exec`, which replaces the process image — so a `trap … EXIT` written to remove its list of paths never fires, and one file is left behind on every push, unattributable to anything, because `mktemp` names a file after nothing.
    ///
    /// `mktemp` is what the fixture answers for, which is what makes this exact rather than statistical: macOS resolves the temporary directory through `confstr` and ignores `$TMPDIR`, so a run cannot be given one of its own, and a before-and-after count of the machine's would race every other test in the suite. A stub that answers with paths under the fixture makes every temporary file in the run this run's, and the assertion is then that none of them is left — which covers `verify-private.sh`'s seven as well as the list.
    @Test
    func theGateRemovesEveryTemporaryFileItMade() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.gitCheckout(in: root, neighbours: ["Kestrel"], carrying: Self.theCheckAndItsCaller)
        let scratch = root.appending(path: "scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Counted rather than `$$`-suffixed: a command substitution can share its parent's process id,
        // and two temporary files that are one file is the failure this would then never see.
        let environment = try Self.stubbing(
            "mktemp",
            with: """
            #!/bin/sh
            n=0
            while [ -e "\(scratch.path)/tmp.$n" ]; do n=$((n + 1)); done
            : > "\(scratch.path)/tmp.$n"
            echo "\(scratch.path)/tmp.$n"

            """,
            in: root
        )

        let run = try Self.shell(subject.appending(path: "Distribution/verify-tree.sh"), in: subject, environment: environment)
        #expect(run.status == 0, "the tree gate found something in a fixture that names nothing private")

        let left = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        #expect(left.isEmpty, "the gate left \(left.count) temporary file(s) behind")
    }

    /// A push from a linked worktree learns the names a push from the checkout it belongs to would.
    ///
    /// Discovery reads the directories beside the checkout, and a worktree does not sit beside them: it sits under `.claude/worktrees/`, whose only entries are other worktrees of the same repository. Read from there the neighbour set is empty — and an empty neighbour set is the one answer this gate is permitted to skip on, so a push from a worktree would go through with not one needle looked for. Change-producing work is routinely done in worktrees, so this is not a corner case.
    ///
    /// The exit code is the assertion and not merely "it did not clear". The failure this pins reports **2**, which `githooks/pre-push` reads as a report about the machine and lets the push through on.
    @Test
    func aLinkedWorktreeLearnsTheNeighboursOfTheCheckoutItHangsOff() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = try Self.gitCheckout(in: root, neighbours: ["Kestrel"])
        let worktree = try TestSources.makeWorktree(of: primary, named: "agent-fixture")
        let document = root.appending(path: "names-a-neighbour.txt")
        try "a screenshot taken in Kestrel on launch.\n".write(to: document, atomically: true, encoding: .utf8)

        #expect(try Self.gateStatus(document, invokedAt: worktree) == 1)
    }

    /// The other direction of the same anchoring: the checkout a worktree hangs off is not one of its neighbours either.
    ///
    /// It is a directory in the list about to be walked — the worktree's own name never is — so identifying the checkout by the path this was invoked through would make the repository's own name a private one, and every file that names the tool would fail the gate. That is the failure that arrives quietly, because the repair it argues for is an exception.
    @Test
    func aLinkedWorktreeDoesNotDiscoverTheCheckoutAsItsOwnNeighbour() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = try Self.gitCheckout(in: root, neighbours: ["Kestrel"])
        let worktree = try TestSources.makeWorktree(of: primary, named: "agent-fixture")
        let document = root.appending(path: "names-the-checkout.txt")
        try "\(primary.lastPathComponent) is the checkout itself.\n"
            .write(to: document, atomically: true, encoding: .utf8)

        #expect(try Self.gateClears(document, invokedAt: worktree))
    }

    /// Having nothing to look for and finding something are different answers, and the exit code has to tell them apart.
    ///
    /// The gate refuses when it discovers no neighbours, because it would then pass whatever it was given. On a clone that holds only this repository that refusal is a fact about the machine, not about the push — so it exits 2 and the hook says so and continues, where a 1 would block every push made from such a checkout and teach everyone to pass `--no-verify`.
    ///
    /// It is a fact about the machine only because the neighbours are read from the primary checkout. Anchored to wherever the script happens to sit, the same 2 is also what a worktree reports, and the sentence above is then false in the one case that matters: `aLinkedWorktreeLearnsTheNeighboursOfTheCheckoutItHangsOff` is the other half of this claim.
    @Test
    func discoveringNoNeighboursIsADifferentExitCodeFromFindingALeak() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: [])
        let document = root.appending(path: "clean.txt")
        try "nothing private here.\n".write(to: document, atomically: true, encoding: .utf8)

        #expect(try Self.gateStatus(document, invokedAt: subject) == 2)
    }

    /// A checkout whose git directory sits somewhere else learns the neighbours of the checkout, not of whatever happens to hold that directory.
    ///
    /// The parent of the common git directory is the checkout in the ordinary layout and in no other. Given `--separate-git-dir` the git directory can be anywhere at all, and anchoring discovery on its parent reads a directory with nothing to do with the repository: the neighbour is never discovered, and a file naming it is cleared outright — `verified: … names nothing private`, exit 0, nothing said. That is the shape every property here is written against, because a gate that resolves the checkout wrongly does not fail loudly; it looks for less and passes. ``GitContext`` settles the same question by asking git instead of taking a parent, and so does the gate.
    ///
    /// **Where the git directory is put decides whether this test pins anything**, and the obvious siting does not. Left somewhere outside any working tree, the parent arithmetic resolves a directory that is inside no work tree — which trips the gate's confirmation guard, so the gate exits 1 for a reason that has nothing to do with the neighbours, and the exit code alone cannot tell that refusal from a finding. So the fixture uses the shape this actually arrives in: a dotfiles repository holding the git directories of the trees it manages. The arithmetic then lands on a plausible checkout, discovers *its* neighbours, and clears the leak. Measured both ways over this layout — buggy `exit=0 verified: … names nothing private`, fixed `exit=1 error: … names 'Kestrel'`.
    ///
    /// The message is asserted and not only the status, for the same reason: 1 means both *found something* and *could not anchor the checkout*.
    @Test
    func aCheckoutWhoseGitDirectoryIsElsewhereLearnsItsOwnNeighbours() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["Kestrel"])
        // A working tree of its own, with a neighbour beside the git directories it holds — so the parent
        // arithmetic reaches a checkout it can believe in, and discovers the wrong names rather than refusing.
        let host = root.appending(path: "Dotfiles")
        try FileManager.default.createDirectory(at: host.appending(path: "gitdirs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: host.appending(path: "config"), withIntermediateDirectories: true)
        try TestSources.runGit(["init", "-b", "main", host.path], in: root)
        let gitDirectory = host.appending(path: "gitdirs/subject")
        try TestSources.runGit(["init", "--separate-git-dir", gitDirectory.path, "-b", "main", subject.path], in: root)
        let document = root.appending(path: "names-a-neighbour.txt")
        try "a screenshot taken in Kestrel on launch.\n".write(to: document, atomically: true, encoding: .utf8)

        let run = try Self.gateRun([document], invokedAt: subject)

        #expect(run.status == 1)
        #expect(run.output.contains("Kestrel"), "the status alone cannot tell a finding from a refusal — both exit 1")
    }

    /// A repository with no working tree refuses, rather than reporting that the machine holds nothing to compare against.
    ///
    /// A bare repository sits *beside* the other projects rather than inside a checkout, so the parent of its git directory is the projects directory itself and discovery, one level too high, comes back empty. The gate would then say "no sibling projects" — the one verdict `githooks/pre-push` continues past — with a neighbour sitting next to the repository and not one needle looked for.
    ///
    /// The exit code is the assertion, and it is the same distinction ``discoveringNoNeighboursIsADifferentExitCodeFromFindingALeak()`` rests on: 2 is a fact about the machine, 1 is a refusal about this checkout, and only the first is something a push may carry on past. It can reach that branch at all because `rev-parse --is-inside-work-tree` says `false` by *printing* it and exiting 0, so a test of the exit status alone reads a bare repository as a working tree.
    @Test
    func aRepositoryWithNoWorkingTreeRefusesInsteadOfReportingAnEmptyMachine() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let bare = try Self.checkout(in: root, named: "subject.git", neighbours: ["Kestrel"])
        try TestSources.runGit(["init", "--bare", bare.path], in: root)
        let document = root.appending(path: "names-a-neighbour.txt")
        try "a screenshot taken in Kestrel on launch.\n".write(to: document, atomically: true, encoding: .utf8)

        let run = try Self.gateRun([document], invokedAt: bare)

        #expect(run.status == 1, "a repository with no checkout to read neighbours from is not a pass and not a skip")
        #expect(run.output.contains("no working tree"), "the refusal has to say which question it could not answer")
    }

    /// A worktree whose repository will not name a primary checkout refuses rather than walking whatever it was handed.
    ///
    /// `git worktree list` reports the main working tree first, which is the answer for the ordinary layout and is how a linked worktree reaches the neighbours it cannot see from where it sits. It is not always a working tree: where the main tree's git directory sits outside it, git names the git directory instead, and a bare repository's first entry is a git directory too. Neither has neighbours that mean anything, so what git hands back is confirmed before it is walked.
    ///
    /// The cost is a refused push from an unusual layout, and the refusal says what to do instead. The alternative is discovering names from a directory that merely looked like a checkout, which is the same silent under-discovery in a new spelling.
    @Test
    func aWorktreeWhoseRepositoryNamesNoPrimaryCheckoutRefuses() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["Kestrel"])
        let gitDirectory = root.appending(path: "Aside/subject-gitdir")
        try FileManager.default.createDirectory(at: gitDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestSources.runGit(["init", "--separate-git-dir", gitDirectory.path, "-b", "main", subject.path], in: root)
        try TestSources.runGit(["config", "user.email", "tester@example.invalid"], in: subject)
        try TestSources.runGit(["config", "user.name", "Tester"], in: subject)
        try TestSources.commitAll(in: subject, message: "seed")
        let worktree = try TestSources.makeWorktree(of: subject, named: "agent-fixture")
        let document = root.appending(path: "names-a-neighbour.txt")
        try "a screenshot taken in Kestrel on launch.\n".write(to: document, atomically: true, encoding: .utf8)

        let run = try Self.gateRun([document], invokedAt: worktree)

        #expect(run.status == 1)
        #expect(run.output.contains("cannot locate"), "a gate that could not anchor its search must say so, not report a clean file")
    }
}

/// The case-boundary refinement to substring matching, split out from the struct above purely to keep it under `type_body_length` — these three share every helper it declares.
extension PrivacyGateTests {
    /// A name's letters turn up inside two unrelated words by pure coincidence of English — `underGoing` contains `erGo` — and a substring match cannot tell that from the name itself.
    ///
    /// What tells the two apart is where the case changes: `Ergo` never moves from lower to upper, and `erGo` does, right in the middle of the coincidence. A hit stands only when the matched text's own case changes are ones the name's own spelling already has.
    @Test
    func aSubstringMatchIsRejectedWhenOnlyACamelCaseCoincidenceProducesIt() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["Ergo"])

        let coincidence = root.appending(path: "coincidence.txt")
        try "the store keeps underGoing a slow migration.\n".write(to: coincidence, atomically: true, encoding: .utf8)
        let real = root.appending(path: "the-real-name.txt")
        try "Ergo is the project next door.\n".write(to: real, atomically: true, encoding: .utf8)

        #expect(try Self.gateClears(coincidence, invokedAt: subject), "a case boundary the name never has was read as a mention")
        #expect(try !Self.gateClears(real, invokedAt: subject), "the name itself went unmatched")
    }

    /// The same property, taken from the other side: every case-folding of a name with no internal transition of its own — including one landing mid-word, where nothing at all changes case at the boundary — is still exactly the name, and still fails the gate.
    @Test
    func aSubstringMatchStillCountsWhateverCaseTheNameItselfIsSpelledIn() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["Ergo"])

        for (index, prose) in ["Ergo", "ergo", "ERGO", "ErgoKit", "MyErgo", "myErgo", "Ergos", "ergo-widget", "the ergo app"].enumerated() {
            let document = root.appending(path: "prose-\(index).txt")
            try "a screenshot taken in \(prose) on launch.\n".write(to: document, atomically: true, encoding: .utf8)

            #expect(try !Self.gateClears(document, invokedAt: subject), "the gate cleared a file naming '\(prose)'")
        }
    }

    /// A name that has one transition of its own (`TanagerWidget` turns from lower to upper once, at `r`→`W`) keeps that one and still rejects a second, unrelated one the match adds elsewhere — the two-word straddle where the name's own words end and another word begins mid-match, as `renamed…Tail` would beside a name ending `…Widget`.
    ///
    /// Having a transition of its own does not make a name's matches immune to gaining an extra one it never had.
    @Test
    func aNamesOwnTransitionIsKeptButASecondUnrelatedOneStillRejectsTheMatch() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["TanagerWidget"])

        // `WidgeTail` reuses the name's own r→W transition and then straddles into a second word with
        // one of its own — the case the first fixture above does not cover, where the name is not flat.
        let straddle = root.appending(path: "straddle.txt")
        try "a helper called xTanagerWidgeTail runs after launch.\n".write(to: straddle, atomically: true, encoding: .utf8)
        let real = root.appending(path: "the-real-name.txt")
        try "TanagerWidgetKit is the project next door.\n".write(to: real, atomically: true, encoding: .utf8)

        #expect(try Self.gateClears(straddle, invokedAt: subject), "a second case boundary the name never has was read as a mention")
        #expect(try !Self.gateClears(real, invokedAt: subject), "the name itself, extended by a suffix, went unmatched")
    }

    /// An acronym-led name's boundary sits where the acronym ends, not only where camel-case would put a lower→upper hinge — so a lower-camel spelling that hinges there (`xyzWidget`, lower `z` into upper `W`, where `XYZWidget` has its acronym boundary) is still the name and not a manufactured transition.
    ///
    /// Every spelling below has to fail the gate: the exact spelling, the lower-camel one, the flattened one, and the spaced and hyphenated ones `SPACED` already builds for any discovered name.
    @Test
    func anAcronymLedNamesLowerCamelSpellingIsStillCaughtAtItsAcronymBoundary() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["XYZWidget"])

        for (index, spelling) in ["XYZWidget", "xyzWidget", "xyzwidget", "XYZ Widget", "XYZ-Widget"].enumerated() {
            let document = root.appending(path: "prose-\(index).txt")
            try "a screenshot taken in \(spelling) on launch.\n".write(to: document, atomically: true, encoding: .utf8)

            #expect(try !Self.gateClears(document, invokedAt: subject), "the gate cleared a file naming '\(spelling)'")
        }
    }

    /// The acronym boundary is additive, not a replacement for the ordinary camel-case hinge: a name whose only transition is the ordinary kind (`TanagerWidget`, `r`→`W`) still keeps that transition as a boundary, so its lower-camel spelling is still caught once the acronym rule sits alongside it.
    @Test
    func aNamesOwnLowerCamelSpellingIsStillCaughtAfterTheAcronymBoundaryIsAdded() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["TanagerWidget"])

        let document = root.appending(path: "prose.txt")
        try "a screenshot taken in tanagerWidget on launch.\n".write(to: document, atomically: true, encoding: .utf8)

        #expect(try !Self.gateClears(document, invokedAt: subject), "the gate cleared a file naming 'tanagerWidget'")
    }

    /// A needle carrying a space of its own is exactly the shape the boundary filter cannot safely read.
    ///
    /// `spaced_form` cannot tell a space that was already in the needle from one it inserts, so a boundary after the first pre-existing space lands one character early. Routed away from the filter entirely — a needle with a space keeps the base gate's plain substring match — both the exact spelling and a lower/camel variant are still caught.
    ///
    /// `Old TanagerWidget` reuses the already-permitted `TanagerWidget` / `tanagerWidget` spellings rather than inventing a new compound, so this fixture needs no addition to the example-name list.
    @Test
    func aNeedleCarryingASpaceOfItsOwnKeepsEveryBoundaryAtItsRealPosition() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["Old TanagerWidget"])

        for (index, spelling) in ["Old TanagerWidget", "old tanagerWidget"].enumerated() {
            let document = root.appending(path: "prose-\(index).txt")
            try "a screenshot taken in \(spelling) on launch.\n".write(to: document, atomically: true, encoding: .utf8)

            #expect(try !Self.gateClears(document, invokedAt: subject), "the gate cleared a file naming '\(spelling)'")
        }
    }

    /// A needle with no uppercase letter has no boundary anywhere in its own spelling, so the filter would read every camel-cased mention of it as manufacturing a transition and reject all of them.
    ///
    /// That would lose a username most of all, since the machine reads one off lower-case. Not every identity needle is lower-case — a mixed-case handle, `github.user` or the `gh` login, is identifier-shaped and goes through the filter as a discovered name does — but one with no uppercase letter is routed away from the filter for the same reason as a needle with a space: it keeps the base gate's plain substring match, and every case-folding is still caught.
    ///
    /// `tanagerwidget`, all lower, is not itself a compound identifier the example-name list has to carry — `isCompound` requires an uppercase letter after the first — and the two mentions below are the already-permitted `TanagerWidget` / `tanagerWidget` spellings, so nothing new is added there either.
    @Test
    func aWhollyLowercaseNeighbourStillCatchesEveryCamelSpelling() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["tanagerwidget"])

        for (index, spelling) in ["TanagerWidget", "tanagerWidget"].enumerated() {
            let document = root.appending(path: "prose-\(index).txt")
            try "a screenshot taken in \(spelling) on launch.\n".write(to: document, atomically: true, encoding: .utf8)

            #expect(try !Self.gateClears(document, invokedAt: subject), "the gate cleared a file naming '\(spelling)'")
        }
    }

    /// The same property on the identity needles, which are read off the machine rather than discovered from a sibling directory.
    ///
    /// `id -un` is stubbed rather than faked through the environment, since the real check calls it directly with no override the environment can reach. The stubbed name is deliberately all lower, as every real username is, and both camel spellings of it are still caught — `MyErgo` and `myErgo` are already-permitted example names, so this needs no addition either.
    @Test
    func aWhollyLowercaseUsernameStillCatchesEveryCamelSpelling() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root)
        let environment = try Self.stubbing("id", with: "#!/bin/sh\ncase \"$1\" in\n    -un) echo myergo ;;\n    *) exit 1 ;;\nesac\n", in: root)

        for (index, spelling) in ["MyErgo", "myErgo"].enumerated() {
            let document = root.appending(path: "identity-\(index).txt")
            try "reported by \(spelling)\n".write(to: document, atomically: true, encoding: .utf8)

            #expect(try !Self.gateClears(document, invokedAt: subject, environment: environment), "the gate cleared a file naming '\(spelling)'")
        }
    }

    /// A needle's own boundaries come from `spaced_form`, which counts a digit as able to open one in the needle's *own* spelling — but the matched text's transition check looks only for a lower-to-upper hinge, never a digit-to-upper one.
    ///
    /// A needle whose digit is followed by a lowercase letter (`Kite3wing`) has no boundary there at all, so a mention hinging a digit into upper where the needle does not (`Kite3Wing`) was read as manufacturing a transition and rejected. Reverted to lower-to-upper only on the text side, the mention is caught again.
    @Test
    func aDigitHingingIntoUppercaseInTheTextAloneIsStillCaughtAsTheNameItIs() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["Kite3wing"])

        let document = root.appending(path: "prose.txt")
        try "a screenshot taken in Kite3Wing on launch.\n".write(to: document, atomically: true, encoding: .utf8)

        #expect(try !Self.gateClears(document, invokedAt: subject), "the gate cleared a file naming 'Kite3Wing'")
    }

    /// A non-ASCII needle is routed away from the boundary filter along with every other needle outside the `[A-Za-z0-9]` class, so it keeps the base gate's plain `grep -i` rather than `name_awk`'s own `LC_ALL=C awk`, whose `tolower` folds only ASCII: an accented capital and its lowercase form are two genuinely different multi-byte sequences (`É` is `0xC3 0x89`, `é` is `0xC3 0xA9`), neither of which `tolower` touches, so the byte-level substring pre-check inside `name_awk` fails before the boundary rule is even reached — the mention is not rejected as a manufactured transition, it is simply never seen as a match at all.
    ///
    /// The needle here is a fabricated `gh` handle rather than a discovered sibling directory, because a directory name is the one shape this property cannot be demonstrated on: APFS does not keep `É` as the single precomposed codepoint a source literal writes it as — `basename` on a directory created with that literal reads back `E` followed by a combining acute accent, and lowercasing *that* is an ASCII transition (`E`→`e`) with an untouched, case-blind combining mark trailing it, which the pre-round-2 code already handled and does not exercise this bug at all. A handle read out of a stubbed `~/.config/gh/hosts.yml` is plain text with no filesystem underneath it to renormalize, so it keeps the single precomposed codepoint the fixture writes.
    ///
    /// Neither spelling is a compound identifier the example-name list has to carry: `ExampleNameScanner`'s tokenizer only ever starts or continues a token on an ASCII letter or digit, so the accented first letter breaks both `Éclair` and `éclair` into a leading non-token byte sequence and a plain lowercase `clair`, three letters short of the four the scanner requires either way.
    @Test
    func aNonASCIIHandleStillCatchesItsLowercasedMention() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root)

        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home.appending(path: ".config/gh"), withIntermediateDirectories: true)
        try "github.com:\n    user: Éclair\n    git_protocol: ssh\n"
            .write(to: home.appending(path: ".config/gh/hosts.yml"), atomically: true, encoding: .utf8)

        // The folding this pins is the UTF-8 locale's, so the run is given one whatever the runner has:
        // under the C locale neither reading folds `É` onto `é`, and this would fail a correct gate.
        var environment = Self.utf8Locale(ProcessEnvironment.withoutGit())
        environment["HOME"] = home.path

        let document = root.appending(path: "identity.txt")
        try "reported by éclair\n".write(to: document, atomically: true, encoding: .utf8)

        #expect(try !Self.gateClears(document, invokedAt: subject, environment: environment), "the gate cleared a file naming 'éclair'")
    }

    /// A backslash in a needle is routed away from `awk -v` along with every other needle outside the `[A-Za-z0-9]` class, so `awk`'s own escape handling never gets a needle it could misread — and the mention is still caught through the base gate's plain substring match.
    ///
    /// Neither half of the directory name is a compound identifier: `Depot` carries no uppercase after its first letter and `Kit` is three letters, one short of what the example-name list requires either side of the backslash that splits them into two tokens.
    @Test
    func aBackslashInANeighboursNameIsStillMatchedLiterally() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["Depot\\Kit"])

        let document = root.appending(path: "prose.txt")
        try "a screenshot taken in Depot\\Kit on launch.\n".write(to: document, atomically: true, encoding: .utf8)

        #expect(try !Self.gateClears(document, invokedAt: subject), "the gate cleared a file naming 'Depot\\Kit'")
    }

    /// A pin rather than a repair: a straddle the filter correctly rejects earlier in a line must not stop the scan from reaching a real mention of the same needle later on it.
    ///
    /// The `for` loop in `name_awk` that walks candidate windows does not `break` on a rejection, only on a match — a "first match only" rewrite that shortened it would pass every other test in this file while failing exactly this one.
    @Test
    func aRejectedStraddleEarlierOnALineDoesNotHideARealMentionLaterOnIt() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["Ergo"])

        let document = root.appending(path: "prose.txt")
        try "the store keeps underGoing while Ergo waits.\n".write(to: document, atomically: true, encoding: .utf8)

        #expect(try !Self.gateClears(document, invokedAt: subject), "the gate cleared a line naming 'Ergo' past a rejected straddle")
    }

    /// A long line naming a neighbour is read in time that grows with its length, not with its square.
    ///
    /// The boundary filter used to ask awk's `substr` for the window at every position of a line, and `substr` measures its whole string on every call — so one line of two million characters, the shape of a minified bundle, held the gate up for most of two minutes per identifier-shaped needle, and one of a few megabytes would stall a push for hours. It now jumps between the places the needle occurs with `index`, and asks about a needle at all only once a plain `grep` finds its letters in the file. The bound is generous: the gate reads this line in about a second.
    @Test
    func aLongLineNamingANeighbourOnceIsReadInTimeLinearInItsLength() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["Kestrel"])

        let document = root.appending(path: "long-line.txt")
        try (String(repeating: "abcdefghij", count: 200_000) + " Kestrel here\n").write(to: document, atomically: true, encoding: .utf8)

        var run: (status: Int32, output: String) = (0, "")
        let elapsed = try ContinuousClock().measure { run = try Self.gateRun([document], invokedAt: subject) }

        #expect(run.status == 1, "the gate cleared a long line naming a neighbour")
        #expect(run.output.contains("names 'Kestrel' (1)"), "the long line was not counted as naming the neighbour: \(run.output.prefix(300))")
        #expect(elapsed < .seconds(20), "the gate took \(elapsed) over one line of two million characters")
    }

    /// A name's words joined by an underscore are one of the spellings the gate looks for, beside the spaced and the hyphenated ones.
    ///
    /// A constant, a file name or a snake-cased key writes `TanagerWidget` as `Tanager_Widget`, and no other spelling the gate derives matches it: the underscore breaks the compound one, and the spaced and hyphenated ones differ from it at the same position.
    @Test
    func aNeighboursWordsJoinedByAnUnderscoreAreStillItsName() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["TanagerWidget"])

        for (index, spelling) in ["Tanager_Widget", "tanager_widget", "TANAGER_WIDGET"].enumerated() {
            let document = root.appending(path: "prose-\(index).txt")
            try "a screenshot taken in \(spelling) on launch.\n".write(to: document, atomically: true, encoding: .utf8)

            #expect(try !Self.gateClears(document, invokedAt: subject), "the gate cleared a file naming '\(spelling)'")
        }
    }
}

/// Reading a file as bytes: a line holding a byte that is not valid UTF-8 is read like any other.
///
/// Split out from the struct above for the same reason as the extension before it. Every gate run here is given a UTF-8 locale rather than inheriting the runner's — see `utf8Locale`.
extension PrivacyGateTests {
    /// `café`, then `rest`, as one Latin-1 line: its `é` is the single byte `0xE9`, which opens a three-byte UTF-8 sequence that the space after it cannot continue — so the line is not valid UTF-8, whatever `rest` holds.
    private static func latin1Line(_ rest: String) -> Data {
        var line = Data("caf".utf8)
        line.append(0xE9)
        line.append(contentsOf: Data(" \(rest)\n".utf8))

        return line
    }

    /// `environment` with its locale pinned to UTF-8, for a test whose property is how the gate reads under one.
    ///
    /// What a UTF-8 locale does with a byte that is not valid UTF-8 is what these tests are about, and a locale inherited from the runner is whatever that runner has. A CI job, or a pre-push from a GUI git client, may have none — and then the gate reads everything in the C locale, where the gate before the byte-reading fix already caught every fixture here, and the tests could no longer tell it from the gate after. `LC_ALL` rather than `LANG`, because it is the one no `LC_*` variable a runner sets can override.
    private static func utf8Locale(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = environment
        environment["LC_ALL"] = "en_US.UTF-8"

        return environment
    }

    /// An invalid byte on a line hides nothing else on it.
    ///
    /// Under a UTF-8 locale `grep` does not match a needle that sits at or after the first byte on its line that is not valid UTF-8, and says nothing about passing it over — so a one-line Latin-1 file naming a neighbour cleared the gate, while the same file failed it in the C locale. Each spelling reaches the gate's verdict by a different path: `TanagerWidget` through the boundary filter, `Tanager Widget` and `tanager-widget` through plain `grep`.
    @Test
    func aNameOnALineHoldingAnInvalidByteIsStillCaught() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["TanagerWidget"])

        for (index, spelling) in ["TanagerWidget", "Tanager Widget", "tanager-widget"].enumerated() {
            let document = root.appending(path: "latin-1-\(index).txt")
            try Self.latin1Line("a screenshot taken in \(spelling) on launch.").write(to: document)

            #expect(try !Self.gateClears(document, invokedAt: subject, environment: Self.utf8Locale()), "the gate cleared a Latin-1 line naming '\(spelling)'")
        }
    }

    /// The control, and what the verdict says: the same name on a second, clean line was always caught — only the line holding the invalid byte was ever passed over — and now both lines are counted and both are shown.
    ///
    /// The count is what checks the per-needle pass: a gate whose first `grep` found the file in the C locale and whose count of each needle still read in a UTF-8 locale would fail this file too, reporting one line where there are two. The Latin-1 line has to be shown for both needles, which `cut -c` in a UTF-8 locale stops short of, at the invalid byte.
    @Test
    func aLineHoldingAnInvalidByteIsCountedAndShownBesideACleanOne() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["TanagerWidget"])

        let document = root.appending(path: "latin-1.txt")
        let mention = "TanagerWidget, or Tanager Widget in prose"
        try (Self.latin1Line(mention) + Data("\(mention)\n".utf8)).write(to: document)

        let run = try Self.gateRun([document], invokedAt: subject, environment: Self.utf8Locale())
        let countedBothForTheFilter = run.output.contains("names 'TanagerWidget' (2)")
        let countedBothForGrep = run.output.contains("names 'Tanager Widget' (2)")
        let latin1LineShown = run.output.components(separatedBy: "café \(mention)").count - 1

        #expect(run.status == 1, "the gate cleared a file whose clean second line names a neighbour")
        #expect(countedBothForTheFilter, "the boundary filter's count missed a line")
        #expect(countedBothForGrep, "plain grep's count missed the line holding the invalid byte")
        #expect(latin1LineShown == 2, "the line holding the invalid byte was shown \(latin1LineShown) time(s), not once per needle")
    }

    /// A needle carrying a byte outside ASCII is looked for in both locales, and a line either reading finds counts.
    ///
    /// The C locale is the reading that sees a line holding an invalid byte — here a Latin-1 `é` beside a handle written in UTF-8, the mixed encoding a string table can carry. The caller's UTF-8 locale is the one that folds `É` onto `é`, which `aNonASCIIHandleStillCatchesItsLowercasedMention` pins: a gate that moved every needle to the C locale alone fails that test, and one that left this needle to the UTF-8 locale alone fails this one. What neither reading finds — an accented letter in its other case, on a line like this one — is the residual the gate's header states.
    @Test
    func aNonASCIIHandleOnALineHoldingAnInvalidByteIsStillCaught() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root)

        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home.appending(path: ".config/gh"), withIntermediateDirectories: true)
        try "github.com:\n    user: Éclair\n    git_protocol: ssh\n"
            .write(to: home.appending(path: ".config/gh/hosts.yml"), atomically: true, encoding: .utf8)

        var environment = Self.utf8Locale(ProcessEnvironment.withoutGit())
        environment["HOME"] = home.path

        let document = root.appending(path: "identity.txt")
        try Self.latin1Line("reported by Éclair").write(to: document)

        #expect(try !Self.gateClears(document, invokedAt: subject, environment: environment), "the gate cleared a Latin-1 line naming 'Éclair'")
    }

    /// The word list is read the same way: a term on a line holding an invalid byte is still caught.
    ///
    /// The term is taken out of the list when the test runs rather than written here, since this file is itself read for every term on the list.
    @Test
    func aTermOnALineHoldingAnInvalidByteIsStillCaught() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root)

        let terms = try String(contentsOf: subject.appending(path: "Distribution/private-terms.txt"), encoding: .utf8)
        let term = try #require(terms.split(separator: "\n").first { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        let document = root.appending(path: "latin-1.txt")
        try Self.latin1Line("and \(term) too").write(to: document)

        #expect(try !Self.gateClears(document, invokedAt: subject, environment: Self.utf8Locale()), "the gate cleared a Latin-1 line carrying a listed term")
    }

    /// A line both readings find is one line, and is counted once.
    ///
    /// A needle outside ASCII is read for twice, and a line that is valid UTF-8 and spells the needle's accented letters as the needle does is found by both: here `ÉCLAIR`, which the C reading finds by folding its ASCII letters and the UTF-8 reading by folding every letter. The second line only the UTF-8 reading finds, since `é` and `É` are different bytes. Two lines name the handle and the count says two; a merge that kept each reading's copy of the first line would say three.
    @Test
    func aLineBothReadingsFindIsCountedOnce() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root)

        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home.appending(path: ".config/gh"), withIntermediateDirectories: true)
        try "github.com:\n    user: Éclair\n    git_protocol: ssh\n"
            .write(to: home.appending(path: ".config/gh/hosts.yml"), atomically: true, encoding: .utf8)

        var environment = Self.utf8Locale(ProcessEnvironment.withoutGit())
        environment["HOME"] = home.path

        let document = root.appending(path: "identity.txt")
        try "reported by ÉCLAIR\nand again by éclair\n".write(to: document, atomically: true, encoding: .utf8)

        let run = try Self.gateRun([document], invokedAt: subject, environment: environment)

        #expect(run.status == 1, "the gate cleared a file naming 'Éclair' on two lines")
        #expect(run.output.contains("names 'Éclair' (2)"), "the two readings' lines were not merged into one count: \(run.output)")
    }

    /// A flagged line that opens with an invalid byte is shown, and the run goes on to the files after it.
    ///
    /// Under a UTF-8 locale BSD `sed` stops with `illegal byte sequence` on a line whose first bytes are not valid UTF-8, and the `sed` that indents a finding for display read in the caller's locale. As the last stage of a pipeline under `set -e` its failure ended the run at the first such finding: the verdict still failed, but every file after it went unread and unreported, behind output that read as a tool crash. One file here for each way a finding is shown — a listed term, a name through the boundary filter, and a name through plain `grep` in a CP1252 smart quote — each flagged line opening with its invalid byte, then a clean file naming the same neighbour. All four are reported.
    @Test
    func aFlaggedLineOpeningWithAnInvalidByteDoesNotEndTheRun() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["TanagerWidget"])

        let terms = try String(contentsOf: subject.appending(path: "Distribution/private-terms.txt"), encoding: .utf8)
        let term = try #require(terms.split(separator: "\n").first { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        // `0xDC` is a Latin-1 `Ü`, and `0x93`/`0x94` are CP1252's curly quotes: none of them can open a
        // UTF-8 sequence that the byte after it continues.
        let files: [(name: String, content: Data)] = [
            ("term.txt", Data([0xDC]) + Data("ber \(term) too\n".utf8)),
            ("filter.txt", Data([0xDC]) + Data("ber TanagerWidget\n".utf8)),
            ("grep.txt", Data([0x93]) + Data("Tanager Widget".utf8) + Data([0x94, 0x0A])),
            ("clean.txt", Data("mentions TanagerWidget\n".utf8)),
        ]
        var documents: [URL] = []
        for file in files {
            let document = root.appending(path: file.name)
            try file.content.write(to: document)
            documents.append(document)
        }

        let run = try Self.gateRun(documents, invokedAt: subject, environment: Self.utf8Locale())
        let unreported = documents.filter { !run.output.contains("\($0.path) names") }.map(\.lastPathComponent)

        #expect(run.status == 1, "the gate cleared four files that each name something")
        #expect(unreported.isEmpty, "the run ended before reporting \(unreported): \(run.output)")
        #expect(!run.output.contains("illegal byte sequence"), "a command stopped on a byte that is not valid UTF-8: \(run.output)")
        #expect(run.output.contains("    \u{DC}ber TanagerWidget"), "the flagged line opening with an invalid byte was not shown: \(run.output)")
    }

    /// The `gh` handle is read past a line holding an invalid byte.
    ///
    /// The handle is read out of `~/.config/gh/hosts.yml` with `sed`, and under a UTF-8 locale `sed` stops at the first line holding a byte that is not valid UTF-8. So a hosts file carrying one above its `user:` line — a comment written by hand in Latin-1, say — gave the gate no handle to look for, and a file naming it cleared with `names nothing private`.
    @Test
    func aHandleBelowALineHoldingAnInvalidByteIsStillANeedle() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root)

        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home.appending(path: ".config/gh"), withIntermediateDirectories: true)
        try (Self.latin1Line("# written by hand") + Data("github.com:\n    user: octocat\n    git_protocol: ssh\n".utf8))
            .write(to: home.appending(path: ".config/gh/hosts.yml"))

        var environment = Self.utf8Locale(ProcessEnvironment.withoutGit())
        environment["HOME"] = home.path

        let document = root.appending(path: "identity.txt")
        try "reported by octocat\n".write(to: document, atomically: true, encoding: .utf8)

        #expect(try !Self.gateClears(document, invokedAt: subject, environment: environment), "the gate cleared a file naming the handle read from below a Latin-1 line")
    }

    /// A needle outside ASCII can be named by a file holding no byte outside ASCII, and is caught there too.
    ///
    /// A UTF-8 `grep -i` folds a handful of letters outside ASCII onto ASCII ones — the dotless `ı` onto `I`, `İ` onto `i`, the long `ſ` onto `S`, the Kelvin sign onto `k` — so a handle `Vılkor` is named by an all-ASCII `VILKOR`. Only the gate's second reading, under the caller's locale, finds it: the C reading compares `ı` as the two bytes it is. This pins why the second reading is not skipped for a file that holds no byte outside ASCII, which looks like a free saving and would lose exactly this.
    @Test
    func aHandleWhoseAccentedLetterFoldsOntoASCIIIsCaughtInAnASCIIFile() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root)

        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home.appending(path: ".config/gh"), withIntermediateDirectories: true)
        try "github.com:\n    user: Vılkor\n    git_protocol: ssh\n"
            .write(to: home.appending(path: ".config/gh/hosts.yml"), atomically: true, encoding: .utf8)

        var environment = Self.utf8Locale(ProcessEnvironment.withoutGit())
        environment["HOME"] = home.path

        let document = root.appending(path: "identity.txt")
        try "reported by VILKOR\n".write(to: document, atomically: true, encoding: .utf8)

        #expect(try !Self.gateClears(document, invokedAt: subject, environment: environment), "the gate cleared an all-ASCII file naming 'Vılkor' as 'VILKOR'")
    }

    /// A needle holding a byte that is not valid UTF-8 leaves the second reading to the needles that can use it.
    ///
    /// A handle is whatever its owner typed into a config file, and one typed in Latin-1 — `É` as the single byte `0xC9` — is not a pattern a UTF-8 `grep` can read: it stops with `illegal byte sequence`. Handed over in one list with the other needles outside ASCII, it stopped that list's whole second reading, so a handle `Vılkor`, which only that reading finds in an all-ASCII `VILKOR` (`aHandleWhoseAccentedLetterFoldsOntoASCIIIsCaughtInAnASCIIFile`), cleared the gate, behind the error printed once per file. The Latin-1 needle itself is still caught by the C reading, which matches it as the bytes it is.
    @Test
    func aNeedleThatIsNotValidUTF8LeavesTheSecondReadingToTheOthers() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root)

        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home.appending(path: ".config/gh"), withIntermediateDirectories: true)
        try "github.com:\n    user: Vılkor\n    git_protocol: ssh\n"
            .write(to: home.appending(path: ".config/gh/hosts.yml"), atomically: true, encoding: .utf8)
        try (Data("[github]\n    user = ".utf8) + Data([0xC9]) + Data("clair\n".utf8)).write(to: home.appending(path: ".gitconfig"))

        var environment = Self.utf8Locale(ProcessEnvironment.withoutGit())
        environment["HOME"] = home.path

        let folded = root.appending(path: "folded.txt")
        try "reported by VILKOR\n".write(to: folded, atomically: true, encoding: .utf8)
        let latin1 = root.appending(path: "latin-1.txt")
        try (Data("reported by ".utf8) + Data([0xC9]) + Data("clair\n".utf8)).write(to: latin1)

        let foldedRun = try Self.gateRun([folded], invokedAt: subject, environment: environment)
        let latin1Run = try Self.gateRun([latin1], invokedAt: subject, environment: environment)

        #expect(foldedRun.status == 1, "the gate cleared an all-ASCII file naming 'Vılkor' beside a Latin-1 needle: \(foldedRun.output)")
        #expect(latin1Run.status == 1, "the gate cleared a file naming the Latin-1 needle itself: \(latin1Run.output)")
        #expect(!(foldedRun.output + latin1Run.output).contains("illegal byte sequence"), "a grep was handed a needle it cannot read: \(foldedRun.output)\(latin1Run.output)")
    }
}

/// The gate's temporary files, however its run ends.
///
/// Split out from the struct above for the same reason as the extensions before it.
extension PrivacyGateTests {
    /// Writes a `mktemp` that answers with numbered paths under the directory it returns, so every temporary file a run makes is that run's to count — `theGateRemovesEveryTemporaryFileItMade` says why a stub rather than `$TMPDIR`.
    ///
    /// The stub lands in the same `bin` as any written after it, so the environment `stubbing` returns for the next one serves both.
    private static func countingTemporaries(in root: URL) throws -> URL {
        let scratch = root.appending(path: "scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        _ = try stubbing(
            "mktemp",
            with: """
            #!/bin/sh
            n=0
            while [ -e "\(scratch.path)/tmp.$n" ]; do n=$((n + 1)); done
            : > "\(scratch.path)/tmp.$n"
            echo "\(scratch.path)/tmp.$n"

            """,
            in: root
        )

        return scratch
    }

    /// A run that `set -e` ends partway through still takes its temporary files away with it.
    ///
    /// Any command that fails under `set -e` ends the run where it stands, and the line that removed the files sat at the end of the script, where a stopped run never reached it — so it left all seven behind, named after nothing. Here `stat` fails on the file being checked, which the gate asks about only once every temporary file exists.
    @Test
    func aRunThatStopsPartwayRemovesEveryTemporaryFileItMade() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root)
        let document = root.appending(path: "document.txt")
        try "names nothing\n".write(to: document, atomically: true, encoding: .utf8)
        let scratch = try Self.countingTemporaries(in: root)
        let environment = try Self.stubbing(
            "stat",
            with: """
            #!/bin/sh
            case "$*" in
                *"\(document.path)"*) exit 1 ;;
            esac
            exec /usr/bin/stat "$@"

            """,
            in: root
        )

        let run = try Self.gateRun([document], invokedAt: subject, environment: environment)
        let left = try FileManager.default.contentsOfDirectory(atPath: scratch.path)

        #expect(run.status != 0 && !run.output.contains("verified:"), "the run was meant to stop partway, and finished: \(run.output)")
        #expect(left.isEmpty, "the stopped run left \(left.count) temporary file(s) behind")
    }

    /// A run stopped by a signal still takes its temporary files away with it.
    ///
    /// A shell killed by a signal it does not trap runs no `EXIT` trap at all, so removing the files on exit covers only half the ways a run stops: a push interrupted from the terminal, or a hook its client gives up on, would still leave all seven behind. Here `file`, which the gate calls once every temporary file exists, sends `TERM` to the process the test itself started — found by walking up from the stub to the one ancestor whose parent is the test's own pid, so the signal can only ever reach the gate this test started, never an ancestor a coincidental command line would misidentify. A trap that let the signal through would exit 143; the gate's own catches it and takes its temporary files with it.
    @Test
    func aRunStoppedByASignalRemovesEveryTemporaryFileItMade() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root)
        let document = root.appending(path: "document.txt")
        try "names nothing\n".write(to: document, atomically: true, encoding: .utf8)
        let scratch = try Self.countingTemporaries(in: root)
        var environment = try Self.stubbing(
            "file",
            with: """
            #!/bin/sh
            gate=""
            pid=$PPID
            while [ "$pid" -gt 1 ]; do
                ppid=$(ps -o ppid= -p "$pid" | tr -d ' ')
                if [ "$ppid" = "$GATE_TEST_PID" ]; then
                    gate=$pid
                    break
                fi
                pid=$ppid
            done
            [ -z "$gate" ] || kill -TERM "$gate"
            echo "ASCII text"

            """,
            in: root
        )
        environment["GATE_TEST_PID"] = String(ProcessInfo.processInfo.processIdentifier)

        let run = try Self.gateRun([document], invokedAt: subject, environment: environment)
        let left = try FileManager.default.contentsOfDirectory(atPath: scratch.path)

        #expect(!run.output.contains("verified:"), "the run was meant to be stopped by a signal, and finished: \(run.output)")
        #expect(run.status == 143, "a run the gate's own TERM trap caught should exit 143, exited \(run.status) instead")
        #expect(left.isEmpty, "the signalled run left \(left.count) temporary file(s) behind")
    }

    /// The walk over a directory does not take the temporary files away under the run that has still to read them.
    ///
    /// The walk runs in a pipeline's subshell, and the verdict is read off a file that subshell writes to, after it has ended. A subshell that inherited the `EXIT` trap would remove that file as the walk ended, and the verdict would find no finding in it — a directory naming a neighbour, cleared.
    @Test
    func aDirectoryHoldingAFileThatNamesANeighbourStillFails() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["Kestrel"])
        let tree = root.appending(path: "tree")
        try FileManager.default.createDirectory(at: tree.appending(path: "nested"), withIntermediateDirectories: true)
        try "names nothing\n".write(to: tree.appending(path: "clean.txt"), atomically: true, encoding: .utf8)
        try "mentions Kestrel\n".write(to: tree.appending(path: "nested/naming.txt"), atomically: true, encoding: .utf8)

        #expect(try !Self.gateClears(tree, invokedAt: subject), "the gate cleared a directory holding a file that names a neighbour")
    }
}

/// The public repository's own checkout, sitting beside this one.
extension PrivacyGateTests {
    /// The public repository is cut into a directory beside this checkout, named for the tool, and that directory is the project itself.
    ///
    /// Read as a neighbour, its name — the tool's own — would become a private one, and every file that names the tool would fail the gate on every push from then on. It is skipped only where the directory is named for the package this checkout declares and declares that package too; either half alone leaves it a name to look for.
    @Test
    func aCutOfThisPackageBesideTheCheckoutIsTheProjectAndNotANeighbour() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["Neighbour", "Gizmo", "GizmoCore", "Orchard"])
        let parent = subject.deletingLastPathComponent()
        let manifest = { (package: String) in "let package = Package(\n    name: \"\(package)\",\n    products: []\n)\n" }
        try manifest("Gizmo").write(to: subject.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try manifest("Gizmo").write(to: parent.appending(path: "Gizmo/Package.swift"), atomically: true, encoding: .utf8)
        try manifest("Gizmo").write(to: parent.appending(path: "GizmoCore/Package.swift"), atomically: true, encoding: .utf8)
        try manifest("Gizmo").write(to: parent.appending(path: "Orchard/Package.swift"), atomically: true, encoding: .utf8)

        let own = root.appending(path: "names-the-tool.txt")
        try "Gizmo is the tool this checkout builds.\n".write(to: own, atomically: true, encoding: .utf8)
        #expect(try Self.gateClears(own, invokedAt: subject))

        // Declaring the package under another directory name does not make that name the project's.
        let elsewhere = root.appending(path: "names-another-checkout.txt")
        try "GizmoCore holds a second copy.\n".write(to: elsewhere, atomically: true, encoding: .utf8)
        #expect(try !Self.gateClears(elsewhere, invokedAt: subject))
    }

    /// A neighbour that shares the tool's name but declares a package of its own is somebody else's project, and stays a name to look for.
    @Test
    func aNeighbourNamedLikeThePackageButDeclaringAnotherIsStillPrivate() throws {
        let root = try TemporaryDirectory.make("privacy-gate").appending(path: "privacy-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try Self.checkout(in: root, neighbours: ["Neighbour", "Gizmo"])
        let parent = subject.deletingLastPathComponent()
        try "let package = Package(\n    name: \"Gizmo\"\n)\n".write(to: subject.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try "let package = Package(\n    name: \"Orchard\"\n)\n".write(to: parent.appending(path: "Gizmo/Package.swift"), atomically: true, encoding: .utf8)

        let document = root.appending(path: "names-the-neighbour.txt")
        try "Gizmo is somebody else's.\n".write(to: document, atomically: true, encoding: .utf8)
        #expect(try !Self.gateClears(document, invokedAt: subject))
    }
}
