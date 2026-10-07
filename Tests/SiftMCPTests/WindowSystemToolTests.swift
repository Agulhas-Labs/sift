//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Line windows read against what the system tools print for them, run on a fixture whose every line is its own.
@Suite(.temporaryDirectories)
struct WindowSystemToolTests {
    /// The fixture's lines, each one distinct, so the text a command prints names the lines it printed.
    private static let fixture = (1 ... 40).map { "let value\($0) = \($0 * 7) // line \($0)" }

    /// The bytes of the fixture's first `lines` lines, newlines included.
    private static func bytes(through lines: Int) -> Int {
        fixture.prefix(lines).reduce(0) { $0 + $1.utf8.count + 1 }
    }

    /// What `command` prints to standard output run by `/bin/sh` in a directory holding the fixture as `F.swift`, with only the system tools on the path.
    private static func systemOutput(of command: String) throws -> String {
        let directory = try TemporaryDirectory.make("window-tools")
        try (fixture.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("F.swift"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// The window `command` is read as.
    private static func window(_ command: String) -> LineWindow {
        LineWindow(stages: ShellSyntax.segments(of: command).map { ShellQuery($0).invocation })
    }

    /// A byte count ending on a line's end, `sed -n` with extended expressions, and an `awk` window printing each line through `printf`, are each read to exactly the lines the system tool prints, and answered as the window they are.
    @Test(arguments: [
        "head -c \(bytes(through: 12)) F.swift",
        "head -c\(bytes(through: 3)) F.swift",
        "head -c 99999 F.swift",
        "sed -n -E '5,17p' F.swift",
        "sed -n -r '5,17p;30p' F.swift",
        "awk 'NR>=5 && NR<=17 {printf \"%s\\n\", $0}' F.swift",
        "awk 'NR==8,NR==11 {printf(\"%s\\n\", $0);}' F.swift",
    ])
    func aWindowIsReadToTheLinesTheSystemToolPrints(command: String) throws {
        let lines = try #require(Self.window(command).lines(in: Self.fixture))
        let printed = try Self.systemOutput(of: command)

        #expect(!lines.isEmpty)
        #expect(lines.map { Self.fixture[$0 - 1] + "\n" }.joined() == printed)
        #expect(InPlaceShape.match(forShell: command, in: "/repo")?.call == .fileDigest(path: "F.swift", windows: [Self.window(command)]))
    }

    /// A byte count ending part way through a line prints part of that line, which no line window stands for: its lines are not read against the file.
    @Test
    func aByteCountEndingInsideALineIsNotReadToLines() throws {
        let command = "head -c \(Self.bytes(through: 12) - 4) F.swift"

        let printed = try Self.systemOutput(of: command)

        #expect(!printed.hasSuffix("\n"))
        #expect(Self.window(command).lines(in: Self.fixture) == nil)
    }
}
