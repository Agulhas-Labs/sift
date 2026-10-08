//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers removing the build `run --without` made without the change: only that one directory and its mark go, never what is beside it or what a link in its place points at, and the receipt says it went.
@Suite(.temporaryDirectories)
struct WithoutBuildCleanupTests {
    /// Discarding removes the build directory and the mark that would have it built on, and leaves the other tool's build directory and the rest of `.sift/` alone.
    @Test
    func discardingRemovesTheBuildAndItsMarkAndNothingBesideThem() throws {
        let root = try TemporaryDirectory.make("without-build")
        let build = RunWithoutBuild(repositoryRoot: root, workingDirectory: root, arguments: ["swift", "test", "--filter", "WidgetTests"])
        try FileManager.default.createDirectory(at: build.directory.appendingPathComponent("debug"), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: build.directory.appendingPathComponent("debug/object.o"))
        build.keep()
        let beside = [".sift/without-build/xcodebuild/object.o", ".sift/set-aside/record.json"].map { root.appendingPathComponent($0) }
        for url in beside {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: url)
        }

        build.discard()

        #expect(build.isRemoved)
        #expect(!FileManager.default.fileExists(atPath: build.finished.path), "a mark left behind would have the next run build on nothing")
        for url in beside {
            #expect(FileManager.default.fileExists(atPath: url.path), "removed beside the build: \(url.path)")
        }
        build.discard()
        #expect(build.isRemoved, "discarding twice is harmless")
    }

    /// A build directory that is a link to somewhere else is never followed: what it points at is left whole, and the directory is not reported removed.
    @Test
    func aBuildDirectoryThatLinksElsewhereIsNotFollowed() throws {
        let root = try TemporaryDirectory.make("without-build")
        let build = RunWithoutBuild(repositoryRoot: root, workingDirectory: root, arguments: ["swift", "test", "--filter", "WidgetTests"])
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: elsewhere.appendingPathComponent("object.o"))
        try FileManager.default.createDirectory(at: build.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: build.directory, withDestinationURL: elsewhere)

        build.discard()

        #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("object.o").path), "a link in the build directory's place was followed")
        #expect(!build.isRemoved, "a directory left in place is not reported as removed")
    }

    /// A build the run removed is said to be removed, with its size when one was measured, and with no `rm -rf` to run.
    @Test
    func theReceiptSaysTheBuildWasRemoved() {
        let measured = RunWithoutAnswerTests.judged(
            without: RunWithoutAnswerTests.run(["shoutingWorks()": false]),
            with: RunWithoutAnswerTests.run(["shoutingWorks()": true]),
            buildDirectory: "/nonexistent/.sift/without-build/swiftpm",
            buildDirectorySize: 1_234_567,
            buildDirectoryRemoved: true
        ).render().text
        let unmeasured = RunWithoutAnswerTests.judged(
            without: RunWithoutAnswerTests.run(["shoutingWorks()": false]),
            with: RunWithoutAnswerTests.run(["shoutingWorks()": true]),
            buildDirectory: "/nonexistent/.sift/without-build/swiftpm",
            buildDirectoryRemoved: true
        ).render().text

        #expect(measured.contains("; built without the change in a scratch build (1.2 MB, removed)"), "\(measured)")
        #expect(unmeasured.contains("; built without the change in a scratch build (removed)"), "\(unmeasured)")
        #expect(!measured.contains("rm -rf"), "\(measured)")
    }

    /// Each place a link above the build directory can stand, and where it points: `absolute` for the whole path, or relative to the link's own directory.
    static let parentLinks: [(link: String, destination: String)] = [
        (".sift", "absolute"),
        (".sift", "elsewhere"),
        (".sift/without-build", "absolute"),
        (".sift/without-build", "../elsewhere"),
    ]

    /// `.sift` or `.sift/without-build` linked to `elsewhere`, which holds a build and its mark where the link leads, and the build for that checkout.
    private static func linkedCheckout(_ link: String, to destination: String) throws -> (build: RunWithoutBuild, kept: [URL]) {
        let root = try TemporaryDirectory.make("without-build")
        let elsewhere = root.appendingPathComponent("elsewhere")
        let below = link == ".sift" ? "without-build/" : ""
        let kept = [elsewhere.appendingPathComponent("\(below)swiftpm/sentinel"), elsewhere.appendingPathComponent("\(below)swiftpm.finished")]
        for url in kept {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("precious".utf8).write(to: url)
        }
        let place = root.appendingPathComponent(link)
        try FileManager.default.createDirectory(at: place.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: place.path, withDestinationPath: destination == "absolute" ? elsewhere.path : destination)
        let build = RunWithoutBuild(repositoryRoot: root, workingDirectory: root, arguments: ["swift", "test", "--filter", "WidgetTests"])
        return (build, kept)
    }

    /// A link above the build directory, absolute or relative, is never followed by discarding: what it points at, build and mark, is left whole.
    @Test(arguments: parentLinks)
    func discardingNeverFollowsALinkAboveTheBuild(_ link: String, _ destination: String) throws {
        let (build, kept) = try Self.linkedCheckout(link, to: destination)

        build.discard()

        #expect(!build.isRemoved, "\(link) → \(destination): a build left in place is not reported as removed")
        for url in kept {
            #expect(FileManager.default.fileExists(atPath: url.path), "\(link) → \(destination): followed, and removed \(url.lastPathComponent)")
        }
    }

    /// Readying the build refuses a link above it, naming the link, and removes nothing through it.
    @Test(arguments: parentLinks)
    func preparingRefusesALinkAboveTheBuild(_ link: String, _ destination: String) throws {
        let (build, kept) = try Self.linkedCheckout(link, to: destination)

        let refusal = #expect(throws: RunWithoutBuild.Linked.self) {
            try build.prepare()
        }

        #expect(refusal?.link == link, "\(link) → \(destination)")
        for url in kept {
            #expect(FileManager.default.fileExists(atPath: url.path), "\(link) → \(destination): followed, and removed \(url.lastPathComponent)")
        }
    }
}
