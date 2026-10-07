//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A `private` or `fileprivate` member can be used only in its own file, so its name-matched sites are narrowed to that file; the answer says so, and counts what it dropped.
@Suite(.temporaryDirectories)
struct WherePrivateNarrowingTests {
    private static func lookup(_ symbol: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Box {
                private var secret = 2
                fileprivate func shake() {}
                func total() -> Int { secret }
            }

            extension Box {
                func twice() -> Int { shake(); return secret * 2 }
            }

            func probe(_ other: Other) -> Int { other.secret }
            """,
            to: "Sources/Lib/Box.swift",
            in: root
        )
        try TestSources.write(
            """
            struct Other {
                var secret = 3
                func read() -> Int { secret }
            }

            func poke() {
                let thing = factory()
                thing.shake()
                _ = thing.secret
            }
            """,
            to: "Sources/Lib/Other.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
    }

    @Test
    func aPrivatePropertysUsesInAnotherFileAreDroppedAndCounted() async throws {
        let output = try await Self.lookup("Box.secret")

        #expect(output.contains("\"secret\" (5 uses by name, 1 on other types dropped, 4 kept, narrowed to its declaring file, as it is private: 1 elsewhere dropped, 3 kept, in 1 file):"), "\(output)")
        #expect(output.contains(":8  in Box.twice()"), "\(output)")
        #expect(!output.contains("Sources/Lib/Other.swift"), "\(output)")
    }

    @Test
    func aFileprivateMethodIsNarrowedTheSameWay() async throws {
        let output = try await Self.lookup("Box.shake")

        #expect(output.contains("narrowed to its declaring file, as it is fileprivate: 1 elsewhere dropped, 1 kept"), "\(output)")
        #expect(!output.contains("Sources/Lib/Other.swift"), "\(output)")
    }

    @Test
    func anInternalPropertyIsNotNarrowed() async throws {
        let output = try await Self.lookup("Other.secret")

        #expect(!output.contains("narrowed to its declaring file"), "\(output)")
        #expect(output.contains("Sources/Lib/Box.swift:"), "\(output)")
        #expect(output.contains("Sources/Lib/Other.swift:"), "\(output)")
    }

    /// The first five private declarations are all the store is asked about, but an internal one past them is still a declaration the name's list stands for, so nothing is narrowed and its use in another file stays listed.
    @Test
    func anInternalDeclarationPastTheCapKeepsItsUseElsewhere() async throws {
        let root = try TestSources.makeTempRepo()
        for index in 1 ... 5 {
            try TestSources.write(
                "struct Tray\(index) {\n    private var secret = \(index)\n    func read() -> Int { secret }\n}\n",
                to: "Sources/Lib/Tray\(index).swift",
                in: root
            )
        }
        try TestSources.write("struct Zone {\n    var secret = 0\n}\n", to: "Sources/Lib/Zone.swift", in: root)
        try TestSources.write("func peek() -> Int {\n    Zone().secret\n}\n", to: "Sources/Lib/Zuse.swift", in: root)
        try TestSources.commitAll(in: root, message: "five private declarations, then an internal one")
        let engine = try SiftEngine(directory: root)
        let output = try await engine.lookup(symbol: "secret", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

        #expect(!output.contains("narrowed to its declaring file"), "\(output)")
        #expect(output.contains("Sources/Lib/Zuse.swift:"), "\(output)")
    }
}
