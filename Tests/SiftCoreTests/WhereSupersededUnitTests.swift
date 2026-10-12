//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A store holding two configurations' units for one file answers from the units that describe the file as it stands, against really-built stores.
///
/// Native builds passing one `-index-store-path` write the debug and release units into one store, as an Xcode store keeps one per architecture: a unit no build replaced since the file was edited still records the old content's lines.
@Suite(.temporaryDirectories)
struct WhereSupersededUnitTests {
    private static let native = ["--build-system", "native"]

    /// A package whose `Lantern.glow()` is called from `shine()`, committed and not yet built.
    private static func makeRepo(lantern: String) throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])\n",
            to: "Package.swift",
            in: root
        )
        try TestSources.write(lantern, to: "Sources/Lib/Lantern.swift", in: root)
        try TestSources.commitAll(in: root, message: "lantern")
        return root
    }

    /// What `where` says about `Lantern.glow()`, from an engine opened after the last build.
    private static func glowAnswer(in root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        return try await engine.lookup(symbol: "Lantern.glow", freshness: engine.ensureFresh())
    }

    /// The debug unit is built before the edit that moves the call down two lines and the release unit after it, so the debug unit still records the call at its old line, where the file now holds a blank one.
    @Test
    func aCallerRecordedOnlyByAConfigurationBuiltBeforeTheEditIsNotListed() async throws {
        let root = try Self.makeRepo(lantern: """
        public struct Lantern {
            public init() {}
            public func glow() -> Int { 1 }
            public func shine() -> Int {
                glow()
            }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        try TestSources.write("""
        public struct Lantern {
            public init() {}
            public func glow() -> Int { 1 }


            public func shine() -> Int {
                glow()
            }
        }
        """, to: "Sources/Lib/Lantern.swift", in: root)
        try TestSources.commitAll(in: root, message: "moved")
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native + ["-c", "release"])

        let answer = try await Self.glowAnswer(in: root)
        let located = WhereStoreSiteTextTests.located(answer)

        #expect(answer.contains("semantic: fresh"), "\(answer)")
        #expect(answer.contains("callers of Lib.Lantern.glow() (1):"), "\(answer)")
        #expect(located.contains("Sources/Lib/Lantern.swift:7  shine()  | glow()"), "\(answer)")
        #expect(!located.contains("Sources/Lib/Lantern.swift:5"), "the debug unit built before the edit answered: \(answer)")
    }

    /// Both configurations are built after the file's last change, the debug one first, and only it compiles the call: an older unit that still describes the file answers beside the newest.
    @Test
    func aCallOnlyTheOlderOfTwoCurrentConfigurationsCompilesIsListed() async throws {
        let root = try Self.makeRepo(lantern: """
        public struct Lantern {
            public init() {}
            public func glow() -> Int { 1 }
            public func shine() -> Int {
                #if DEBUG
                return glow()
                #else
                return 0
                #endif
            }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native + ["-c", "release"])

        let answer = try await Self.glowAnswer(in: root)

        #expect(answer.contains("semantic: fresh"), "\(answer)")
        #expect(answer.contains("callers of Lib.Lantern.glow() (1):"), "\(answer)")
        #expect(WhereStoreSiteTextTests.located(answer).contains("Sources/Lib/Lantern.swift:6  shine()  | return glow()"), "\(answer)")
    }

    /// `shine()` calls `glow()` only under `#if DEBUG`; the edit lands between the debug and the release build, so the one unit that records the call is older than the file's last edit and its site is set aside, which the answer says rather than reading as a definitive absence.
    @Test
    func aCallerSetAsideForAStaleUnitIsSaidAndNoCallersIsNotDefinitive() async throws {
        let root = try Self.makeRepo(lantern: Self.debugOnlyCaller(blankLines: 0))
        defer { try? FileManager.default.removeItem(at: root) }
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        try TestSources.write(Self.debugOnlyCaller(blankLines: 2), to: "Sources/Lib/Lantern.swift", in: root)
        try TestSources.commitAll(in: root, message: "moved")
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native + ["-c", "release"])

        let answer = try await Self.glowAnswer(in: root)

        #expect(answer.contains("semantic: fresh"), "\(answer)")
        #expect(answer.contains("1 site in Sources/Lib/Lantern.swift set aside: recorded only by a build older than the file's last edit"), "\(answer)")
        #expect(answer.contains("no callers of Lib.Lantern.glow() recorded in the current builds"), "\(answer)")
        #expect(!answer.contains("recorded in the store"), "\(answer)")
    }

    /// A caller in a file edited after the last build is still listed: the floor is the earlier of the file's newest unit and its change, so the unit that recorded the call, written before the edit, clears it.
    @Test
    func aCallerInAFileEditedAfterTheLastBuildIsStillListed() async throws {
        let root = try Self.makeRepo(lantern: "public struct Lantern {\n    public init() {}\n    public func glow() -> Int { 1 }\n}\n")
        try TestSources.write("public struct Keeper {\n    public init() {}\n    public func tend() -> Int {\n        Lantern().glow()\n    }\n}\n", to: "Sources/Lib/Keeper.swift", in: root)
        try TestSources.commitAll(in: root, message: "keeper")
        defer { try? FileManager.default.removeItem(at: root) }
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        try TestSources.write("public struct Keeper {\n    public init() {}\n    public func tend() -> Int {\n        Lantern().glow()\n    }\n}\n\n", to: "Sources/Lib/Keeper.swift", in: root)

        let answer = try await Self.glowAnswer(in: root)

        #expect(answer.contains("callers of Lib.Lantern.glow() (1, 1 file changed since last build):"), "\(answer)")
        #expect(WhereStoreSiteTextTests.located(answer).contains("Sources/Lib/Keeper.swift:4  tend()"), "\(answer)")
        #expect(!answer.contains("set aside"), "\(answer)")
    }

    /// The edit moves the call down two lines and the file's mtime is then put back to what it was: the change moment is still the later of mtime and ctime, so the debug unit built before the edit is told from the file as it stands.
    @Test
    func aCallerRecordedBeforeAnEditWhoseMtimeWasRestoredIsNotListed() async throws {
        let root = try Self.makeRepo(lantern: Self.plainCaller(blankLines: 0))
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sources/Lib/Lantern.swift")
        let original = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        try TestSources.write(Self.plainCaller(blankLines: 2), to: "Sources/Lib/Lantern.swift", in: root)
        try FileManager.default.setAttributes([.modificationDate: original], ofItemAtPath: file.path)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native + ["-c", "release"])

        let answer = try await Self.glowAnswer(in: root)
        let located = WhereStoreSiteTextTests.located(answer)

        #expect(located.contains("Sources/Lib/Lantern.swift:7  shine()  | glow()"), "\(answer)")
        #expect(!located.contains("Sources/Lib/Lantern.swift:5"), "the unit built before the edit answered: \(answer)")
    }

    private static func plainCaller(blankLines: Int) -> String {
        "public struct Lantern {\n    public init() {}\n    public func glow() -> Int { 1 }\n" + String(repeating: "\n", count: blankLines)
            + "    public func shine() -> Int {\n        glow()\n    }\n}\n"
    }

    private static func debugOnlyCaller(blankLines: Int) -> String {
        "public struct Lantern {\n    public init() {}\n    public func glow() -> Int { 1 }\n" + String(repeating: "\n", count: blankLines)
            + "    public func shine() -> Int {\n        #if DEBUG\n        return glow()\n        #else\n        return 0\n        #endif\n    }\n}\n"
    }
}
