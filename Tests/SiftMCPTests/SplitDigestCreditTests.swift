//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A digest target holding several names is answered as each name's own digest, and the usage log records and credits it as those calls would be: every file a name served is located, the source its parts stand in for is counted, and a whole read of a served file is excused as it is after the separate calls.
@Suite(.temporaryDirectories)
struct SplitDigestCreditTests {
    private static var alpha: String {
        "Sources/App/Alpha.swift"
    }

    private static var beta: String {
        "Sources/App/Beta.swift"
    }

    /// The files of two modules, `A` and `B`, each holding a file named `Foo.swift` declaring a type of another name.
    private static var sameNamed: [String: String] {
        [
            beta: "struct Beta {\n    let two = 2\n}\n",
            "Package.swift": "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"Probe\", targets: [.target(name: \"A\"), .target(name: \"B\"), .target(name: \"App\")])\n",
            "Sources/A/Foo.swift": "struct Gizmo {\n    let one = 1\n}\n",
            "Sources/B/Foo.swift": "struct Depot {\n    let one = 1\n}\n",
            "Sources/B/Orchard.swift": "struct Orchard {\n    let one = 1\n}\n",
        ]
    }

    /// The type a name stands for, as the index resolves it, where the hook asks.
    private static func resolve(_ name: String, atRoot _: String) -> String? {
        ["Alpha": alpha, "Beta": beta, "Gizmo": "Sources/A/Foo.swift", "Depot": "Sources/B/Foo.swift", "Orchard": "Sources/B/Orchard.swift"][name]
    }

    /// A repository of two types in files named for them, with `files` added, or the one `shared` names as it stands, and the line the real server writes for a digest of `target` in it.
    private static func serve(
        _ target: String,
        files: [String: String] = [beta: "struct Beta {\n    let two = 2\n}\n"],
        in shared: URL? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> Served {
        let root = try shared ?? MCPTestRepo.make()
        if shared == nil {
            try MCPTestRepo.add(files, to: root)
        }
        let written = try TemporaryDirectory.make("split-credit").appendingPathComponent("usage.jsonl")
        let session = "split-credit-\(UUID().uuidString)"
        let toServer = Pipe()
        let fromServer = Pipe()
        let server = try MCPServer(
            input: toServer.fileHandleForReading,
            output: fromServer.fileHandleForWriting,
            defaultRoot: root,
            log: { _ in },
            usage: UsageLog(fileURL: written),
            callers: CallAttribution(directory: TemporaryDirectory.make("callers").appendingPathComponent("callers", isDirectory: true)),
            session: session
        )
        let task = Task { await server.run() }
        var responses = FileHandleLines.lines(from: fromServer.fileHandleForReading).makeAsyncIterator()
        var request = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "digest", "arguments": ["target": target]],
        ] as [String: Any])
        request.append(0x0A)
        toServer.fileHandleForWriting.write(request)
        let response = await responses.next()
        toServer.fileHandleForWriting.closeFile()
        _ = await task.value

        let reply = try #require(response, sourceLocation: sourceLocation)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any], sourceLocation: sourceLocation)
        let content = try #require((object["result"] as? [String: Any])?["content"] as? [[String: Any]], sourceLocation: sourceLocation)
        let text = try #require(content.first?["text"] as? String, sourceLocation: sourceLocation)
        let line = try #require(String(contentsOf: written, encoding: .utf8).split(separator: "\n").first, sourceLocation: sourceLocation)
        var entry = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], sourceLocation: sourceLocation)
        // The line as the server wrote it, filed under this test's own session: the server logs the one in the environment, which a run may not have.
        entry["session"] = session
        return try Served(root: root, entry: entry, log: DigestedFilesTests.UsageLogFile([entry]), session: session, text: text)
    }

    /// The reported defect: a split answer recorded neither the files it served nor the source it stood in for; it records what the separate calls would, the files located and the source stood in for, and each name's part.
    @Test(arguments: ["Alpha Sources/App/Beta.swift", "Sources/App/Beta.swift Alpha", "Sources/A/Foo.swift Depot", "B Sources/Z/Foo.swift"])
    func theUsageLineRecordsWhatTheSeparateCallsWould(target: String) async throws {
        let served = try await Self.serve(target, files: Self.sameNamed)
        var separate: [Served] = []
        for name in DigestSpacedTarget.names(in: target) {
            try await separate.append(Self.serve(name, files: Self.sameNamed))
        }

        let located = Set(separate.flatMap { $0.entry["located"] as? [String] ?? [] })
        #expect(Set(served.entry["located"] as? [String] ?? []) == located)
        let sources = separate.compactMap { $0.entry["srcBytes"] as? Int }
        #expect(served.entry["srcBytes"] as? Int == (sources.isEmpty ? nil : sources.reduce(0, +)))
        // A name the split answer says it did not serve has no part, as a name it did serve has one.
        let answered = DigestSpacedTarget.names(in: target).filter { !served.text.contains("\($0) was not served") }
        #expect((served.entry["parts"] as? [[String: Any]])?.compactMap { $0["target"] as? String } == answered)
        #expect(served.entry["target"] as? String == target)
    }

    /// The hook credits each served file a whole read as it does after the separate single-target calls, whichever order the names came in.
    @Test(arguments: ["Alpha Sources/App/Beta.swift", "Sources/App/Beta.swift Alpha"])
    func aWholeReadOfEachServedFileIsCreditedAsAfterTheSeparateCalls(target: String) async throws {
        let served = try await Self.serve(target)
        let digested = served.log.digested

        for path in [Self.alpha, Self.beta] {
            #expect(digested.contains(served.file(path), session: served.session, agent: nil, resolve: Self.resolve), "\(path)")
            #expect(digested.locates(served.file(path), session: served.session, agent: nil, resolve: Self.resolve), "\(path)")
        }
    }

    /// A name whose own digest excuses no whole read of a file still does not once it is one of several: a member of a type, and a module that lists a file under a heading.
    @Test(arguments: ["Alpha.go Sources/App/Beta.swift", "Sources Sources/App/Beta.swift"])
    func aNameThatServedNoWholeDigestOfAFileDoesNotExcuseItsWholeRead(target: String) async throws {
        let served = try await Self.serve(target)
        let digested = served.log.digested

        #expect(digested.contains(served.file(Self.beta), session: served.session, agent: nil, resolve: Self.resolve))
        #expect(!digested.contains(served.file(Self.alpha), session: served.session, agent: nil, resolve: Self.resolve))
    }

    /// The transcript scan is never more generous than the hook: whatever it credits from the answer a split call was served, the hook credits from the line the same call wrote, two files of one name in two modules among them.
    @Test(arguments: [
        "Alpha Sources/App/Beta.swift", "Sources/App/Beta.swift Alpha", "Alpha Phantom",
        "Sources/A/Foo.swift Depot", "Depot Sources/A/Foo.swift", "Sources/A/Foo.swift B", "B Sources/A/Foo.swift",
        "Sources/Z/Foo.swift B", "B Sources/Z/Foo.swift", "Depot Sources/Z/Foo.swift", "Sources/Q/Orchard.swift Alpha",
    ])
    func theScanCreditsNoFileTheHookDoesNot(target: String) async throws {
        let served = try await Self.serve(target, files: Self.sameNamed)
        let digested = served.log.digested
        let credited = LocatedDigest.credited(targets: [target], whole: true, answer: served.text, anchor: served.root.path)

        for path in Self.fixturePaths {
            let scan = credited.contains { $0.covers(served.file(path), in: served.root.path, whole: true, resolve: Self.resolve) }
            let hook = digested.contains(served.file(path), session: served.session, agent: nil, resolve: Self.resolve)
            #expect(!scan || hook, "\(path)")
        }
    }

    /// The reviewed defects: a path naming another module's file of the same name excused a whole read of every located file of that name, a module's listing included, and a type's part located the file its header cites for a window, though no name's own digest would have done either.
    @Test(arguments: [
        "Sources/A/Foo.swift Depot", "Depot Sources/A/Foo.swift",
        "Sources/A/Foo.swift B", "B Sources/A/Foo.swift",
        "Sources/Z/Foo.swift B", "B Sources/Z/Foo.swift",
    ])
    func aReadOfAnyWidthIsCreditedExactlyAsAfterTheSeparateCalls(target: String) async throws {
        try await Self.expectSeparateCallsVerdict(target)
    }

    /// The credit the separate calls give is kept: a path's own file, and the file served in place of a path that names none.
    @Test(arguments: [
        ("Sources/A/Foo.swift Alpha", "Sources/A/Foo.swift"),
        ("Alpha Sources/A/Foo.swift", "Sources/A/Foo.swift"),
        ("Sources/Q/Orchard.swift Alpha", "Sources/B/Orchard.swift"),
    ])
    func aPathNameStillCreditsTheFileItServed(target: String, path: String) async throws {
        let served = try await Self.serve(target, files: Self.sameNamed)

        #expect(served.log.digested.contains(served.file(path), session: served.session, agent: nil, resolve: Self.resolve))
        try await Self.expectSeparateCallsVerdict(target)
    }

    /// The reported defect: a name digesting some of a file's lines, beside another name, left a later window of that file answered and a withheld answer noted, where the separate calls let it through as no lookup, since the separate range call is credited by the advice ledger and the split string the ledger notes names no file.
    @Test(arguments: [
        "Sources/B/Foo.swift:12-40 Orchard", "Orchard Sources/B/Foo.swift:12-40",
        "Sources/B/Orchard.swift:5 Depot", "Depot Sources/B/Orchard.swift:5",
        "Sources/B/Catalogue.swift:3-9 Depot", "Depot Sources/B/Catalogue.swift:3-9",
    ])
    func aRangeNameCreditsAWindowAsTheSeparateCallsDo(target: String) async throws {
        let split = try await Self.hookVerdicts(after: [target], files: Self.ranged)
        let separate = try await Self.hookVerdicts(after: DigestSpacedTarget.names(in: target), files: Self.ranged)

        #expect(split == separate)
    }
}

extension SplitDigestCreditTests {
    /// Every Swift file of the two-module fixture, whose whole reads the pins above ask about.
    private static var fixturePaths: [String] {
        [alpha] + sameNamed.keys.filter { $0.hasPrefix("Sources/") }.sorted()
    }

    /// Expects the hook's verdicts on a later read of every file of the two-module fixture, whole and windowed, after a split digest of `target`, to be the verdicts after a digest of each of its names on its own.
    private static func expectSeparateCallsVerdict(_ target: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let split = try await serve(target, files: sameNamed, sourceLocation: sourceLocation)
        var separate: [Served] = []
        for name in DigestSpacedTarget.names(in: target) {
            try await separate.append(serve(name, files: sameNamed, sourceLocation: sourceLocation))
        }
        for path in fixturePaths {
            let baseline = separate.contains { $0.log.digested.contains($0.file(path), session: $0.session, agent: nil, resolve: resolve) }
            let verdict = split.log.digested.contains(split.file(path), session: split.session, agent: nil, resolve: resolve)
            #expect(verdict == baseline, "whole read of \(path)", sourceLocation: sourceLocation)
            let windowBaseline = separate.contains { $0.log.digested.locates($0.file(path), session: $0.session, agent: nil, resolve: resolve) }
            let window = split.log.digested.locates(split.file(path), session: split.session, agent: nil, resolve: resolve)
            #expect(window == windowBaseline, "window of \(path)", sourceLocation: sourceLocation)
        }
        let hookSplit = try await hookVerdicts(after: [target], files: ranged, sourceLocation: sourceLocation)
        let hookSeparate = try await hookVerdicts(after: DigestSpacedTarget.names(in: target), files: ranged, sourceLocation: sourceLocation)
        #expect(hookSplit == hookSeparate, sourceLocation: sourceLocation)
    }

    /// The two-module fixture with lines enough in every file for a digest of some of them and a read the hook weighs, and one more file in module `B` named for no type it declares.
    private static var ranged: [String: String] {
        let body = (1 ... 44).map { "    let line\($0) = \($0)" }.joined(separator: "\n")
        return [
            alpha: "struct Alpha {\n\(body)\n}\n",
            beta: "struct Beta {\n\(body)\n}\n",
            "Package.swift": sameNamed["Package.swift"] ?? "",
            "Sources/A/Foo.swift": "struct Gizmo {\n\(body)\n}\n",
            "Sources/B/Foo.swift": "struct Depot {\n\(body)\n}\n",
            "Sources/B/Orchard.swift": "struct Orchard {\n\(body)\n}\n",
            "Sources/B/Catalogue.swift": "extension Depot {\n\(body)\n}\n",
        ]
    }

    /// The hook's verdict line and the suppressions it wrote on a window and on a whole read of every Swift file of `files`, each judged afresh, after a digest of each of `targets` in one repository and session, noted on the usage log as the server writes it and in the advice ledger as the hook does.
    private static func hookVerdicts(after targets: [String], files: [String: String], sourceLocation: SourceLocation = #_sourceLocation) async throws -> [String] {
        let root = try MCPTestRepo.make()
        try MCPTestRepo.add(files, to: root)
        let session = "split-hook-\(UUID().uuidString)"
        var entries: [[String: Any]] = []
        for target in targets {
            var entry = try await serve(target, in: root, sourceLocation: sourceLocation).entry
            entry["session"] = session
            entries.append(entry)
        }
        let usage = try DigestedFilesTests.UsageLogFile(entries)
        let context = AdviceContext.resolve(sessionID: session, transcriptPath: nil, agentID: "")
        let paths = Set(files.keys.filter { $0.hasPrefix("Sources/") }).union([alpha]).sorted()
        var verdicts: [String] = []
        for path in paths {
            for windowed in [true, false] {
                let ledger = try AdviceLedger(directory: TemporaryDirectory.make("split-ledger"))
                for target in targets {
                    _ = try PreToolUseCommand.adviceTaken(
                        session: session,
                        context: context,
                        payload: ["tool_name": IndexToolName.prefix + "digest", "tool_input": ["target": target]],
                        cwd: root.path,
                        ledger: ledger,
                        callers: CallAttribution(directory: TemporaryDirectory.make("split-callers"))
                    )
                }
                var input: [String: Any] = ["file_path": root.appendingPathComponent(path).path]
                if windowed {
                    input["offset"] = 2
                    input["limit"] = 1
                }
                let payload: [String: Any] = ["session_id": session, "tool_name": "Read", "tool_input": input, "tool_use_id": "toolu_split"]
                let recording = try AdviceAgreementTests.Recording()
                defer { recording.cleanup() }
                var line = PreToolUseCommand.Verdict(token: "allowed", rule: "noLookup").line
                if let lookup = PreToolUseCommand.lookup(
                    command: nil,
                    payload: payload,
                    in: root.path,
                    noting: recording.log,
                    digested: usage.digested,
                    couldAnswer: { _, _ in true },
                    resolvingDigests: resolve
                ) {
                    line = try PreToolUseCommand.outcome(
                        to: lookup,
                        session: session,
                        context: context,
                        payload: payload,
                        cwd: root.path,
                        ledger: ledger,
                        usage: UsageLog(fileURL: TemporaryDirectory.make("split-usage").appendingPathComponent("usage.jsonl")),
                        suppressions: recording.log,
                        answerer: { _, _, _ in .withheld(.linesNotShown) },
                        couldAnswer: { _, _ in true }
                    ).verdict.line
                }
                verdicts.append("\(windowed ? "window" : "whole read") of \(path): \(line) \(recording.rules)")
            }
        }
        return verdicts
    }

    /// What one split digest wrote: the repository, the usage line, the session it was logged under and the text the caller was served.
    struct Served {
        let root: URL
        let entry: [String: Any]
        let log: DigestedFilesTests.UsageLogFile
        let session: String
        let text: String

        func file(_ path: String) -> String {
            root.appendingPathComponent(path).path
        }
    }
}
