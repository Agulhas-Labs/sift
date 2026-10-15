//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The `PostToolUse` hook locates the diagnostics a `Grep` or `Bash` call printed, so the next turn is not spent asking which function a line is in.
@Suite(.temporaryDirectories)
struct DiagnosticNoteTests {
    /// The file the diagnostics are in, as the repository holds it: line 6 is inside `restock(_:)`, which spans lines 4 to 8.
    static var producer: String {
        """
        import Foundation

        struct Producer {
            func restock(_ lengths: [Int]) -> Int {
                let total = lengths.reduce(0, +)
                let broken = total + "x"
                return broken
            }
        }

        """
    }

    static var producerPath: String {
        "Sources/Orchard/Logic/Producer.swift"
    }

    /// A repository holding ``producer``, and the hook's answer to `payload` run in it.
    func answer(_ make: (String) -> [String: Any], extraFiles: [String: String] = [:]) throws -> String {
        let repo = try MCPTestRepo.make(declaring: "Depot")
        try MCPTestRepo.add([Self.producerPath: Self.producer].merging(extraFiles) { first, _ in first }, to: repo)
        let marks = try ReuseNudgeMarks(directory: TemporaryDirectory.make("nudge-marks"))
        let recorded = RecordedOutput()
        PostToolUseCommand.answer(to: make(repo.path), output: recorded.output, marks: marks)
        return recorded.printed
    }

    static func grep(_ content: String, cwd: String) -> [String: Any] {
        ["tool_name": "Grep", "tool_input": ["pattern": "error:"], "tool_response": ["mode": "content", "content": content], "session_id": "s1", "cwd": cwd]
    }

    static func bash(_ stdout: String, cwd: String) -> [String: Any] {
        ["tool_name": "Bash", "tool_input": ["command": "grep error: build.log"], "tool_response": ["stdout": stdout, "stderr": ""], "session_id": "s1", "cwd": cwd]
    }

    static func context(of printed: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let object = try #require(JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any], sourceLocation: sourceLocation)
        let output = try #require(object["hookSpecificOutput"] as? [String: Any], sourceLocation: sourceLocation)
        return try #require(output["additionalContext"] as? String, sourceLocation: sourceLocation)
    }

    static var expected: String {
        """
        sift: the diagnostics above, located:
          \(producerPath):6 — in Producer.restock(_:) :4-8
            4|     func restock(_ lengths: [Int]) -> Int {
            5|         let total = lengths.reduce(0, +)
          > 6|         let broken = total + "x"
            7|         return broken
            8|     }
        """
    }

    @Test func aGrepOfAnotherMachinesPathNamesTheEnclosingFunctionAndTheNumberedLine() throws {
        let foreign = "/Users/runner/work/x/x/Sources/Orchard/Logic/Producer.swift:6:25: error: binary operator '+' cannot be applied"
        let printed = try answer { Self.grep(foreign, cwd: $0) }

        #expect(try Self.context(of: printed) == Self.expected)
    }

    @Test func anAbsolutePathToARealFileOutsideTheRepositoryIsNotLocatedInTheRepositorysFile() throws {
        let other = try TemporaryDirectory.make("other-checkout")
        let file = other.appendingPathComponent(Self.producerPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "struct Other {\n    func one() {}\n}\n".write(to: file, atomically: true, encoding: .utf8)
        let printed = try answer { Self.grep("\(file.path):6:25: error: binary operator '+' cannot be applied", cwd: $0) }

        #expect(printed.isEmpty)
    }

    @Test func aRelativePathToARealFileOutsideTheRepositoryIsNotLocatedInTheRepositorysFile() throws {
        let other = try TemporaryDirectory.make("other-checkout")
        let file = other.appendingPathComponent(Self.producerPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "struct Other {\n    func one() {}\n}\n".write(to: file, atomically: true, encoding: .utf8)
        let printed = try answer {
            let climb = String(repeating: "../", count: URL(fileURLWithPath: $0).pathComponents.count)
            return Self.grep("\(climb)\(file.path.dropFirst()):6:25: error: binary operator '+' cannot be applied", cwd: $0)
        }

        #expect(printed.isEmpty)
    }

    @Test func aBashCallsStdoutIsReadTheSame() throws {
        let foreign = "/Users/runner/work/x/x/Sources/Orchard/Logic/Producer.swift:6:25: error: binary operator '+' cannot be applied"
        let printed = try answer { Self.bash(foreign, cwd: $0) }

        #expect(try Self.context(of: printed) == Self.expected)
    }

    @Test func aPathInsideTheRepositoryIsMadeRelativeToIt() throws {
        let printed = try answer { Self.grep("\($0)/\(Self.producerPath):6:25: warning: x", cwd: $0) }

        #expect(try Self.context(of: printed) == Self.expected)
    }

    @Test func aRelativePathResolvesAgainstTheWorkingDirectory() throws {
        let printed = try answer { Self.grep("Logic/Producer.swift:6:25: error: x", cwd: $0 + "/Sources/Orchard") }

        #expect(try Self.context(of: printed) == Self.expected)
    }

    @Test func outputWithNoSwiftLocationDrawsNothing() throws {
        let printed = try answer { Self.bash("error: the build failed\n" + String(repeating: "noise\n", count: 1000), cwd: $0) }

        #expect(printed.isEmpty)
    }

    @Test func aPathTwoFilesEndTheSameWayIsSkipped() throws {
        let extra = [
            "Alpha/Sources/Shared/Twin.swift": "struct Gizmo {\n    func go() {}\n}\n",
            "Beta/Sources/Shared/Twin.swift": "struct Catalogue {\n    func go() {}\n}\n",
        ]
        let printed = try answer({ Self.grep("/ci/work/Sources/Shared/Twin.swift:2:5: error: x", cwd: $0) }, extraFiles: extra)

        #expect(printed.isEmpty)
    }

    @Test func aLongerSharedSuffixSeparatesTwoFilesOfOneName() throws {
        let extra = [
            "Alpha/Sources/Shared/Twin.swift": "struct Gizmo {\n    func go() {}\n}\n",
            "Beta/Sources/Shared/Twin.swift": "struct Catalogue {\n    func go() {}\n}\n",
        ]
        let printed = try answer({ Self.grep("/ci/work/Beta/Sources/Shared/Twin.swift:2:5: error: x", cwd: $0) }, extraFiles: extra)

        #expect(try Self.context(of: printed).contains("Beta/Sources/Shared/Twin.swift:2 — in Catalogue.go() :2"))
    }

    @Test func aLinePastTheEndOfTheFileIsSkipped() throws {
        let printed = try answer { Self.grep("/ci/Sources/Orchard/Logic/Producer.swift:400:1: error: x", cwd: $0) }

        #expect(printed.isEmpty)
    }

    @Test func sixDistinctSitesAreFiveLines() throws {
        let sites = (4 ... 9).map { "/ci/Sources/Orchard/Logic/Producer.swift:\($0):1: error: x" }
        let printed = try answer { Self.grep(sites.joined(separator: "\n") + "\n" + sites[0], cwd: $0) }

        let note = try Self.context(of: printed)

        #expect(note.components(separatedBy: "\n").filter { $0.hasPrefix("  \(Self.producerPath):") }.count == 5)
        #expect(!note.contains("Producer.swift:9"))
    }

    @Test func aWritePayloadIsNotReadForDiagnostics() throws {
        let payload: (String) -> [String: Any] = { cwd in
            ["tool_name": "Write", "tool_input": ["file_path": cwd + "/notes.txt"], "tool_response": "\(cwd)/\(Self.producerPath):6:25: error: x", "session_id": "s1", "cwd": cwd]
        }

        #expect(try answer(payload).isEmpty)
    }
}
