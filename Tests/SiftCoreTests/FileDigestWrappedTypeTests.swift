//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a file digest whose file holds one type declared inside an extension of its namespace, and the files around that shape that keep the nested naming.
///
/// A file digest is the locating step, so the members of a file that is in effect one type must come back with their ranges. Cutting them to a handful of names sends the caller back for a second digest of the type.
@Suite(.temporaryDirectories)
struct FileDigestWrappedTypeTests {
    /// A type body of `count` methods, each six lines long, so a file of them is large enough to keep its digest.
    private static func methods(_ count: Int, named prefix: String) -> String {
        (0 ..< count).map { index in
            """
                    func \(prefix)\(index)() -> Int {
                        let first = \(index)
                        let second = first * 2
                        let third = second + first
                        return third
                    }
            """
        }.joined(separator: "\n")
    }

    private static func wrapped(_ name: String, methods count: Int) -> String {
        "extension Audit {\n    struct \(name) {\n\(methods(count, named: name.lowercased()))\n    }\n}\n"
    }

    /// The non-struct twin of `wrapped(_:methods:)`, to pin the same treatment for an enum.
    private static func wrappedEnum(_ name: String, methods count: Int) -> String {
        "extension Audit {\n    enum \(name) {\n\(methods(count, named: name.lowercased()))\n    }\n}\n"
    }

    /// `count` swift-testing functions, each calling the fixture's own `call` helper, long enough that a file of them clears the compression floor and is answered as a digest rather than as its own source.
    private static func suiteTests(_ count: Int, prefixed prefix: String) -> String {
        (0 ..< count).map { index in
            """
                    @Test
                    func \(prefix)\(index)() throws {
                        var total = 0
                        for step in 0 ..< 6 {
                            total += step
                        }
                        #expect(Self.call("go") == "GO")
                        #expect(total == 15)
                    }
            """
        }.joined(separator: "\n\n")
    }

    private static func fileDigest(of source: String) throws -> String {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let parsed = try TestSources.parsed(source, path: "Sources/Alpha/Audit.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
        return try renderer.render(target: "Sources/Alpha/Audit.swift", options: DigestOptions())
    }

    @Test
    func aFilesOnlyTypeInsideAnExtensionListsEveryMemberWithItsRange() throws {
        let output = try Self.fileDigest(of: Self.wrapped("Redaction", methods: 20))

        #expect(output.contains("extension Audit — 1 members  :1-124"))
        #expect(output.contains("\n    struct Redaction — 20 members  :2-123\n"))
        #expect(output.contains("\n        func redaction0() -> Int  :3-8\n"))
        #expect(output.contains("\n        func redaction19() -> Int  :117-122"))
        #expect(!output.contains("more"))
    }

    @Test
    func twoTypesInsideExtensionsKeepTheirMembersNamedOnTheirOwnLine() throws {
        let output = try Self.fileDigest(of: Self.wrapped("First", methods: 20) + Self.wrapped("Second", methods: 20))

        #expect(output.contains("struct First — 20 members: first0() first1() first2()"))
        #expect(output.contains("struct Second — 20 members: second0() second1() second2()"))
        #expect(!output.contains("        func "))
    }

    @Test
    func aTypeInsideAnExtensionBesideATopLevelTypeKeepsItsMembersNamed() throws {
        let output = try Self.fileDigest(of: "struct Audit {\n    let level: Int\n}\n" + Self.wrapped("Redaction", methods: 20))

        #expect(output.contains("struct Redaction — 20 members: redaction0() redaction1()"))
        #expect(!output.contains("        func "))
    }

    @Test
    func anEnumeratedWrappedTypeStillStopsAtTheMemberCap() throws {
        let output = try Self.fileDigest(of: Self.wrapped("Redaction", methods: 70))

        #expect(output.contains("\n        func redaction57() -> Int"))
        #expect(!output.contains("func redaction58()"))
        #expect(output.contains("truncated: 12 more member lines"))
    }

    /// A wrapped type's own `@Suite` is classified the same way a top-level suite is: its last test is recorded and its helper's source is eligible for inlining, not just listed by signature.
    @Test
    func aSuiteInsideAnExtensionNamesItsOwnLastTestAndInlinesItsHelper() throws {
        let output = try Self.fileDigest(of: """
        import Testing

        extension Audit {
            @Suite
            struct Redaction {
                private static func call(_ command: String) -> String {
                    command.uppercased()
                }

        \(Self.suiteTests(12, prefixed: "redaction"))
            }
        }
        """)

        #expect(output.contains("last test in Redaction: redaction11() —"))
        #expect(output.contains("command.uppercased()"))
    }

    /// The wrapped type's own members are enumerated with their ranges for an enum too, not only a struct.
    @Test
    func aFilesOnlyTypeInsideAnExtensionIsAnEnumListsEveryMemberWithItsRange() throws {
        let output = try Self.fileDigest(of: Self.wrappedEnum("Redaction", methods: 20))

        #expect(output.contains("extension Audit — 1 members  :1-124"))
        #expect(output.contains("\n    enum Redaction — 20 cases/members  :2-123\n"))
        #expect(output.contains("\n        func redaction0() -> Int  :3-8\n"))
        #expect(output.contains("\n        func redaction19() -> Int  :117-122"))
    }
}
