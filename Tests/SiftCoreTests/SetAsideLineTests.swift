//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the set-aside `run --without-line` stands on: one line of a Swift file commented out, and every byte of the file — and nothing in the index — back afterwards.
@Suite(.temporaryDirectories)
struct SetAsideLineTests {
    /// The line gains `// ` after its indentation, and every other byte, line endings included, is as it was.
    @Test
    func aLineIsCommentedOutAfterItsIndentationAndNothingElseMoves() throws {
        let source = Data("struct Widget {\n\t  var state = \"fixed\"\r\n}".utf8)

        let (text, mutated) = try SetAsideRecord.MutatedLine.commentingOut(line: 2, of: source, path: "Widget.swift")

        #expect(text == "\t  var state = \"fixed\"\r")
        #expect(mutated == Data("struct Widget {\n\t  // var state = \"fixed\"\r\n}".utf8))
        let last = try SetAsideRecord.MutatedLine.commentingOut(line: 3, of: source, path: "Widget.swift").mutated
        #expect(last == Data("struct Widget {\n\t  var state = \"fixed\"\r\n// }".utf8))
    }

    /// A line past the end, a blank line and a line that is already a comment are refused, the comment with its text said back.
    @Test
    func aLineWithNothingToCommentOutIsRefused() {
        let source = Data("struct Widget {\n\n    // state\n}\n".utf8)
        let refusals = [5, 2, 3, 0].map { number -> String in
            do {
                _ = try SetAsideRecord.MutatedLine.commentingOut(line: number, of: source, path: "Widget.swift")
                return "accepted"
            } catch {
                return "\(error)"
            }
        }

        #expect(refusals[0].contains("Widget.swift:5 — the file has 4 lines"), "\(refusals[0])")
        #expect(refusals[1].contains("Widget.swift:2 — it is blank"), "\(refusals[1])")
        #expect(refusals[2].contains("it is already a comment — \"// state\""), "\(refusals[2])")
        #expect(refusals[3].contains("Widget.swift:0 — the file has 4 lines"), "\(refusals[3])")
    }

    /// A `--without-line` refusal names its own flag, not `--without`: the capture that finds nothing to comment out is a `--without-line` capture, and the sentence it prints says so.
    @Test
    func aLineRefusalNamesItsOwnFlag() {
        let source = Data("struct Widget {\n\n}\n".utf8)

        do {
            _ = try SetAsideRecord.MutatedLine.commentingOut(line: 2, of: source, path: "Widget.swift")
            Issue.record("a blank line was accepted")
        } catch let error as SetAsideError {
            #expect(error.description.contains("sift run --without-line: refusing to set aside"), "\(error.description)")
            #expect(!error.description.contains("sift run --without:"), "\(error.description)")
        } catch {
            Issue.record("refused as \(error), not a SetAsideError")
        }
    }

    /// The record's line survives being written and read, and a record written without one reads as having none.
    @Test
    func theRecordsLineRoundTripsAndAnOldRecordStillLoads() throws {
        let line = SetAsideRecord.MutatedLine(path: "Sources/Widget.swift", number: 5, text: "        state = \"fixed\"")
        let record = SetAsideRecord(id: "one", pathspecs: ["Sources/Widget.swift:5"], directory: "", head: "abc", owner: 1, entries: [], line: line)
        let old = SetAsideRecord(id: "two", pathspecs: ["Sources/"], directory: "", head: "abc", owner: 1, entries: [])

        let decoded = try JSONDecoder().decode(SetAsideRecord.self, from: JSONEncoder().encode(record))
        let oldData = try JSONEncoder().encode(old)

        #expect(decoded == record)
        #expect(decoded.named == "Sources/Widget.swift:5")
        #expect(!(String(bytes: oldData, encoding: .utf8) ?? "").contains("\"line\""))
        #expect(try JSONDecoder().decode(SetAsideRecord.self, from: oldData).line == nil)
    }

    /// Set aside, the file reads with its line commented out and the index is untouched; put back, the file and the index are exactly as they were — for a tracked file with an edit and for an untracked one.
    @Test(arguments: [true, false])
    func theLineGoesOutAndComesBackByteForByte(tracked: Bool) throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("// seed\n", to: "Sources/Seed.swift", in: root)
        if tracked {
            try TestSources.write("struct Widget {\n}\n", to: "Sources/Widget.swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "base")
        try TestSources.write("struct Widget {\n    var state = \"fixed\"\n}\n", to: "Sources/Widget.swift", in: root)
        let file = root.appendingPathComponent("Sources/Widget.swift")
        let before = try Data(contentsOf: file)
        let index = try TestSources.runGit(["ls-files", "-s"], in: root)
        let store = SetAsideStore(repositoryRoot: root)

        let record = try SetAside.capture(line: 2, of: "Sources/Widget.swift", from: root, into: store)
        guard case .setAside = try SetAside(store: store).setAside(record) else {
            Issue.record("the set-aside stopped")
            return
        }

        #expect(record.line == SetAsideRecord.MutatedLine(path: "Sources/Widget.swift", number: 2, text: "    var state = \"fixed\""))
        #expect(try String(contentsOf: file, encoding: .utf8) == "struct Widget {\n    // var state = \"fixed\"\n}\n")
        #expect(try TestSources.runGit(["ls-files", "-s"], in: root) == index)
        _ = try SetAside(store: store).restore(record)
        #expect(try Data(contentsOf: file) == before)
        #expect(try TestSources.runGit(["ls-files", "-s"], in: root) == index)
        #expect(try store.record() == nil)
    }

    /// A file written between being recorded and being set aside stops the set-aside, and the write stays.
    @Test
    func aFileChangedAfterItWasRecordedStopsTheSetAside() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Widget {\n    var state = \"fixed\"\n}\n", to: "Sources/Widget.swift", in: root)
        try TestSources.commitAll(in: root, message: "base")
        let store = SetAsideStore(repositoryRoot: root)
        let record = try SetAside.capture(line: 2, of: "Sources/Widget.swift", from: root, into: store)
        try TestSources.write("struct Widget {\n    var state = \"edited\"\n}\n", to: "Sources/Widget.swift", in: root)

        let outcome = try SetAside(store: store).setAside(record)

        guard case let .stopped(changed, _) = outcome else {
            Issue.record("the set-aside went ahead over a changed file")
            return
        }

        #expect(changed == ["Sources/Widget.swift"])
        #expect(try String(contentsOf: root.appendingPathComponent("Sources/Widget.swift"), encoding: .utf8).contains("edited"))
        #expect(try store.record() == nil)
    }
}
