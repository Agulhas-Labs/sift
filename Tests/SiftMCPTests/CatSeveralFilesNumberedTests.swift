//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A `cat -n` of several Swift files serves each file it answers with source as `cat -n` would have printed it, numbered from 1 in each file, as a `cat -n` of that file alone runs and prints.
@Suite(.temporaryDirectories)
struct CatSeveralFilesNumberedTests {
    @Test(arguments: ["cat -n Sources/App/Large.swift Sources/App/Medium.swift", "cat -n Sources/App/Large.swift Sources/App/Medium.swift || echo fail"])
    func aFileServedAsItsSourceIsNumberedAsCatNumbersIt(command: String) async throws {
        let root = try await CatSeveralFilesVerdictTests.repository()

        let verdict = try #require(try await CatSeveralFilesVerdictTests.decide(command, in: root).verdict)

        #expect(verdict.token == "in-place", "\(verdict)")
        let reason = verdict.reason ?? ""
        let printed = try Self.catNumbering(root.appendingPathComponent("Sources/App/Medium.swift").path)
        let medium = try #require(reason.range(of: "Sources/App/Medium.swift — module: Sources\n("), "\(reason)")
        #expect(reason[medium.lowerBound...].contains(String(printed.dropLast())), "\(reason)")
        let large = try #require(reason.range(of: "Sources/App/Large.swift — module: Sources"), "\(reason)")
        #expect(!reason[large.lowerBound ..< medium.lowerBound].contains("     1\t"), "\(reason)")
    }

    /// A file small enough that its digest would cost more than its source is numbered too: a `cat -n` of it alone runs and prints numbers.
    @Test
    func aFileTheFloorServesAsSourceIsNumberedToo() async throws {
        let root = try await CatSeveralFilesVerdictTests.repository()
        let tiny = root.appendingPathComponent("Sources/App/Tiny.swift")
        try "struct Tiny {\n    let value = 1\n}\n".write(to: tiny, atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()

        let verdict = try #require(try await CatSeveralFilesVerdictTests.decide("cat -n Sources/App/Large.swift Sources/App/Tiny.swift", in: root).verdict)

        #expect(verdict.token == "in-place", "\(verdict)")
        let reason = verdict.reason ?? ""
        let part = try #require(reason.range(of: "Sources/App/Tiny.swift — module: Sources\n("), "\(reason)")
        #expect(try reason[part.lowerBound...].contains(String(Self.catNumbering(tiny.path).dropLast())), "\(reason)")
    }

    @Test
    func aCatWithoutNumbersServesTheSourceUnnumbered() async throws {
        let root = try await CatSeveralFilesVerdictTests.repository()

        let verdict = try #require(try await CatSeveralFilesVerdictTests.decide("cat Sources/App/Large.swift Sources/App/Medium.swift", in: root).verdict)
        let reason = verdict.reason ?? ""

        #expect(reason.contains("\n/// A Medium.\nstruct Medium {\n"), "\(reason)")
        #expect(!reason.contains("     1\t"), "\(reason)")
    }

    @Test(arguments: ["one\ntwo\n", "one\n\nthree", "", "\n", String(repeating: "line\n", count: 12)])
    func numberingMatchesTheSystemCat(source: String) throws {
        let file = try TemporaryDirectory.make("numbered").appendingPathComponent("Text.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let printed = try Self.catNumbering(file.path)

        #expect(WeighedRead.numbered(source) == printed)
    }

    /// What `/bin/cat -n` prints of the file at `path`, or nothing where that is no UTF-8 text.
    private static func catNumbering(_ path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.arguments = ["-n", path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}
