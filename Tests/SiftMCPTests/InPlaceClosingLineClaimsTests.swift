//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// The closing line of every answer in place states sizes and nothing it cannot know: no saving in tokens, since whether the source is read anyway is not known when the answer is given, and no claim that the re-run is free, since it costs the raw output it returns.
@Suite(.temporaryDirectories)
struct InPlaceClosingLineClaimsTests {
    /// Records an issue unless `answered` closes on a line free of both claims, after an opening line naming the re-run as the way to the raw output; returns the closing line.
    @discardableResult
    private static func closing(of answered: InPlaceAnswerer.Answered?, _ shape: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let reason = try #require(answered?.reason, "\(shape) was not answered", sourceLocation: sourceLocation)
        let lines = reason.split(separator: "\n")
        let opening = try #require(lines.first, sourceLocation: sourceLocation)
        let closing = try #require(lines.last.map(String.init), sourceLocation: sourceLocation)
        #expect(InPlaceAnswer.calls(inOpeningLine: opening) != nil, "\(shape): \(opening)", sourceLocation: sourceLocation)
        #expect(opening.hasSuffix("re-run the identical command if you wanted its raw output.") || opening.hasSuffix("or Read just a member's line range below with offset and limit."), "\(shape)", sourceLocation: sourceLocation)
        #expect(!reason.contains("tokens saved"), "\(shape): \(closing)", sourceLocation: sourceLocation)
        #expect(!reason.contains("costs nothing"), "\(shape): \(closing)", sourceLocation: sourceLocation)
        #expect(!closing.contains("saved"), "\(shape): \(closing)", sourceLocation: sourceLocation)
        #expect(!closing.contains("bytes a token"), "\(shape): \(closing)", sourceLocation: sourceLocation)
        return closing
    }

    /// The line a refusal of `served` bytes closes on where it stands in for `source` bytes and is smaller: the two sizes and the share by which it is smaller, rounded down.
    private static func smaller(source: Int, served: Int) -> String {
        let share = (source - served) * 100 / source
        return "\(ByteSize.short(source)) of source → \(ByteSize.short(served)) served (\(share == 0 ? "<1" : "\(share)")% smaller)."
    }

    /// A whole read answered with the file's digest closes on the file's size, the refusal's own, and the share between them, with the bytes the usage log records for it unchanged: every byte served charged to a call, against the file's size on disk.
    @Test
    func aWholeReadClosesOnItsSizesAlone() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)

        let answered = try #require(try await InPlaceAnswerTests.answered("cat Sources/App/Depot.swift", in: root))
        let served = answered.reason.utf8.count

        #expect(try Self.closing(of: answered, "whole read") == Self.smaller(source: size, served: served))
        #expect(answered.calls.map(\.bytes.source) == [size])
        #expect(answered.calls.reduce(0) { $0 + $1.bytes.served } == served)
        // The audit reads the same two sizes back off the line, to the rounding the line prints them at.
        let spared = AnswerThenRead.claimedSaving(inReason: answered.reason)
        #expect(abs(spared - (size - served)) <= 100, "\(spared) read back for \(size - served)")
    }

    /// A window answered with the members it overlaps closes on the window's own lines' size, not the file's.
    @Test
    func aWindowClosesOnItsSizesAlone() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)
        let lines = try String(contentsOf: root.appendingPathComponent("Sources/App/Depot.swift"), encoding: .utf8).components(separatedBy: "\n")
        let window = lines[1 ..< 180].reduce(0) { $0 + $1.utf8.count + 1 }

        let answered = try #require(try await InPlaceAnswerTests.answered("sed -n '2,180p' Sources/App/Depot.swift", in: root))

        #expect(try Self.closing(of: answered, "window") == Self.smaller(source: window, served: answered.reason.utf8.count))
    }

    /// A Markdown document's outline, a declaration grep's digest, and a line of several reads each close free of both claims.
    @Test
    func everyOtherShapeClosesFreeOfBothClaims() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        try InPlaceAnswerTests.document(in: root)

        // A whole `Read` of a document is answered with its outline; a lone shell read of one is not a candidate.
        let read = try await InPlaceAnswerTests.answer(.documentOutline(path: "Docs/Plan.md"), from: root.path)
        let outline: InPlaceAnswerer.Answered? = if case let .answered(answered) = read {
            answered
        } else {
            nil
        }
        let digest = try await InPlaceAnswerTests.answered("grep -n 'func ' Sources/App/Depot.swift", in: root)
        let compound = try await InPlaceAnswerTests.answered("cat Sources/App/Depot.swift && cat Docs/Plan.md", in: root)
        let closings = try [Self.closing(of: outline, "outline"), Self.closing(of: digest, "declaration grep"), Self.closing(of: compound, "compound line")]

        #expect(closings[2].hasSuffix("% smaller)."), "compound line: \(closings[2])")
    }

    /// A sweep answered with `where` and every reference site, on a package built with an index store, closes free of both claims.
    @Test
    func aSweepClosesFreeOfBothClaims() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Gadget.swift": "public struct Gadget {\n    public init() {}\n}\n",
            "Sources/App/Uses.swift": "struct Holder {\n    var gadget: Gadget\n    func make() -> Gadget { Gadget() }\n}\n",
        ], to: root)
        try MCPTestRepo.build(root)
        try await SiftEngine(directory: root).ensureFresh()

        let sweep = try await InPlaceAnswerTests.answered("grep -rnw Gadget Sources", in: root)

        #expect(sweep?.calls.map(\.tool) == ["where"])
        try Self.closing(of: sweep, "sweep")
    }

    /// The two closings that state no smaller size say only that: no saving against a source the answer did not undercut, and none claimed where there was nothing to weigh.
    @Test
    func theClosingsStatingNoSavingCarryNoReRunClaim() {
        let short = InPlaceAnswer.reason(calls: ["digest Sources/App/Alpha.swift"], answer: "tree: App\nstruct Alpha {}", source: 60, standsIn: "").text
        let unweighed = InPlaceAnswer.reason(calls: ["where Alpha --refs"], answer: "tree: App\nwhere Alpha", source: nil, standsIn: "nothing weighed").text

        #expect(short.split(separator: "\n").last.map(String.init) == "No saving: \(ByteSize.short(short.utf8.count)) served for 60 B of source.")
        #expect(InPlaceAnswer.deniesSaving(inReason: short))
        #expect(unweighed.split(separator: "\n").last.map(String.init) == "No saving is claimed: nothing weighed, so there is nothing measured to set it against.")
    }
}
