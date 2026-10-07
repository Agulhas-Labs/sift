//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Every refusal served around an answer's break-even point, one byte of source at a time: each states its own size, and none is bigger than what it stands in for.
@Suite(.temporaryDirectories) struct InPlaceBreakEvenTests {
    /// The lines of a depot of `members` five-line functions, as `InPlaceAnswerTests.indexedRepository` writes it with forty.
    private static func depot(members: Int) -> [String] {
        let bodies = (1 ... members).flatMap { index in
            ["    func stock\(index)() -> Int {", "        let count = \(index)", "        let doubled = count * 2", "        return doubled + count", "    }"]
        }
        return ["/// A depot."] + ["struct Depot {"] + bodies + ["}"]
    }

    /// Writes `lines` to the depot file with the 1-based line `padded` carrying a trailing comment of `padding` bytes, or none where `padding` is zero.
    private static func write(_ lines: [String], padded: Int, by padding: Int, in root: URL) throws {
        var rows = lines
        if padding > 0 {
            rows[padded - 1] += " //" + String(repeating: "x", count: padding - 3)
        }
        try (rows.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("Sources/App/Depot.swift"), atomically: true, encoding: .utf8)
    }

    /// What the hook does with `command` in `root` as the file stands now — waiting however long the machine takes to compute it, since this is a test of break-even arithmetic, not of the machine's own speed.
    private static func outcome(_ command: String, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> InPlaceAnswerer.Outcome {
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path), sourceLocation: sourceLocation)
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, deadline: .unbounded, backoff: backoff)
        }
    }

    /// The closing line of a refusal of `served` bytes standing in for `source` bytes of source, smaller than it: the two sizes and the share by which the refusal is smaller, rounded down.
    private static func smaller(source: Int, served: Int) -> String {
        let share = (source - served) * 100 / source
        return "\(ByteSize.short(source)) of source → \(ByteSize.short(served)) served (\(share == 0 ? "<1" : "\(share)")% smaller)."
    }

    /// Records an issue unless `outcome` is withheld as not smaller or as not showing its lines, or served no bigger than `source` bytes with a closing line stating the refusal's own size against exactly that source; returns whether it was served.
    private static func check(_ outcome: InPlaceAnswerer.Outcome, source: Int, width: Int, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        guard case let .answered(answered) = outcome else {
            #expect([.withheld(.notSmaller), .withheld(.linesNotShown)].contains(outcome), "at \(width) B", sourceLocation: sourceLocation)
            return false
        }
        let served = answered.reason.utf8.count
        let closing = answered.reason.split(separator: "\n").last.map(String.init)
        #expect(served < source, "at \(width) B a \(served) B refusal was served for \(source) B", sourceLocation: sourceLocation)
        #expect(closing == Self.smaller(source: source, served: served), "at \(width) B, \(served) B served", sourceLocation: sourceLocation)
        return true
    }

    /// A five-line window widened a byte at a time from just under the size of its own member answer plus the floor to sixty bytes past it, across the band where that answer breaks even: a members answer showing none of the window's lines has to save ``InPlaceAnswer/windowSavingFloor`` to be served.
    ///
    /// The band is measured from the answer rather than fixed, since the answer's freshness header names the fixture's directory and so moves every width with it. Two, four and forty-one bytes past the answer's size are where the old loop stopped with a figure a byte or a token off the answer's own size.
    @Test
    func everyWindowServedAcrossItsBreakEvenStatesItsOwnSize() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let lines = Self.depot(members: 40)
        let bare = lines[49 ... 53].reduce(0) { $0 + $1.utf8.count + 1 }
        let command = "sed -n '50,54p' Sources/App/Depot.swift"
        try Self.write(lines, padded: 50, by: 700 + InPlaceAnswer.windowSavingFloor - bare, in: root)
        guard case let .answered(roomy) = try await Self.outcome(command, in: root) else {
            Issue.record("a window of 700 B past the floor is answered")
            return
        }
        let size = roomy.reason.utf8.count + InPlaceAnswer.windowSavingFloor
        var served = 0
        for width in size - 10 ... size + 60 {
            try Self.write(lines, padded: 50, by: width - bare, in: root)
            if try await Self.check(Self.outcome(command, in: root), source: width, width: width) {
                served += 1
            }
        }

        #expect(served > 0, "no window in the band was served, so none was checked")
    }

    /// A whole read of a file grown a byte at a time from where its digest gives way to its own source, served bigger than the file, to where the refusal it serves is four hundred bytes smaller than the file: every read served states its own size against the file's real size on disk, and every one no smaller than the file is withheld.
    @Test
    func everyWholeReadServedAcrossItsBreakEvenStatesItsOwnSize() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let lines = Self.depot(members: 8)
        let bare = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        #expect(bare < 1370)
        var served = 0
        var withheld = 0
        for width in 1370 ... 1450 {
            try Self.write(lines, padded: lines.count, by: width - bare, in: root)
            let size = try #require(try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Sources/App/Depot.swift").path)[.size] as? Int)
            #expect(size == width)
            if try await Self.check(Self.outcome("cat Sources/App/Depot.swift", in: root), source: width, width: width) {
                served += 1
            } else {
                withheld += 1
            }
        }
        #expect(served > 0 && withheld > 0, "the band did not straddle the break-even point: \(served) served, \(withheld) withheld")
    }

    /// A whole read of a file smaller than its answer is withheld as not smaller, rather than served saying it saved nothing.
    @Test
    func aWholeReadOfAFileSmallerThanItsAnswerIsWithheld() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try Self.write(Self.depot(members: 2), padded: 1, by: 0, in: root)

        #expect(try await Self.outcome("cat Sources/App/Depot.swift", in: root) == .withheld(.notSmaller))
    }

    /// A declaration grep of a four-function file grown a byte at a time across the band where its answer breaks even is served at every width, closing with figures that are the refusal's own where it states any and with the line that claims no saving where no closing line could state its own size.
    ///
    /// The band is measured from the answer, as the window sweep's is, and spans the widths where the file is a few bytes bigger than the answer: there the line denying a saving leaves the refusal smaller than the file and the line stating a smaller size makes it no smaller. A grep prints a few lines rather than the file, so none of it is withheld as no smaller than what it prints.
    @Test
    func everyDeclarationGrepAcrossItsBreakEvenIsServed() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add(["Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n"], to: root)
        // Short bodies, so the file comes within a few bytes of its digest's answer while the digest is still served in place of its source.
        let bodies = (1 ... 4).flatMap { index in
            ["    func stock\(index)(_ v: Int) -> Int {", "        let a = v * 2", "        let b = v * 3", "        return a + b", "    }"]
        }
        let lines = ["/// A depot.", "struct Depot {"] + bodies + ["}"]
        let bare = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        let command = "grep -n 'func ' Sources/App/Depot.swift"
        try Self.write(lines, padded: lines.count, by: 900 - bare, in: root)
        guard case let .answered(roomy) = try await Self.outcome(command, in: root) else {
            Issue.record("a grep of a 900 B file is answered")
            return
        }
        let size = roomy.reason.utf8.count
        try #require(bare + 3 <= size - 40, "the file is \(bare) B before padding, the answer \(size) B")
        var stated = 0
        var unclaimed = 0
        for width in size - 40 ... size + 10 {
            try Self.write(lines, padded: lines.count, by: width - bare, in: root)
            guard case let .answered(answered) = try await Self.outcome(command, in: root) else {
                Issue.record("at \(width) B the grep was not served")
                continue
            }
            let served = answered.reason.utf8.count
            let closing = answered.reason.split(separator: "\n").last.map(String.init) ?? ""
            if closing.hasPrefix("No saving is claimed: ") {
                #expect(closing == "No saving is claimed: this answer did not weigh itself against the grep's output, so there is nothing measured to set it against.", "at \(width) B")
                unclaimed += 1
                continue
            }
            let expected = width > served
                ? Self.smaller(source: width, served: served)
                : "No saving: \(ByteSize.short(served)) served for \(ByteSize.short(width)) of source."
            #expect(closing == expected, "at \(width) B, \(served) B served")
            stated += 1
        }

        #expect(stated > 0 && unclaimed > 0, "the band did not cover both closings: \(stated) stated, \(unclaimed) claiming none")
    }
}
