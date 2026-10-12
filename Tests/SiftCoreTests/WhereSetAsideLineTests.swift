//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Every answer path that reads a store's call sites says the sites it set aside as recorded only by a build older than their file's last edit, as the single-owner `where` answer does.
@Suite(.temporaryDirectories)
struct WhereSetAsideLineTests {
    private static let native = ["--build-system", "native"]
    private static var setAsideText: String {
        "set aside: recorded only by a build older than the file's last edit"
    }

    private static func package() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])\n",
            to: "Package.swift",
            in: root
        )
        try TestSources.write(".build\n", to: ".gitignore", in: root)
        return root
    }

    /// A struct whose `glow()` is called only under the debug condition, `padding` blank lines above the caller.
    private static func lantern(padding: Int, glow: String = "public func glow() -> Int { 1 }") -> String {
        "public struct Lantern {\n    public init() {}\n    \(glow)\n" + String(repeating: "\n", count: padding)
            + "    public func shine() -> Int {\n        #if DEBUG\n        return glow()\n        #else\n        return 0\n        #endif\n    }\n}\n"
    }

    /// The edited declaration: the same symbol with narrower access, a change a diff resolves rather than reads as a removal.
    private static var narrower: String {
        "func glow() -> Int { 1 }"
    }

    /// The same name declared by a second, unrelated struct, so a bare query for it has several owners.
    private static var torch: String {
        "public struct Torch {\n    public init() {}\n    public func glow() -> Int { 2 }\n}\n"
    }

    /// The debug configuration is built before the edit and the release one after it, so the only unit that records the debug-only call is older than its file's last edit.
    private static func buildAroundEdit(in root: URL, edit: () throws -> Void) async throws {
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: native)
        try edit()
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: native + ["-c", "release"])
    }

    /// A bare name two unrelated owners declare lists no uses, and says the sites it set aside beside its counts.
    @Test
    func severalOwnersSaysTheSitesSetAside() async throws {
        let root = try Self.package()
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSources.write(Self.lantern(padding: 0), to: "Sources/Lib/Lantern.swift", in: root)
        try TestSources.write(Self.torch, to: "Sources/Lib/Torch.swift", in: root)
        try TestSources.commitAll(in: root, message: "owners")
        try await Self.buildAroundEdit(in: root) {
            try TestSources.write(Self.lantern(padding: 2), to: "Sources/Lib/Lantern.swift", in: root)
        }

        let answer = try await Self.lookup("glow", in: root)

        #expect(answer.contains("under 2 owners"), "\(answer)")
        #expect(answer.contains("1 site in Sources/Lib/Lantern.swift \(Self.setAsideText)"), "\(answer)")
    }

    /// A diff's callers section says the sites set aside for a member whose signature changed.
    @Test
    func diffCallersSaysTheSitesSetAside() async throws {
        let root = try Self.package()
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSources.write(Self.lantern(padding: 0), to: "Sources/Lib/Lantern.swift", in: root)
        try TestSources.commitAll(in: root, message: "before")
        try await Self.buildAroundEdit(in: root) {
            try TestSources.write(Self.lantern(padding: 2, glow: Self.narrower), to: "Sources/Lib/Lantern.swift", in: root)
            try TestSources.commitAll(in: root, message: "after")
        }

        let output = try await DiffEngineTests.diff(root, range: "HEAD~1..HEAD")

        #expect(output.contains("resolved by the index store: 0 call sites"), "\(output)")
        #expect(output.contains("1 site in Sources/Lib/Lantern.swift \(Self.setAsideText)"), "\(output)")
    }

    /// A diff whose builds all follow the edit sets nothing aside and says nothing of it.
    @Test
    func diffCallersSaysNothingWhereNothingWasSetAside() async throws {
        let root = try Self.package()
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSources.write(Self.lantern(padding: 0), to: "Sources/Lib/Lantern.swift", in: root)
        try TestSources.commitAll(in: root, message: "before")
        try TestSources.write(Self.lantern(padding: 2, glow: Self.narrower), to: "Sources/Lib/Lantern.swift", in: root)
        try TestSources.commitAll(in: root, message: "after")
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native + ["-c", "release"])

        let output = try await DiffEngineTests.diff(root, range: "HEAD~1..HEAD")

        #expect(output.contains("resolved by the index store"), "\(output)")
        #expect(!output.contains("set aside"), "\(output)")
    }

    /// A property wrapper with two initializers, the first declared with `access`; only that first initializer's text changes between the two versions the tests commit, so the second keeps its identity.
    private static func clamp(access: String, value: String = "Int") -> String {
        """
        @propertyWrapper struct Clamp {
            var wrappedValue: \(value)
            \(access)init(wrappedValue: \(value)) { self.wrappedValue = wrappedValue }
            init(wrappedValue: \(value), step: Int) { self.wrappedValue = wrappedValue }
        }
        """
    }

    /// A struct whose `@Clamp(step:)` site is compiled only under the debug condition, `padding` blank lines above it, so the edit moves the attribute only where it changes the padding.
    private static func box(value: Int, padding: Int = 0) -> String {
        "struct Box {\n" + String(repeating: "\n", count: padding) + "    #if DEBUG\n    @Clamp(step: 2) var v = \(value)\n    #endif\n}\n"
    }

    /// The wrapper whose second initializer's attribute site only the debug build records, the first initializer edited, then built around the edit, which inserts `padding` lines above the site.
    private static func siblingFixture(in root: URL, padding: Int = 0) async throws {
        try TestSources.write(clamp(access: ""), to: "Sources/Lib/Clamp.swift", in: root)
        try TestSources.write(box(value: 1), to: "Sources/Lib/Box.swift", in: root)
        try TestSources.commitAll(in: root, message: "before")
        try await buildAroundEdit(in: root) {
            try TestSources.write(Self.clamp(access: "public "), to: "Sources/Lib/Clamp.swift", in: root)
            try TestSources.write(Self.box(value: 3, padding: padding), to: "Sources/Lib/Box.swift", in: root)
            try TestSources.commitAll(in: root, message: "after")
        }
    }

    /// The wrapper listing judges its sites against the references recorded to the wrapper's other initializers, so a diff of the first initializer says the one site set aside for its sibling.
    @Test
    func wrapperAttributeSitesSaysTheSitesSetAsideForASiblingInitializer() async throws {
        let root = try Self.package()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.siblingFixture(in: root)

        let output = try await DiffEngineTests.diff(root, range: "HEAD~1..HEAD")

        #expect(output.contains("resolved by the index store"), "\(output)")
        #expect(output.contains("1 site in Sources/Lib/Box.swift \(Self.setAsideText)"), "\(output)")
    }

    /// The single-owner answer for the first initializer says the one attribute site left out for its sibling, once.
    @Test
    func singleOwnerWrapperAnswerSaysTheSitesSetAside() async throws {
        let root = try Self.package()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.siblingFixture(in: root)

        let answer = try await Self.lookup("Clamp.init(wrappedValue:)", in: root)

        #expect(answer.contains("1 site in Sources/Lib/Box.swift \(Self.setAsideText)"), "\(answer)")
        #expect(answer.components(separatedBy: Self.setAsideText).count == 2, "\(answer)")
    }

    /// An attribute site only the debug build records is still said set aside once the edit inserts lines above it, though the line that build recorded is no longer the site's.
    @Test
    func wrapperSiteMovedSinceTheStaleBuildIsStillSetAside() async throws {
        let root = try Self.package()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.siblingFixture(in: root, padding: 2)

        let answer = try await Self.lookup("Clamp.init(wrappedValue:)", in: root)
        let output = try await DiffEngineTests.diff(root, range: "HEAD~1..HEAD")

        #expect(answer.contains("1 site in Sources/Lib/Box.swift \(Self.setAsideText)"), "\(answer)")
        #expect(output.contains("1 site in Sources/Lib/Box.swift \(Self.setAsideText)"), "\(output)")
    }

    /// A stale file that only names the wrapper type holds no attribute site, so a diff of the wrapper's initializers has none to say it set aside.
    @Test
    func wrapperTypeReferenceInAStaleFileIsNoSetAsideSite() async throws {
        let root = try Self.package()
        defer { try? FileManager.default.removeItem(at: root) }
        let holder = "struct Holder {\n    #if DEBUG\n    var c: Clamp? = nil\n    #endif\n}\n"
        try TestSources.write(Self.clamp(access: ""), to: "Sources/Lib/Clamp.swift", in: root)
        try TestSources.write(holder, to: "Sources/Lib/Holder.swift", in: root)
        try TestSources.commitAll(in: root, message: "before")
        try await Self.buildAroundEdit(in: root) {
            try TestSources.write(Self.clamp(access: "", value: "Int64"), to: "Sources/Lib/Clamp.swift", in: root)
            try TestSources.write(holder + "\n", to: "Sources/Lib/Holder.swift", in: root)
            try TestSources.commitAll(in: root, message: "after")
        }

        let output = try await DiffEngineTests.diff(root, range: "HEAD~1..HEAD")

        #expect(output.contains("resolved by the index store"), "\(output)")
        #expect(!output.contains("set aside"), "\(output)")
    }

    /// An attribute added since the stale build, in a file whose only set-aside line is a debug-only reference to the wrapper type, is no set-aside site of either initializer.
    @Test
    func wrapperAttributeAddedBesideAStaleTypeReferenceIsNoSetAsideSite() async throws {
        let root = try Self.package()
        defer { try? FileManager.default.removeItem(at: root) }
        let holder = { (added: String) in "struct Holder {\n    #if DEBUG\n    let probe: Clamp? = nil\n\(added)    #endif\n}\n" }
        try TestSources.write(Self.clamp(access: ""), to: "Sources/Lib/Clamp.swift", in: root)
        try TestSources.write(holder(""), to: "Sources/Lib/Holder.swift", in: root)
        try TestSources.commitAll(in: root, message: "before")
        try await Self.buildAroundEdit(in: root) {
            try TestSources.write(Self.clamp(access: "", value: "Int64"), to: "Sources/Lib/Clamp.swift", in: root)
            try TestSources.write(holder("    @Clamp var added: Int64 = 1\n"), to: "Sources/Lib/Holder.swift", in: root)
            try TestSources.commitAll(in: root, message: "after")
        }

        let output = try await DiffEngineTests.diff(root, range: "HEAD~1..HEAD")

        #expect(output.contains("resolved by the index store"), "\(output)")
        #expect(!output.contains("set aside"), "\(output)")
    }

    /// A name two unrelated owners declare as kinds the store is not asked about lists no uses, and so says nothing of sites it never counted.
    @Test
    func severalOwnersSaysNothingOfAKindItNeverCounted() async throws {
        let root = try Self.package()
        defer { try? FileManager.default.removeItem(at: root) }
        func source(padding: Int) -> String {
            "public protocol Lamp {\n    associatedtype Wick\n}\npublic protocol Taper {\n    associatedtype Wick\n}\n" + String(repeating: "\n", count: padding)
                + "extension Lamp {\n    func trim(_ wick: Wick) {}\n    #if DEBUG\n    func snuff(_ wick: Wick?) {}\n    #endif\n}\n"
        }
        try TestSources.write(source(padding: 0), to: "Sources/Lib/Lamp.swift", in: root)
        try TestSources.commitAll(in: root, message: "owners")
        try await Self.buildAroundEdit(in: root) {
            try TestSources.write(source(padding: 2), to: "Sources/Lib/Lamp.swift", in: root)
        }

        let answer = try await Self.lookup("Wick", in: root)

        #expect(answer.contains("under 2 owners"), "\(answer)")
        #expect(!answer.contains("set aside"), "\(answer)")
    }

    /// One symbol set aside in two stores counts in each, and in one store counts once however many readers note it.
    @Test
    func setAsideSitesSumAcrossStoresAndCountEachSymbolOncePerStore() {
        var sites = SetAsideSites()
        let first = ["/r/A.swift": [3: 1, 9: 1]]
        sites.note(ofUSR: "s:x", inStore: "one", first) { $0.replacingOccurrences(of: "/r/", with: "") }
        sites.note(ofUSR: "s:x", inStore: "one", first) { $0.replacingOccurrences(of: "/r/", with: "") }
        sites.note(ofUSR: "s:x", inStore: "two", ["/r/A.swift": [20: 1]]) { $0.replacingOccurrences(of: "/r/", with: "") }

        #expect(sites.line?.hasPrefix("3 sites in A.swift") == true, "\(sites.line ?? "nil")")
    }

    /// One source site two stale stores both record for a symbol counts once, not once per store.
    @Test
    func aSiteTwoStoresRecordCountsOnce() {
        var sites = SetAsideSites()
        sites.note(ofUSR: "s:x", inStore: "one", ["/r/A.swift": [3: 1]]) { $0.replacingOccurrences(of: "/r/", with: "") }
        sites.note(ofUSR: "s:x", inStore: "two", ["/r/A.swift": [3: 1]]) { $0.replacingOccurrences(of: "/r/", with: "") }

        #expect(sites.line?.hasPrefix("1 site in A.swift") == true, "\(sites.line ?? "nil")")
    }

    /// A wrapper site already counted among a symbol's own references is not counted again by the merged wrapper tally.
    @Test
    func wrapperSiteAlreadyCountedForASymbolIsCountedOnce() {
        var own = SetAsideSites()
        own.note(ofUSR: "s:x", inStore: "one", ["/r/A.swift": [3: 1]]) { $0.replacingOccurrences(of: "/r/", with: "") }
        var wrapper = SetAsideSites()
        wrapper.noteWrapperSites(path: "A.swift", unexplained: [3, 8], setAside: [3, 8])
        own.merge(wrapper)

        #expect(own.line?.hasPrefix("2 sites in A.swift") == true, "\(own.line ?? "nil")")
    }

    private static func lookup(_ symbol: String, in root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
    }
}
