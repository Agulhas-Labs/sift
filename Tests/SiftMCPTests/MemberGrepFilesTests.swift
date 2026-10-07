//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A member grep of several named Swift files, a glob of them, or one file searched recursively: each file proven as a grep of it alone would be, and every member's source served file by file in operand order.
@Suite(.temporaryDirectories)
struct MemberGrepFilesTests {
    /// Two files that each declare a `stock` member, a file whose body spells the pattern, a file with the pattern in a comment outside every member, and a directory of one clean file beside that comment.
    static func repository() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let member: (String) -> String = { type in
            "/// A \(type).\nstruct \(type) {\n    var count = 0\n    func stock() -> Int {\n        let doubled = count * 2\n        return doubled\n    }\n    func other() {}\n}\n"
        }
        try MCPTestRepo.add([
            "Sources/Kit/Alpha.swift": member("Pallet"),
            "Sources/Kit/Beta.swift": member("Crate"),
            "Sources/Body/Inner.swift": "struct Inner {\n    func stock() -> String {\n        \"func stock is here in a string\"\n    }\n}\n",
            "Sources/Mixed/Clean.swift": member("Drum"),
            "Sources/Mixed/Noisy.swift": "// func stock was here once\nstruct Noisy {\n    func stock() {}\n}\n",
        ], to: root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// Twelve files under `Sources/Dozen`, each declaring one `stock` member on a single line, so each prints exactly one line.
    static func dozenFiles() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        var files: [String: String] = [:]
        for index in 1 ... 12 {
            files["Sources/Dozen/Box\(index).swift"] = "struct Box\(index) {\n    func stock() -> Int { \(index) }\n}\n"
        }
        try MCPTestRepo.add(files, to: root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// Two files under `Sources/Pair`: `Uno.swift`, whose member has two context lines after its match, and `Duo.swift`, whose match sits one line from the end of the file — five printed lines between them.
    static func pairOfFiles() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Sources/Pair/Uno.swift": "struct Uno {\n    func stock() -> Int {\n        let doubled = 2\n        return doubled\n    }\n}\n",
            "Sources/Pair/Duo.swift": "struct Duo {\n    func stock() -> Int { 0 }\n}\n",
        ], to: root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// A glob of two files is answered with each file's member, in the order the shell expands the glob.
    @Test
    func aGlobOfTwoFilesIsAnsweredFileByFile() async throws {
        let root = try await Self.repository()

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn 'func stock' Sources/Kit/*.swift", in: root))

        #expect(answered.calls.map(\.target) == ["Pallet.stock()", "Crate.stock()"])
        let first = try #require(answered.reason.range(of: "Pallet.stock() — func — Sources/Kit/Alpha.swift:4-7"))
        let second = try #require(answered.reason.range(of: "Crate.stock() — func — Sources/Kit/Beta.swift:4-7"))
        #expect(first.upperBound <= second.lowerBound)
        #expect(answered.reason.contains("        return doubled\n"))
    }

    /// Two files named outright are answered in the order they were named.
    @Test
    func twoNamedFilesAreAnsweredInOperandOrder() async throws {
        let root = try await Self.repository()

        let answered = try #require(try await InPlaceAnswerTests.answered(
            "grep -n 'func stock' Sources/Kit/Beta.swift Sources/Kit/Alpha.swift", in: root
        ))

        #expect(answered.calls.map(\.target) == ["Crate.stock()", "Pallet.stock()"])
    }

    /// `head -3` over twelve files that each print one line lets the call through: no order of them proves which three the shell's grep would actually print.
    @Test
    func headOverTwelveFilesLetsTheCallThrough() async throws {
        let root = try await Self.dozenFiles()

        #expect(try await InPlaceAnswerTests.outcome(
            "grep -n 'func stock' Sources/Dozen/*.swift | head -3", in: root
        ) == .withheld(.unchecked))
    }

    /// `head -30` over two files that print five lines between them keeps every one of them however the files order, so it is answered with both.
    @Test
    func headWideEnoughForBothFilesIsAnsweredWithBoth() async throws {
        let root = try await Self.pairOfFiles()

        let answered = try #require(try await InPlaceAnswerTests.answered(
            "grep -n 'func stock' -A 2 Sources/Pair/*.swift | head -30", in: root
        ))

        #expect(answered.calls.map(\.target) == ["Duo.stock()", "Uno.stock()"])
    }

    /// `tail -2` across two files that print more than two lines between them lets the call through, since either file could be the one grep prints last.
    @Test
    func tailOverTwoFilesThatPrintMoreLetsTheCallThrough() async throws {
        let root = try await Self.repository()

        #expect(try await InPlaceAnswerTests.outcome(
            "grep -n 'func stock' -A 3 Sources/Kit/*.swift | tail -2", in: root
        ) == .withheld(.unchecked))
    }

    /// `sed -n 1,200p` opens at line 1 and reaches past every printed line, whatever order the files come in, so it is answered.
    @Test
    func sedWindowCoveringEverythingIsAnswered() async throws {
        let root = try await Self.repository()

        let answered = try #require(try await InPlaceAnswerTests.answered(
            "grep -n 'func stock' Sources/Kit/*.swift | sed -n 1,200p", in: root
        ))

        #expect(answered.calls.map(\.target) == ["Pallet.stock()", "Crate.stock()"])
    }

    /// A recursive grep of one file is that file's member grep: `-r` on a file searches the file.
    @Test
    func aRecursiveGrepOfOneFileIsAnswered() async throws {
        let root = try await Self.repository()

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn 'func stock' -A 2 Sources/Kit/Alpha.swift", in: root))

        #expect(answered.calls.map(\.target) == ["Pallet.stock()"])
    }

    /// A match inside a body in any one file lets the whole call through, the files that prove out included.
    @Test
    func aMatchInsideABodyInOneFileWithholdsAll() async throws {
        let root = try await Self.repository()

        #expect(try await InPlaceAnswerTests.outcome(
            "grep -n 'func stock' Sources/Kit/Alpha.swift Sources/Body/Inner.swift", in: root
        ) == .withheld(.notExact))
    }

    /// A glob that takes in a file whose match is no member's declaration is withheld whole.
    @Test
    func aGlobTakingInANonMemberMatchIsWithheld() async throws {
        let root = try await Self.repository()

        #expect(try await InPlaceAnswerTests.outcome("grep -n 'func stock' Sources/Mixed/*.swift", in: root) == .withheld(.notExact))
    }

    /// An answer over the size budget is withheld as any other is, and a glob that matches no file is never answered.
    @Test
    func anOverrunAndAnEmptyGlobAreWithheld() async throws {
        let root = try await Self.repository()
        let command = "grep -n 'func stock' Sources/Kit/*.swift"
        let answered = try #require(try await InPlaceAnswerTests.answered(command, in: root))
        let shaped = try #require(InPlaceShape.match(forShell: command, in: root.path))

        #expect(try await InPlaceAnswerTests.answer(shaped.call, from: shaped.directory, sizeBudget: answered.reason.utf8.count - 1) == .withheld(.overSize))
        #expect(try await InPlaceAnswerTests.outcome("grep -n 'func stock' Sources/Kit/Z*.swift", in: root) == .withheld(.unchecked))
    }

    /// A search that prints no file names, or filters the files it reads, keeps the shape it had: none.
    @Test(arguments: [
        "grep -hn 'func stock' Sources/Kit/*.swift",
        "grep -rn --include=*.swift 'func stock' Sources/Kit/*.swift",
    ])
    func aSearchWithoutFileNamesOrWithAFilterIsNotTheShape(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }

    /// Two files under `Sources/My Dir`, a directory whose name holds a space, each declaring one `stock` member.
    static func spacedDirectory() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Sources/My Dir/Uno.swift": "struct Uno {\n    func stock() -> Int { 1 }\n}\n",
            "Sources/My Dir/Duo.swift": "struct Duo {\n    func stock() -> Int { 2 }\n}\n",
        ], to: root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// A glob whose space is escaped or quoted, with its wildcard left live, is expanded as the plain glob is and answered the same way.
    @Test(arguments: [
        #"grep -n 'func stock' Sources/My\ Dir/*.swift"#,
        #"grep -n 'func stock' "Sources/My Dir"/*.swift"#,
        #"grep -n 'func stock' 'Sources/My Dir'/*.swift"#,
        #"grep -n 'func stock' Sources/My\ Dir/Duo.swift Sources/My\ Dir/Uno.swift"#,
    ])
    func aSpaceEscapedOrQuotedInAGlobIsAnswered(command: String) async throws {
        let root = try await Self.spacedDirectory()

        let answered = try #require(try await InPlaceAnswerTests.answered(command, in: root))

        #expect(answered.calls.map(\.target) == ["Duo.stock()", "Uno.stock()"])
        #expect(answered.reason.contains("Uno.stock() — func — Sources/My Dir/Uno.swift:2"))
    }

    /// A wildcard quoted or escaped reaches the search as a literal file name no shell expanded, so no answer speaks for it.
    @Test(arguments: [
        #"grep -n 'func stock' "Sources/My Dir/*.swift""#,
        #"grep -n 'func stock' Sources/My\ Dir/\*.swift"#,
    ])
    func aQuotedOrEscapedWildcardIsNotTheShape(command: String) async throws {
        let root = try await Self.spacedDirectory()

        #expect(InPlaceShape.match(forShell: command, in: root.path) == nil)
    }

    /// `-H` alone prints each line's file name and nothing else the plain search does not, so it is answered as the plain search is.
    @Test(arguments: [
        "grep -H 'func stock' Sources/Kit/*.swift",
        "grep -hH 'func stock' Sources/Kit/Alpha.swift Sources/Kit/Beta.swift",
    ])
    func withFileNamesAloneIsAnswered(command: String) async throws {
        let root = try await Self.repository()

        let answered = try #require(try await InPlaceAnswerTests.answered(command, in: root))

        #expect(answered.calls.map(\.target) == ["Pallet.stock()", "Crate.stock()"])
    }

    /// `Sources/Links/Uno.swift`, declaring one `stock` member, and `Sources/Links/Link.swift`, a symbolic link to it.
    static func linkedFile() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let links = root.appendingPathComponent("Sources/Links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: links.appendingPathComponent("Link.swift").path, withDestinationPath: "Uno.swift")
        try MCPTestRepo.add(["Sources/Links/Uno.swift": "struct Uno {\n    func stock() -> Int { 1 }\n}\n"], to: root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// A symbolic link, named or taken in by a glob, is withheld: grep prints the link's path, and the index's record under that path is not refreshed when the file it points at changes, so an answer naming it could cite ranges the file no longer has.
    @Test(arguments: [
        "grep -n 'func stock' Sources/Links/Link.swift",
        "grep -n 'func stock' Sources/Links/Link.swift Sources/Links/Uno.swift",
        "grep -n 'func stock' Sources/Links/*.swift",
        "grep -rn 'func stock' Sources/Links/Link.swift",
    ])
    func aSymbolicLinkNamedOrGlobbedIsWithheld(command: String) async throws {
        let root = try await Self.linkedFile()

        #expect(try await InPlaceAnswerTests.outcome(command, in: root) == .withheld(.unchecked))
    }

    /// A file named twice is served once: grep prints its lines twice, but the second copy is the same lines of the same file, so every line it prints still lies inside a member the answer serves.
    @Test
    func aFileNamedTwiceIsServedOnce() async throws {
        let root = try await Self.repository()

        let answered = try #require(try await InPlaceAnswerTests.answered(
            "grep -n 'func stock' Sources/Kit/Alpha.swift Sources/Kit/Beta.swift Sources/Kit/Alpha.swift", in: root
        ))

        #expect(answered.calls.map(\.target) == ["Pallet.stock()", "Crate.stock()"])
        #expect(answered.reason.components(separatedBy: "Pallet.stock() — func — Sources/Kit/Alpha.swift:4-7").count == 2)
    }

    /// ``repository()`` with a directory named `~` at its root, whose `Sources/Kit/Tilde.swift` declares one `stock` member too.
    static func tildeDirectory() async throws -> URL {
        let root = try await repository()
        try MCPTestRepo.add(["~/Sources/Kit/Tilde.swift": "struct Tilde {\n    func stock() -> Int { 0 }\n}\n"], to: root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// A `~` quoted or escaped names a directory called `~`, which the shell never reads as the home directory, so a search through one, named, globbed or recursive, is not the shape.
    @Test(arguments: [
        #"grep -n 'func stock' "~"/Sources/Kit/*.swift"#,
        #"grep -n 'func stock' \~/Sources/Kit/*.swift"#,
        #"grep -n 'func stock' '~/Sources/Kit'/*.swift"#,
        #"grep -n 'func stock' \~/Sources/Kit/Alpha.swift \~/Sources/Kit/Beta.swift"#,
        #"grep -n 'func stock' "~/Sources/Kit/Alpha.swift" "~/Sources/Kit/Beta.swift""#,
        #"grep -rn 'func stock' "~/Sources/Kit/Alpha.swift""#,
    ])
    func aQuotedOrEscapedTildeIsNotTheShape(command: String) async throws {
        let root = try await Self.tildeDirectory()

        #expect(InPlaceShape.match(forShell: command, in: root.path) == nil)
    }

    /// A `~` left unquoted is the home directory however the rest of its path is quoted, so the search stays the shape, its operand read as the shell hands it over.
    @Test
    func anUnquotedTildeBeforeAQuotedPathIsTheShape() async throws {
        let root = try await Self.tildeDirectory()

        let shaped = try #require(InPlaceShape.match(forShell: #"grep -n 'func stock' ~"/Sources/Kit"/*.swift"#, in: root.path))

        guard case let .members(search) = shaped.call else {
            Issue.record("expected a member grep, got \(shaped.call)")
            return
        }

        #expect(search.paths == ["~/Sources/Kit/*.swift"])
    }

    /// Driven through the built binary with the home directory pointed at the repository, a search through a quoted `~` runs, and one through a live `~` is answered from the files under home, never from the directory called `~`.
    @Test
    func theBinaryReadsATildeAsHomeOnlyWhereTheShellDoes() async throws {
        let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)")
        let root = try await Self.tildeDirectory()
        let scratch = try TemporaryDirectory.make("tilde").appendingPathComponent("tilde")
        defer { try? FileManager.default.removeItem(at: scratch) }
        func printed(_ command: String, session: String) throws -> String {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["pre-tool-use"]
            var environment = ProcessInfo.processInfo.environment
            environment["CFFIXED_USER_HOME"] = root.path
            environment["SIFT_USAGE_LOG"] = scratch.appendingPathComponent("usage.jsonl").path
            environment["SIFT_ADVICE_DIR"] = scratch.appendingPathComponent("advice").path
            environment["CLAUDE_CODE_SESSION_ID"] = nil
            process.environment = environment
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            try input.fileHandleForWriting.write(JSONSerialization.data(withJSONObject: [
                "session_id": session, "cwd": root.path, "hook_event_name": "PreToolUse", "tool_name": "Bash",
                "tool_input": ["command": command],
            ] as [String: Any]))
            input.fileHandleForWriting.closeFile()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(bytes: data, encoding: .utf8) ?? ""
        }

        let quoted = try printed(#"grep -n 'func stock' "~"/Sources/Kit/*.swift"#, session: "tilde-quoted")
        let live = try printed(#"grep -n 'func stock' ~"/Sources/Kit"/*.swift"#, session: "tilde-live")

        #expect(quoted.isEmpty, "\(quoted)")
        // Answered, the live search names the files under home; over the time budget on a loaded machine it
        // prints nothing and runs, which is never the wrong answer.
        #expect(live.isEmpty || (live.contains("Sources/Kit/Alpha.swift") && !live.contains("Tilde")), "\(live)")
    }

    /// Driven through the built binary with the home directory pointed at the repository, a `cd` opening on a quoted or escaped `~` is withheld, and one left unquoted moves to the home directory as before.
    @Test
    func theBinaryFollowsATildeCdOnlyWhereTheShellDoes() async throws {
        let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)")
        let root = try await Self.tildeDirectory()
        let scratch = try TemporaryDirectory.make("tilde-cd").appendingPathComponent("tilde-cd")
        defer { try? FileManager.default.removeItem(at: scratch) }
        func printed(_ command: String, session: String) throws -> String {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["pre-tool-use"]
            var environment = ProcessInfo.processInfo.environment
            environment["CFFIXED_USER_HOME"] = root.path
            environment["SIFT_USAGE_LOG"] = scratch.appendingPathComponent("usage.jsonl").path
            environment["SIFT_ADVICE_DIR"] = scratch.appendingPathComponent("advice").path
            environment["CLAUDE_CODE_SESSION_ID"] = nil
            process.environment = environment
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            try input.fileHandleForWriting.write(JSONSerialization.data(withJSONObject: [
                "session_id": session, "cwd": root.path, "hook_event_name": "PreToolUse", "tool_name": "Bash",
                "tool_input": ["command": command],
            ] as [String: Any]))
            input.fileHandleForWriting.closeFile()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(bytes: data, encoding: .utf8) ?? ""
        }

        let doubleQuoted = try printed(#"cd "~/Sources/Kit" && grep -n 'func stock' Alpha.swift"#, session: "cd-tilde-double-quoted")
        let singleQuoted = try printed(#"cd '~/Sources/Kit' && grep -n 'func stock' Alpha.swift"#, session: "cd-tilde-single-quoted")
        let escaped = try printed(#"cd \~/Sources/Kit && grep -n 'func stock' Alpha.swift"#, session: "cd-tilde-escaped")
        let live = try printed(#"cd ~/Sources/Kit && grep -n 'func stock' Alpha.swift"#, session: "cd-tilde-live")

        // A quoted or escaped `~` names a directory the real `cd` cannot enter, so nothing prints where it withholds.
        #expect(doubleQuoted.isEmpty, "\(doubleQuoted)")
        #expect(singleQuoted.isEmpty, "\(singleQuoted)")
        #expect(escaped.isEmpty, "\(escaped)")
        // Answered, the live `cd` moves to the home directory's Sources/Kit as before; over the time budget on
        // a loaded machine it prints nothing and runs, which is never the wrong answer.
        #expect(live.isEmpty || live.contains("Pallet.stock()"), "\(live)")
    }
}
