//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// A `grep` command read for what decides the lines it prints, and run in-process: context groups, the cut a `head` or `tail` makes, and every file it cannot read exactly reported as undecided.
@Suite(.temporaryDirectories)
struct ShellGrepTests {
    /// A directory holding `files`, removed by the caller.
    private static func directory(_ files: [String: String]) throws -> URL {
        let root = try TemporaryDirectory.make("shellgrep").appendingPathComponent("shellgrep")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private static func printed(
        _ arguments: [String],
        cut: ShellGrep.Cut? = nil,
        in root: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ShellGrep.Outcome {
        var search = try #require(ShellGrep(arguments: arguments), sourceLocation: sourceLocation)
        search.cut = cut
        return search.run(in: root.path)
    }

    private static func lines(_ outcome: ShellGrep.Outcome) -> [Int] {
        guard case let .printed(lines) = outcome else { return [] }
        return lines.map(\.line)
    }

    /// The flags that change which lines match are read; the ones that change only how they print are allowed; the rest leave the command unread.
    @Test
    func theArgumentsAreReadForWhatDecidesTheLines() throws {
        let search = try #require(ShellGrep(arguments: ["-rniw", "--include=*.swift", "name", "Sources", "Tests"]))

        #expect(search.options == GrepPattern.Options(dialect: .basic, ignoresCase: true, wholeWords: true))
        #expect(search.recursive && search.swiftOnly)
        #expect(search.paths == ["Sources", "Tests"])
        #expect(try #require(ShellGrep(arguments: ["-n", "func go", "-A", "3", "A.swift"])).after == 3)
        #expect(try #require(ShellGrep(arguments: ["-nC2", "x", "A.swift"])).before == 2)
        for unread in [
            ["-v", "x", "A.swift"],
            ["-c", "x", "A.swift"],
            ["-e", "x", "A.swift"],
            ["-o", "x", "A.swift"],
            ["-P", "x", "A.swift"],
            ["-rn", "--include=*.SWIFT", "x", "Sources"],
            ["-n"],
        ] {
            #expect(ShellGrep(arguments: unread) == nil, "\(unread)")
        }
    }

    /// A `head` or `tail` stage is read as the count it cuts to; anything else is no cut.
    @Test
    func aCutIsTheCountItKeeps() {
        #expect(ShellGrep.cut(ofStage: ["head", "-5"]) == .head(5))
        #expect(ShellGrep.cut(ofStage: ["tail", "-n", "3"]) == .tail(3))
        #expect(ShellGrep.cut(ofStage: ["head"]) == .head(10))
        #expect(ShellGrep.cut(ofStage: ["tail", "-n", "+3"]) == nil)
        #expect(ShellGrep.cut(ofStage: ["sort"]) == nil)
    }

    /// The cut applies to what was printed, so a `tail -1` keeps the last match, not the first.
    @Test
    func theCutAppliesToThePrintedLines() throws {
        let root = try Self.directory(["A.swift": "func save() {}\nlet x = 1\nfunc save2() {}\nfunc saved() {}\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try Self.lines(Self.printed(["-n", "func save", "A.swift"], in: root)) == [1, 3, 4])
        #expect(try Self.lines(Self.printed(["-n", "func save", "A.swift"], cut: .tail(1), in: root)) == [4])
        #expect(try Self.lines(Self.printed(["-n", "func save", "A.swift"], cut: .head(2), in: root)) == [1, 3])
    }

    /// Context lines are printed around each match, and where a separator may or may not count toward a cut, the lines kept either way are all accounted for.
    @Test
    func contextIsPrintedAndACutKeepsEitherReading() throws {
        let body = (1 ... 12).map { $0 == 2 || $0 == 9 ? "match \($0)" : "line \($0)" }.joined(separator: "\n") + "\n"
        let root = try Self.directory(["A.swift": body])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try Self.lines(Self.printed(["-n", "-A", "1", "match", "A.swift"], in: root)) == [2, 3, 9, 10])
        // With the separator counted the head keeps 2, 3 and the separator; without it, 2, 3 and 9.
        #expect(try Self.lines(Self.printed(["-n", "-A", "1", "match", "A.swift"], cut: .head(3), in: root)) == [2, 3, 9])
    }

    /// A recursive search reads every regular file, hidden ones included, and `--include=*.swift` keeps it to Swift.
    @Test
    func aRecursiveSearchReadsEveryFileItWouldReach() throws {
        let root = try Self.directory([
            "Sources/A.swift": "struct Name {}\n",
            "Sources/.hidden/B.swift": "let a = Name()\n",
            "Sources/README.md": "Name is documented here\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let everything = try Self.printed(["-rnw", "Name", "Sources"], in: root)
        let swift = try Self.printed(["-rnw", "--include=*.swift", "Name", "Sources"], in: root)

        guard case let .printed(all) = everything, case let .printed(onlySwift) = swift else {
            Issue.record("expected both searches decided")
            return
        }

        #expect(Set(all.map { URL(fileURLWithPath: $0.file).lastPathComponent }) == ["A.swift", "B.swift", "README.md"])
        #expect(Set(onlySwift.map { URL(fileURLWithPath: $0.file).lastPathComponent }) == ["A.swift", "B.swift"])
    }

    /// A binary file elsewhere in the tree does not withhold a search its pattern could never have reached.
    ///
    /// The required-literal check decides such a file before its encoding is ever asked, so a stray `.DS_Store` or checked-in image beside the files being searched changes nothing. A binary file that genuinely holds the pattern's bytes is still undecided — the fix reorders the two checks, it does not skip the encoding one.
    @Test
    func aFileThatCannotHoldThePatternIsDecidedWithoutAskingItsEncoding() throws {
        let root = try Self.directory(["Sources/A.swift": "struct Name {}\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        // Neither the shape's bytes nor the pattern's letters as plain text.
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: root.appendingPathComponent("Sources/.DS_Store"))

        #expect(try Self.lines(Self.printed(["-rnw", "Name", "Sources"], in: root)) == [1])

        // A NUL file that does hold the pattern's bytes stays undecided: its encoding still cannot be pinned down.
        try (Data([0x00, 0x01]) + Data("Name".utf8)).write(to: root.appendingPathComponent("Sources/blob.bin"))
        #expect(try Self.printed(["-rnw", "Name", "Sources"], in: root) == .undecided("encoding"))
    }

    /// A UTF-32 file is undecided whichever way round its byte-order mark is written: `ugrep` decodes and prints such a file where the system grep reads it as binary, and the two disagree about a line the search would otherwise answer for.
    ///
    /// The pattern's letters stand in it one byte in four, so the required-literal check never finds them and would decide the file has nothing to print — which is why the mark has to be recognised before that check is trusted. Big-endian's `00 00 FE FF` is the mark that needs one of its own; little-endian's `FF FE 00 00` opens on the UTF-16 mark, asserted here beside it rather than assumed.
    @Test
    func aUTF32FileIsUndecidedWhicheverWayRoundItsByteOrderMarkIsWritten() throws {
        /// `text` as UTF-32, each scalar's most significant byte written first or last as asked.
        func utf32(_ text: String, mostSignificantFirst: Bool) -> Data {
            Data(text.unicodeScalars.flatMap { scalar -> [UInt8] in
                let bytes = (0 ..< 4).map { UInt8(truncatingIfNeeded: scalar.value >> (24 - 8 * $0)) }
                return mostSignificantFirst ? bytes : bytes.reversed()
            })
        }

        let root = try Self.directory(["Wide/Alpha.swift": "struct Name {}\n", "Little/Alpha.swift": "struct Name {}\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        try (Data([0x00, 0x00, 0xFE, 0xFF]) + utf32("Name of the thing\n", mostSignificantFirst: true))
            .write(to: root.appendingPathComponent("Wide/notes.txt"))
        try (Data([0xFF, 0xFE, 0x00, 0x00]) + utf32("Name of the thing\n", mostSignificantFirst: false))
            .write(to: root.appendingPathComponent("Little/notes.txt"))

        #expect(try Self.printed(["-rnw", "Name", "Wide"], in: root) == .undecided("encoding"))
        #expect(try Self.printed(["-rnw", "Name", "Little"], in: root) == .undecided("encoding"))
    }

    /// Whatever cannot be worked out exactly is undecided: a cut across files in an order grep does not fix, a binary file that may match, a symbolic link, a line a trailing carriage return decides.
    @Test
    func whatCannotBeReproducedIsUndecided() throws {
        let root = try Self.directory([
            "Sources/A.swift": "struct Name {}\n",
            "Sources/B.swift": "let a = Name()\n",
            "Loose/C.swift": "Name\r\n",
            "Other/D.swift": "struct Name {}\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0x4E, 0x61, 0x6D, 0x65, 0x00]).write(to: root.appendingPathComponent("Other/blob.bin"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Linked"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Linked/A.swift"),
            withDestinationURL: root.appendingPathComponent("Sources/A.swift")
        )

        #expect(try Self.printed(["-rnw", "Name", "Sources"], cut: .head(1), in: root) == .undecided("order"))
        #expect(try Self.lines(Self.printed(["-rnw", "Name", "Sources"], cut: .head(5), in: root)) == [1, 1])
        #expect(try Self.printed(["-rnw", "Name", "Other"], in: root) == .undecided("encoding"))
        #expect(try Self.printed(["-rn", "Name", "Linked"], in: root) == .undecided("tree"))
        #expect(try Self.printed(["-n", "Name$", "Loose/C.swift"], in: root) == .undecided("line"))
        #expect(try Self.printed(["-n", "Name", "Missing.swift"], in: root) == .undecided("path"))
    }

    /// A localization table stored as UTF-16 is decoded and printed by `ugrep` and read as binary by the system grep, and a NUL makes any file binary to one and skipped or reported by the other: such a file is undecided before its pattern is looked for, though the pattern's letters never stand in it as plain bytes.
    @Test
    func aFileEveryGrepReadsDifferentlyIsUndecidedWhateverItHolds() throws {
        let entry = "\"greeting\" = \"Welcome\";\n"
        let root = try Self.directory(["Sources/Strings.swift": "enum Strings {\n    static let greeting = \"greeting\"\n}\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try (Data([0xFF, 0xFE]) + Data(entry.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))
            .write(to: resources.appendingPathComponent("Localizable.strings"))
        let wide = root.appendingPathComponent("Wide")
        try FileManager.default.createDirectory(at: wide, withIntermediateDirectories: true)
        try (Data([0xFE, 0xFF]) + Data(entry.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }))
            .write(to: wide.appendingPathComponent("Localizable.strings"))
        let binary = root.appendingPathComponent("Binary")
        try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: true)
        // Holds the pattern's own bytes, so its NUL alone — not an absent literal — is what leaves it undecided.
        try (Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]) + Data("greeting".utf8)).write(to: binary.appendingPathComponent("icon.png"))

        #expect(try Self.printed(["-rnw", "greeting", "Sources", "Resources"], in: root) == .undecided("encoding"))
        #expect(try Self.printed(["-rnw", "greeting", "Sources", "Resources"], cut: .head(5), in: root) == .undecided("encoding"))
        #expect(try Self.printed(["-rnw", "greeting", "Wide"], in: root) == .undecided("encoding"))
        #expect(try Self.printed(["-rnw", "greeting", "Binary"], in: root) == .undecided("encoding"))
        #expect(try Self.printed(["-nw", "greeting", "Resources/Localizable.strings"], in: root) == .undecided("encoding"))
        #expect(try Self.lines(Self.printed(["-rnw", "greeting", "Sources"], in: root)) == [2])
    }

    /// A UTF-8 byte-order mark opening a file is stripped by `ugrep` and read as text by the system grep, so a first line whose match turns on it — an anchored pattern, a whole-line one — is undecided, and one that matches alike either way is not.
    @Test
    func aByteOrderMarkOpeningAFileDecidesItsFirstLineOnlyWhereBothReadingsAgree() throws {
        let root = try Self.directory([:])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try (Data([0xEF, 0xBB, 0xBF]) + Data("import Foundation\nfunc go() {}\n".utf8)).write(to: root.appendingPathComponent("Marked.swift"))

        #expect(try Self.printed(["-n", "^import", "Marked.swift"], in: root) == .undecided("line"))
        #expect(try Self.printed(["-nx", "import Foundation", "Marked.swift"], in: root) == .undecided("line"))
        #expect(try Self.lines(Self.printed(["-n", "^func", "Marked.swift"], in: root)) == [2])
        #expect(try Self.lines(Self.printed(["-n", "import", "Marked.swift"], in: root)) == [1])
    }

    /// `--include` filters a recursion and never starts one: without `-r` a directory operand is skipped by some implementations and searched by others.
    @Test
    func anIncludeWithoutARecursionSearchesNoDirectory() throws {
        let root = try Self.directory(["Sources/A.swift": "struct Name {}\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let search = try #require(ShellGrep(arguments: ["-nw", "--include=*.swift", "Name", "Sources"]))

        #expect(!search.recursive && search.swiftOnly)
        #expect(search.run(in: root.path) == .undecided("path"))
    }

    /// Under a ceiling the search stops at the first line of a file no answer accounts for, and once what it has printed would cost more than the budget — and a cut across files stops it as soon as the cut would drop a line.
    @Test
    func aSearchStopsWhereItsCeilingCannotHoldWhatItPrints() throws {
        let root = try Self.directory([
            "Sources/A.swift": "struct Name {}\nlet a = Name()\n",
            "Sources/B.swift": "let b = Name()\n",
            "Docs/Name.md": "Name\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        // A file read past the stopping point would be undecided for its own reason, so the stop is what decides.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Later"), withIntermediateDirectories: true)
        try Data([0x4E, 0x61, 0x6D, 0x65, 0x00]).write(to: root.appendingPathComponent("Later/blob.bin"))
        func ceiling(_ budget: Int) -> ShellGrep.Ceiling {
            ShellGrep.Ceiling(admits: { $0.hasSuffix(".swift") }, cost: { lines, _ in lines.count * 10 }, budget: budget)
        }
        var sweep = try #require(ShellGrep(arguments: ["-rnw", "Name", "Sources", "Docs", "Later"]))

        #expect(sweep.run(in: root.path, ceiling: ceiling(1000)) == .pastCeiling(.unaccounted))
        sweep.paths = ["Sources", "Later"]
        #expect(sweep.run(in: root.path, ceiling: ceiling(29)) == .pastCeiling(.overBudget))
        sweep.paths = ["Sources"]
        #expect(Self.lines(sweep.run(in: root.path, ceiling: ceiling(30))) == [1, 2, 1])
        sweep.paths = ["Sources", "Later"]
        sweep.cut = .head(2)
        #expect(sweep.run(in: root.path) == .undecided("order"))
    }

    /// Wherever the search decides a file, every grep a shell may run prints exactly the lines it says — across the encodings, byte-order marks and line endings the greps read differently; wherever they would differ, it is undecided.
    @Test
    func everyDecidedFileAgreesWithTheSystemGrep() throws {
        try Self.checkDecidedFiles(against: [.system(locale: "C"), .system(locale: "en_US.UTF-8")])
    }

    /// The same, against `ugrep` run as Claude Code's shell runs it.
    @Test(.enabled(if: SystemGrep.installedUgrep != nil, "no ugrep on this machine"))
    func everyDecidedFileAgreesWithUgrep() throws {
        try Self.checkDecidedFiles(against: [#require(SystemGrep.installedUgrep)])
    }

    /// A directory the walk cannot list, or a file under it that cannot be read, is an error every grep reports and exits 2 on whatever it printed from the rest, so the search is undecided rather than answered from what it could read.
    @Test
    func aDirectoryOrAFileGrepCannotReadIsUndecided() throws {
        let root = try Self.directory([
            "Sources/Open/A.swift": "let a = Name()\n",
            "Sources/Sealed/B.swift": "let b = Name()\n",
            "Other/C.swift": "let c = Name()\n",
            "Other/D.swift": "let d = Name()\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let sealed = root.appendingPathComponent("Sources/Sealed").path
        let locked = root.appendingPathComponent("Other/D.swift").path
        chmod(sealed, 0o311)
        chmod(locked, 0o000)
        defer {
            chmod(sealed, 0o755)
            chmod(locked, 0o644)
        }

        #expect(try Self.printed(["-rnw", "Name", "Sources"], in: root) == .undecided("unreadable"))
        #expect(try Self.printed(["-rnw", "--include=*.swift", "Name", "Sources"], in: root) == .undecided("unreadable"))
        #expect(try Self.printed(["-rnw", "Name", "Other"], in: root) == .undecided("unreadable"))
        #expect(try Self.lines(Self.printed(["-rnw", "Name", "Sources/Open"], in: root)) == [1])
    }

    /// Runs each search over each file both in-process and through `greps`, and checks every decided outcome against what each prints.
    private static func checkDecidedFiles(against greps: [SystemGrep], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let entry = "\"greeting\" = \"Welcome\";\nimport Foundation\n"
        let files: [String: Data] = [
            "Plain.swift": Data("import Foundation\nfunc go() {}\nlet greeting = 1\n".utf8),
            "Marked.swift": Data([0xEF, 0xBB, 0xBF]) + Data("import Foundation\nfunc go() {}\n".utf8),
            "Crlf.swift": Data("import Foundation\r\nfunc go() {}\r\n".utf8),
            "Little.strings": Data([0xFF, 0xFE]) + Data(entry.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
            "Big.strings": Data([0xFE, 0xFF]) + Data(entry.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }),
            "Nul.bin": Data("welcome\u{0}Title\nimport Foundation\n".utf8),
        ]
        let searches: [[String]] = [
            ["-w", "greeting"], ["^import"], ["-x", "import Foundation"], ["-w", "go"], ["Foundation$"], ["-i", "IMPORT"],
        ]
        let root = try directory([:])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, data) in files {
            try data.write(to: root.appendingPathComponent(name))
        }
        var decided = 0
        var undecided = 0
        for (name, _) in files {
            for search in searches {
                let arguments = ["-n"] + search + [name]
                guard case let .printed(lines) = try printed(arguments, in: root, sourceLocation: sourceLocation) else {
                    undecided += 1
                    continue
                }
                decided += 1
                for grep in greps {
                    let pattern = try #require(search.last, sourceLocation: sourceLocation)
                    let printedByGrep = try grep.lines(Array(search.dropLast()), pattern, root.appendingPathComponent(name))
                    #expect(Set(lines.map(\.line)) == printedByGrep, "\(grep) \(search) on \(name)", sourceLocation: sourceLocation)
                }
            }
        }
        // Both kinds occur, or the check would prove nothing about one of them.
        #expect(decided > 0 && undecided > 0, sourceLocation: sourceLocation)
    }
}
