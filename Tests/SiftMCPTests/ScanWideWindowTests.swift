//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// The status-line scan holds a window read after an answer that only located the file to the width the hook holds it to (`ListedWindow.widestExcused`): a window of more than that many printed lines is the file read through a window, scored cold as the hook judges it, unless the file's whole digest was served.
@Suite(.temporaryDirectories)
struct ScanWideWindowTests {
    private static var file: String {
        "Sources/App/Ledger.swift"
    }

    private static func locating(_ kind: Locating) -> [Data] {
        switch kind {
        case .whereListing:
            TranscriptFixture.answeredCall("mcp__sift__where", id: "w1", input: ["symbol": "Ledger"])
        case .lineRangeDigest:
            TranscriptFixture.answeredDigest("\(file):500-520", id: "d1", file: file)
        case .memberDigest:
            TranscriptFixture.answeredDigest("Ledger.balance3", id: "d1", file: file)
        case .moduleDigestHeading:
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "App"]),
                TranscriptFixture.indexAnswer(id: "d1", text: "tree: App  head: 0000000  dirty: 0  parse_errors: 0\n\(file):\n  final class Ledger"),
            ]
        }
    }

    private static func read(_ root: URL, _ input: [String: Any]) -> Data {
        TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": root.appendingPathComponent(file).path].merging(input) { $1 })
    }

    private static func lookup(_ lines: [Data]) -> SwiftLookup? {
        TranscriptFixture.lookups(lines, belowFloor: { _ in false }).last
    }

    @Test(arguments: Locating.allCases)
    func aWideReadAfterOnlyLocatingTheFileIsCold(kind: Locating) throws {
        let root = try ListedWideWindowTests.repository()
        let path = root.appendingPathComponent(Self.file).path

        let lookup = Self.lookup(Self.locating(kind) + [Self.read(root, ["offset": 1, "limit": 520])])

        #expect(lookup == .cold(file: path, missed: nil))
    }

    @Test(arguments: Locating.allCases)
    func aNarrowReadAfterLocatingTheFileIsStillGuided(kind: Locating) throws {
        let root = try ListedWideWindowTests.repository()
        let path = root.appendingPathComponent(Self.file).path

        let lookup = Self.lookup(Self.locating(kind) + [Self.read(root, ["offset": 500, "limit": 200])])

        #expect(lookup == .guided(file: path))
    }

    @Test(arguments: Locating.allCases)
    func aWideShellWindowAfterOnlyLocatingTheFileIsCold(kind: Locating) throws {
        let root = try ListedWideWindowTests.repository()
        let path = root.appendingPathComponent(Self.file).path
        let window = TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sed -n '1,520p' \(path)"])

        let lookup = Self.lookup(Self.locating(kind) + [window])

        #expect(lookup == .cold(file: path, missed: nil))
    }

    @Test
    func aNarrowShellWindowAfterAListingIsStillGuided() throws {
        let root = try ListedWideWindowTests.repository()
        let path = root.appendingPathComponent(Self.file).path
        let window = TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sed -n '480,540p' \(path)"])

        let lookup = Self.lookup(Self.locating(.whereListing) + [window])

        #expect(lookup == .guided(file: path))
    }

    /// The whole digest has handed the context the member map, so it excuses a window of any width, as it does at the hook.
    @Test
    func aWideReadAfterTheWholeDigestIsStillGuided() throws {
        let root = try ListedWideWindowTests.repository()
        let path = root.appendingPathComponent(Self.file).path

        let lookup = Self.lookup(TranscriptFixture.answeredDigest(Self.file, id: "d1", file: Self.file) + [Self.read(root, ["offset": 1, "limit": 520])])

        #expect(lookup == .guided(file: path))
    }

    /// A digest that resolved nothing locates nothing, so even a narrow window after it is cold.
    @Test
    func aNarrowReadAfterADigestThatResolvedNothingIsCold() throws {
        let root = try ListedWideWindowTests.repository()
        let path = root.appendingPathComponent(Self.file).path
        let missed = [
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Ledger.nosuchmember"]),
            TranscriptFixture.indexAnswer(id: "d1", text: "tree: App  head: 0000000  dirty: 0  parse_errors: 0\nno symbol named nosuchmember in the index"),
        ]

        let lookup = Self.lookup(missed + [Self.read(root, ["offset": 500, "limit": 40])])

        #expect(lookup == .cold(file: path, missed: nil))
    }
}

extension ScanWideWindowTests {
    /// What located the file, each of the shapes the hook credits for a window.
    enum Locating: CaseIterable {
        case whereListing
        case lineRangeDigest
        case memberDigest
        case moduleDigestHeading
    }
}
