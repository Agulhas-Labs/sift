//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers where `run --without` builds the tree with the change set aside: a build directory of its own, handed to the tool in place of any the command named, and built on again only after a build of the same package or scheme that reached its tests.
@Suite(.temporaryDirectories)
struct RunWithoutBuildTests {
    /// `swift test` builds in `.sift/without-build/swiftpm`, named straight after the subcommand, with the rest of the command as it was — wherever the subcommand falls, since a flag can come before it.
    @Test
    func aSwiftTestRunBuildsInADirectoryOfItsOwn() throws {
        let root = try TemporaryDirectory.make("without-build")
        let build = RunWithoutBuild(repositoryRoot: root, workingDirectory: root, arguments: ["swift", "test", "--filter", "WidgetTests"])
        let directory = root.appendingPathComponent(".sift/without-build/swiftpm").path

        #expect(build.directory.path == directory)
        #expect(build.shownDirectory == ".sift/without-build/swiftpm")
        #expect(build.rewrittenArguments == ["swift", "test", "--scratch-path", directory, "--filter", "WidgetTests"])

        let withAFlagBeforeTheSubcommand = RunWithoutBuild(repositoryRoot: root, workingDirectory: root, arguments: ["swift", "-v", "test", "--filter", "WidgetTests"])
        #expect(withAFlagBeforeTheSubcommand.rewrittenArguments == ["swift", "-v", "test", "--scratch-path", directory, "--filter", "WidgetTests"])
    }

    /// The directory is named from where the command runs, as the answer's receipt names it: relative from the repository root, and by its whole path from a subdirectory, where the relative spelling would name a directory that does not exist.
    @Test
    func theDirectoryIsNamedFromWhereTheCommandRuns() throws {
        let root = try TemporaryDirectory.make("without-build")
        let arguments = ["swift", "test", "--filter", "WidgetTests"]
        let fromTheRoot = RunWithoutBuild(repositoryRoot: root, workingDirectory: root, arguments: arguments)
        let fromASubdirectory = RunWithoutBuild(repositoryRoot: root, workingDirectory: root.appendingPathComponent("Packages/Kit"), arguments: arguments)

        #expect(fromTheRoot.shownDirectory == ".sift/without-build/swiftpm")
        #expect(fromASubdirectory.shownDirectory == root.appendingPathComponent(".sift/without-build/swiftpm").path)
    }

    /// A build location the command named is the caller's own build, so the run without the change drops it for its own — whichever spelling named it.
    @Test(arguments: [
        ["--scratch-path", "elsewhere"],
        ["--scratch-path=elsewhere"],
        ["--build-path", "elsewhere"],
        ["--build-path=elsewhere"],
    ])
    func aScratchPathTheCommandNamedIsReplaced(_ named: [String]) throws {
        let root = try TemporaryDirectory.make("without-build")
        let arguments = ["swift", "test"] + named + ["--filter", "WidgetTests"]
        let build = RunWithoutBuild(repositoryRoot: root, workingDirectory: root, arguments: arguments)

        #expect(build.rewrittenArguments == ["swift", "test", "--scratch-path", build.directory.path, "--filter", "WidgetTests"])
    }

    /// `xcodebuild` builds in derived data of its own, in place of any `-derivedDataPath` the command named, and the command still reads as the same test run.
    @Test
    func anXcodebuildRunBuildsInDerivedDataOfItsOwn() throws {
        let root = try TemporaryDirectory.make("without-build")
        let arguments = ["xcodebuild", "test", "-scheme", "App", "-derivedDataPath", "mine", "-only-testing:AppTests/WidgetTests"]
        let build = RunWithoutBuild(repositoryRoot: root, workingDirectory: root, arguments: arguments)
        let rewritten = build.rewrittenArguments

        #expect(build.shownDirectory == ".sift/without-build/xcodebuild")
        #expect(rewritten == ["xcodebuild", "-derivedDataPath", build.directory.path, "test", "-scheme", "App", "-only-testing:AppTests/WidgetTests"])
        #expect(RunVerdict.Contract.xcodebuildAction(of: rewritten) == "test")
        try RunWithoutArguments.check(rewritten, pathspecs: [])
    }

    /// A build directory is built on again only while it is marked as holding a build that reached its tests; any other is removed before the next build, and readying one unmarks it, so a run killed mid-build leaves nothing marked.
    @Test
    func onlyABuildThatReachedItsTestsIsBuiltOnAgain() throws {
        let root = try TemporaryDirectory.make("without-build")
        let build = RunWithoutBuild(repositoryRoot: root, workingDirectory: root, arguments: ["swift", "test", "--filter", "WidgetTests"])
        let object = build.directory.appendingPathComponent("object")

        try build.prepare()
        #expect(!FileManager.default.fileExists(atPath: build.directory.path), "nothing was ever built there")

        try FileManager.default.createDirectory(at: build.directory, withIntermediateDirectories: true)
        try Data("built".utf8).write(to: object)
        build.keep()
        try build.prepare()
        #expect(FileManager.default.fileExists(atPath: object.path), "a build that reached its tests is built on")
        #expect(!FileManager.default.fileExists(atPath: build.finished.path), "and is unmarked while the next build runs")

        try build.prepare()
        #expect(!FileManager.default.fileExists(atPath: build.directory.path), "a build that was never marked is removed")
    }

    /// A finished build is built on only by a run for what it was built for — the same directory, package, project, workspace and scheme, whichever tests it names; a run for any other clears it first, since a build directory is laid out by name rather than path, and one package's build is never trusted to have left nothing another's would read as its own.
    @Test
    func aBuildForAnotherPackageOrSchemeIsNotBuiltOn() throws {
        let root = try TemporaryDirectory.make("without-build")
        let kit = root.appendingPathComponent("Packages/Kit")
        let tests = ["swift", "test", "--filter", "WidgetTests"]
        let scheme = ["xcodebuild", "test", "-scheme", "App", "-only-testing:AppTests"]
        func build(_ arguments: [String], in directory: URL? = nil) -> RunWithoutBuild {
            RunWithoutBuild(repositoryRoot: root, workingDirectory: directory ?? root, arguments: arguments)
        }
        func built(_ build: RunWithoutBuild) throws -> URL {
            let object = build.directory.appendingPathComponent("object")
            try FileManager.default.createDirectory(at: build.directory, withIntermediateDirectories: true)
            try Data("built".utf8).write(to: object)
            build.keep()
            return object
        }

        for (first, next) in [
            (build(tests), build(tests, in: kit)),
            (build(["swift", "test", "--package-path", "Packages/Kit", "--filter", "WidgetTests"]), build(["swift", "test", "--package-path=Packages/Gadget", "--filter", "WidgetTests"])),
            (build(scheme), build(["xcodebuild", "test", "-scheme", "Widget", "-only-testing:AppTests"])),
            (build(scheme), build(["xcodebuild", "test", "-project", "Other.xcodeproj", "-scheme", "App", "-only-testing:AppTests"])),
        ] {
            let object = try built(first)
            try next.prepare()
            #expect(!FileManager.default.fileExists(atPath: object.path), "a run for \(next.subject) built on a build for \(first.subject)")
            #expect(!FileManager.default.fileExists(atPath: first.finished.path))
        }

        let object = try built(build(scheme))
        try build(["xcodebuild", "test", "-only-testing:AppTests/WidgetTests", "-scheme", "App"]).prepare()

        #expect(FileManager.default.fileExists(atPath: object.path), "a run for the same scheme builds on it, whichever tests it names")
    }

    /// The directory's size on disk is nil while nothing has been built there, and counts what is once something has — named in the answer's receipt so the disk it costs is never invisible.
    @Test
    func theDirectorySizeIsMeasuredOnceSomethingIsBuilt() throws {
        let root = try TemporaryDirectory.make("without-build")
        let build = RunWithoutBuild(repositoryRoot: root, workingDirectory: root, arguments: ["swift", "test", "--filter", "WidgetTests"])

        #expect(build.sizeOnDisk == nil, "nothing was ever built there")

        try FileManager.default.createDirectory(at: build.directory, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: build.directory.appendingPathComponent("object.o"))

        let size = try #require(build.sizeOnDisk)
        #expect(size >= 1000)
    }

    /// The command runs here with the repository's own URL rewrites carried in its environment, since the clone made into this directory never reads the repository's configuration file.
    @Test
    func theRepositorysURLRewritesAreCarriedIntoTheEnvironment() throws {
        let root = try TestSources.makeTempRepo()
        let arguments = ["swift", "test", "--filter", "WidgetTests"]
        let untouched = RunWithoutBuild(repositoryRoot: root, workingDirectory: root, arguments: arguments).environment

        #expect(untouched == ProcessInfo.processInfo.environment, "a repository with no rewrites leaves the environment as it was")

        try TestSources.runGit(["config", "--local", "--add", "url.git@example.com:acme/.insteadof", "https://example.com/acme/"], in: root)
        try TestSources.runGit(["config", "--local", "--add", "url.git@example.com:acme/.pushinsteadof", "https://example.com/push/"], in: root)
        let environment = RunWithoutBuild(repositoryRoot: root, workingDirectory: root, arguments: arguments).environment
        let existing = ProcessInfo.processInfo.environment["GIT_CONFIG_COUNT"].flatMap { Int($0) } ?? 0

        #expect(environment["GIT_CONFIG_COUNT"] == String(existing + 1), "a push rewrite is not carried")
        #expect(environment["GIT_CONFIG_KEY_\(existing)"] == "url.git@example.com:acme/.insteadof")
        #expect(environment["GIT_CONFIG_VALUE_\(existing)"] == "https://example.com/acme/")
    }

    /// A rewrite the repository's configuration file reaches through `include.path` is carried as well.
    @Test
    func aRewriteReachedThroughAnIncludeIsCarried() throws {
        let root = try TestSources.makeTempRepo()
        let included = root.appendingPathComponent(".git/rewrites")
        try "[url \"git@example.com:acme/\"]\n\tinsteadof = https://example.com/acme/\n".write(to: included, atomically: true, encoding: .utf8)
        try TestSources.runGit(["config", "--local", "include.path", included.path], in: root)

        let rewrites = GitContext(repoRoot: root).localURLRewrites()

        #expect(rewrites.map(\.key) == ["url.git@example.com:acme/.insteadof"])
        #expect(rewrites.map(\.value) == ["https://example.com/acme/"])
    }

    /// A run that stopped because a dependency could not be fetched is answered in one line quoting the repository that failed, and removed.
    @Test(arguments: [
        (["swift", "test", "--filter", "WidgetTests"], [
            "Fetching https://example.com/acme/Widget.git",
            "error: Failed to clone repository https://example.com/acme/Widget.git:",
            "    Cloning into bare repository '/tmp/repositories/Widget-1a2b3c4d'...",
            "    fatal: could not read Username for 'https://example.com': terminal prompts disabled",
        ]),
        (["xcodebuild", "test", "-scheme", "App", "-only-testing:AppTests/WidgetTests"], [
            "Resolve Package Graph",
            "",
            "xcodebuild: error: Could not resolve package dependencies:",
            "  Failed to clone repository https://example.com/acme/Widget.git:",
            "    fatal: could not read Username for 'https://example.com': terminal prompts disabled",
        ]),
    ])
    func aRunThatCouldNotFetchItsDependenciesIsAnsweredInOneLine(_ arguments: [String], _ log: [String]) {
        let answer = RunWithoutBuild.unresolvedAnswer(to: Self.outcome(of: arguments, printing: log), without: "Sources")

        #expect(answer == "✘ could not build without Sources: dependency resolution failed — nothing was proven (Failed to clone repository https://example.com/acme/Widget.git:)")
    }

    /// When nothing beneath `xcodebuild`'s header names the repository, the header itself is the only line matching a marker — and the header alone never says why, so the answer quotes the first line of SwiftPM's own explanation beneath it rather than the header.
    @Test
    func aHeaderWithNoRepositoryNamedIsFollowedToTheCauseBeneathIt() {
        let arguments = ["xcodebuild", "test", "-scheme", "App", "-only-testing:AppTests/WidgetTests"]
        let log = [
            "Resolve Package Graph",
            "",
            "xcodebuild: error: Could not resolve package dependencies:",
            "  Dependencies could not be resolved because no versions of 'Widget' match the requirement 2.0.0..<3.0.0",
        ]

        let answer = RunWithoutBuild.unresolvedAnswer(to: Self.outcome(of: arguments, printing: log), without: "Sources")

        #expect(answer == "✘ could not build without Sources: dependency resolution failed — nothing was proven (Dependencies could not be resolved because no versions of 'Widget' match the requirement 2.0.0..<3.0.0)")
    }

    /// With SwiftPM's shared cache of repositories on, its default, a dependency never fetched fails as a git command in that cache rather than as a clone, and is answered the same way, quoting that line.
    @Test
    func aGitCommandThatFailedInSwiftPMsRepositoryCacheIsReadAsUnresolved() {
        let arguments = ["swift", "test", "--filter", "WidgetTests"]
        let cache = "/Users/dev/Library/Caches/org.swift.swiftpm/repositories/Widget-1a2b3c4d"
        let line = "Git command 'git -C \(cache) config --get remote.origin.url' failed: fatal: cannot change to '\(cache)': No such file or directory"
        let unresolved = Self.outcome(of: arguments, printing: ["Fetching https://example.com/acme/Widget.git", "error: \(line)"])
        let elsewhere = Self.outcome(of: arguments, printing: ["error: Git command 'git -C /tmp/Sources config --get remote.origin.url' failed: fatal: not a git repository"])

        #expect(RunWithoutBuild.unresolvedAnswer(to: unresolved, without: "Sources") == "✘ could not build without Sources: dependency resolution failed — nothing was proven (\(line))")
        #expect(RunWithoutBuild.unresolvedAnswer(to: elsewhere, without: "Sources") == nil, "a git command outside the cache of repositories is not a dependency that could not be fetched")
    }

    /// The cause quoted in the one-line answer is cut at the answer's line cap, however long the log's line was.
    @Test
    func aCauseLineOfTensOfKilobytesIsClippedToTheLineCap() throws {
        let cause = "Failed to clone repository https://example.com/acme/Widget.git:" + String(repeating: " /Users/dev/Widget/Sources/Widget/Widget.swift", count: 1300)
        let log = ["Resolve Package Graph", "", "xcodebuild: error: Could not resolve package dependencies:", "  \(cause)"]

        let answer = try #require(RunWithoutBuild.unresolvedAnswer(to: Self.outcome(of: ["xcodebuild", "test", "-scheme", "App"], printing: log), without: "Sources"))

        #expect(answer.hasPrefix("✘ could not build without Sources: dependency resolution failed — nothing was proven (Failed to clone repository"))
        #expect(answer.utf8.count < RunReportRenderer.lineCap + 400)
    }

    /// Any other stop — a build that failed, or tests that ran and failed — is left to the ordinary answer.
    @Test
    func anyOtherFailureIsNotReadAsUnresolved() {
        let arguments = ["swift", "test", "--filter", "WidgetTests"]
        let buildFailed = Self.outcome(of: arguments, printing: ["/tmp/Sources/Widget.swift:3:5: error: cannot find 'gadget' in scope"])
        let testFailed = Self.outcome(of: arguments, printing: [
            "Test Case '-[WidgetTests.WidgetTests testCrashes]' started.",
            "/tmp/Tests/WidgetTests.swift:9: error: -[WidgetTests.WidgetTests testCrashes] : XCTAssertTrue failed",
            "Test Case '-[WidgetTests.WidgetTests testCrashes]' failed (0.001 seconds).",
        ])

        #expect(RunWithoutBuild.unresolvedAnswer(to: buildFailed, without: "Sources") == nil)
        #expect(RunWithoutBuild.unresolvedAnswer(to: testFailed, without: "Sources") == nil)
    }

    /// What `arguments` reports after printing `log` and exiting 1.
    private static func outcome(of arguments: [String], printing log: [String]) -> RunOutcome {
        var filter = RunOutputFilter(invokedAs: arguments)
        filter.consume(Data((log.joined(separator: "\n") + "\n").utf8))
        return RunOutcome(
            kind: RunCommandKind.recognize(arguments),
            logKey: RunCommandKind.logKey(of: arguments),
            exitCode: 1,
            report: filter.finish(exitCode: 1),
            log: nil,
            repositoryRoot: nil
        )
    }
}
