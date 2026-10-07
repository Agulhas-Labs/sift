//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// `--coverage` on an `xcodebuild test` line, and `diff --coverage`, as the command line takes them.
@Suite(.temporaryDirectories)
struct RunCoverageXcodebuildTests {
    @Test func coverageAndAResultBundleAreAddedOnlyWhereTheLineDoesNotSayThem() {
        let plain = ["xcodebuild", "test", "-scheme", "Gizmo"]
        #expect(RunCoverage.enabling(plain, run: "7") == plain + ["-enableCodeCoverage", "YES", "-resultBundlePath", ".sift/coverage-7.xcresult"])

        let named = ["xcodebuild", "test", "-scheme", "Gizmo", "-enableCodeCoverage", "YES", "-resultBundlePath", "out/run.xcresult"]
        #expect(RunCoverage.enabling(named) == named)
        #expect(XcodebuildCoverage.bundlePath(of: named, in: URL(fileURLWithPath: "/repo")) == URL(fileURLWithPath: "/repo/out/run.xcresult"))
    }

    @Test func aLineWhoseCoverageCannotBeTiedToThisBuildIsRefusedBeforeItRuns() throws {
        let validate = { (line: [String]) in
            try RunCoverage.validate(RunCoverage.enabling(line), coverage: true, from: nil, setsAside: false, restoresOrProves: false)
        }
        try validate(["xcodebuild", "test", "-scheme", "Gizmo"])
        try validate(["xcodebuild", "test", "-scheme", "Gizmo", "-enableCodeCoverage", "yes"])
        try validate(["xcodebuild", "test", "-scheme", "Gizmo", "-enableCodeCoverage", "Yes"])

        #expect(throws: ValidationError.self) { try validate(["xcodebuild", "test-without-building", "-scheme", "Gizmo"]) }
        #expect(throws: ValidationError.self) { try validate(["xcodebuild", "test", "-xctestrun", "a.xctestrun"]) }
        #expect(throws: ValidationError.self) { try validate(["xcodebuild", "build", "-scheme", "Gizmo"]) }
        #expect(throws: ValidationError.self) { try validate(["xcodebuild", "test", "-enableCodeCoverage", "NO"]) }
    }

    @Test func onlyTheBundleThisRunNamedIsClearedAndAnotherRunsIsLeftAlone() throws {
        let directory = try TemporaryDirectory.make("bundles")
        let own = directory.appendingPathComponent(XcodebuildCoverage.ownResultBundle(run: "7"))
        let other = directory.appendingPathComponent(XcodebuildCoverage.ownResultBundle(run: "8"))
        let named = directory.appendingPathComponent("mine.xcresult")
        for bundle in [own, other, named] {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        }

        XcodebuildCoverage.clearOwnResultBundle(for: ["xcodebuild", "test", "-resultBundlePath", "mine.xcresult"], in: directory, run: "7")
        #expect(FileManager.default.fileExists(atPath: named.path))
        #expect(FileManager.default.fileExists(atPath: own.path))
        XcodebuildCoverage.clearOwnResultBundle(for: XcodebuildCoverage.enabling(["xcodebuild", "test"], run: "7"), in: directory, run: "7")
        #expect(!FileManager.default.fileExists(atPath: own.path))
        #expect(FileManager.default.fileExists(atPath: other.path), "a concurrent run's bundle is not this run's to delete")
        #expect(FileManager.default.fileExists(atPath: named.path))
    }

    @Test func aBundleIsAbandonedOnlyPastTheWindowAndOnlyUnderTheToolsOwnName() {
        let now = Date()
        let old = now.addingTimeInterval(-2 * RunLedger.trustWindow)
        let fresh = now.addingTimeInterval(-60)
        let entries = [("coverage-1.xcresult", old), ("coverage-2.xcresult", fresh), ("mine.xcresult", old), ("coverage.xcresult", old), ("coverage-x.xcresult", old)]

        #expect(XcodebuildCoverage.abandonedBundles(among: entries, now: now) == ["coverage-1.xcresult"])
        #expect(!XcodebuildCoverage.writesOwnResultBundle(["xcodebuild", "test", "-resultBundlePath", ".sift/coverage-8.xcresult"], run: "7"))
        #expect(!XcodebuildCoverage.writesOwnResultBundle(["xcodebuild", "test", "-resultBundlePath", "out/coverage-7.xcresult"], run: "7"))
    }

    @Test func aChangedFileXccovDidNotListIsNotMeasuredWhateverSitsBesideIt() {
        let root = URL(fileURLWithPath: "/repo")
        let counts = ["/repo/Sources/Shared/Used.swift": [3: UInt64(2)]]
        let listed = ["/repo/Sources/Shared/Used.swift", "/repo/Sources/Shared/Protocols.swift"]

        let matched = XcodebuildCoverage.matching(
            ["Sources/Shared/Used.swift", "Sources/Shared/Other.swift", "Sources/Shared/Protocols.swift"], root: root, counts: counts, listed: listed
        )

        #expect(matched == ["Sources/Shared/Used.swift": [3: 2], "Sources/Shared/Protocols.swift": [:]])
    }

    @Test func diffCoverageAppendsTheSectionAndTakesNoRange() async throws {
        let repository = try MCPTestRepo.make()
        let registry = try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))

        let (text, refused) = try await DiffCommand.parse(["--coverage", "--root", repository.path]).answer(registry: registry)

        #expect(!refused)
        #expect(text.split(separator: "\n").last?.hasPrefix("coverage: none recorded") == true)
        await #expect(throws: ValidationError.self) {
            try await DiffCommand.parse(["HEAD~1..HEAD", "--coverage", "--root", repository.path]).answer(registry: registry)
        }
    }
}
