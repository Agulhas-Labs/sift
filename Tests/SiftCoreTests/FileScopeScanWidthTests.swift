//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the file-scope macro scan read several files at a time: its verdict is the one a scan reading each file in turn gives, wherever the file holding such a macro sits, however many do, and in whatever order the reads finish.
@Suite(.temporaryDirectories)
struct FileScopeScanWidthTests {
    /// A file the scan parses that holds nothing at file scope a macro may declare a name with: a `@Test` under its import.
    private static func quiet(_ index: Int) -> String {
        "import Testing\n@Test func anchor\(index)() {}\n"
    }

    /// A file-scope declaration carrying another package's attribute, which may add any name beside it.
    private static var blocking: String {
        "@Aliased func anchor() {}\n"
    }

    /// A tree's declaration of a macro named `name`: one named `Test` makes every other file's `@Test` maybe another module's.
    private static func declaring(_ name: String) -> String {
        "@attached(peer) public macro \(name)(tag: Int) = #externalMacro(module: \"DepotKit\", type: \"Stamp\")\n"
    }

    /// `count` quiet files, with `sources` written in place of the files at their indices.
    private static func tree(_ count: Int, with sources: [Int: String] = [:]) -> [String] {
        (0 ..< count).map { sources[$0] ?? quiet($0) }
    }

    /// Whether the files of `sources`, written into a fresh repo, expand at file scope, scanned `width` at a time in the order given.
    private static func expands(_ sources: [String], width: Int, reversed: Bool = false) async throws -> Bool {
        let root = try TestSources.makeTempRepo()
        var paths: [String] = []
        for (index, source) in sources.enumerated() {
            let path = "Sources/Lib/f\(index).swift"
            try TestSources.write(source, to: path, in: root)
            paths.append(path)
        }
        return await BareNameOutsideTypes.expandsAtFileScope(paths: reversed ? paths.reversed() : paths, under: root, width: width)
    }

    /// The blocking file first, in the middle, last, many of them, or none, and a macro `Test` declared in one file while the others write `@Test`: one file at a time, the serial scan, gives what several at a time do, either way round.
    @Test
    func theVerdictIsTheSerialScansWhereverTheBlockingFileSits() async throws {
        let cases: [String: (sources: [String], expands: Bool)] = [
            "none": (Self.tree(12), false),
            "first": (Self.tree(12, with: [0: Self.blocking]), true),
            "middle": (Self.tree(12, with: [6: Self.blocking]), true),
            "last": (Self.tree(12, with: [11: Self.blocking]), true),
            "many": (Self.tree(12, with: [1: Self.blocking, 4: Self.blocking, 7: Self.blocking, 10: Self.blocking]), true),
            "a macro of the name declared in another file": (Self.tree(12, with: [2: Self.declaring("Test")]), true),
            "a macro of another name declared": (Self.tree(12, with: [2: Self.declaring("Stamp")]), false),
        ]
        for (name, scanned) in cases.sorted(by: { $0.key < $1.key }) {
            for width in [1, 3, 64] {
                for reversed in [false, true] {
                    let expands = try await Self.expands(scanned.sources, width: width, reversed: reversed)

                    #expect(expands == scanned.expands, "\(name), width \(width), reversed \(reversed)")
                }
            }
        }
    }

    /// One blocking file among many, the last one read included, keeps the lines however the reads interleave.
    @Test
    func oneBlockingFileAmongManyKeepsTheLines() async throws {
        for position in [0, 97, 199] {
            let sources = Self.tree(200, with: [position: Self.blocking])
            for _ in 0 ..< 3 {
                let expands = try await Self.expands(sources, width: 4)

                #expect(expands, "blocking file at \(position)")
            }
        }
        let none = try await Self.expands(Self.tree(200), width: 4)

        #expect(!none)
    }

    /// A scan cancelled before it reads the files has not read that none blocks, so it says one may.
    @Test
    func aCancelledScanSaysOneMay() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.quiet(0), to: "Sources/Lib/f0.swift", in: root)

        let read = await BareNameOutsideTypes.expandsAtFileScope(paths: ["Sources/Lib/f0.swift"], under: root)
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await BareNameOutsideTypes.expandsAtFileScope(paths: ["Sources/Lib/f0.swift"], under: root)
        }.value

        #expect(!read)
        #expect(cancelled)
    }
}
