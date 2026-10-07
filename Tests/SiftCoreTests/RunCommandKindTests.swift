//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers recognition, which reads argv and never the output.
///
/// A filter chosen from what the output happens to look like would change its mind halfway through a build; a filter chosen from the command line is decided before a byte arrives.
struct RunCommandKindTests {
    @Test(arguments: [
        (["swift", "build"], RunCommandKind.swiftBuild),
        (["swift", "build", "-c", "release"], RunCommandKind.swiftBuild),
        (["swift", "test"], RunCommandKind.swiftTest),
        (["swift", "test", "--filter", "list"], RunCommandKind.swiftTest),
        (["swift", "test", "--skip-build", "--scratch-path", "list"], RunCommandKind.swiftTest),
        (["swift", "test", "--filter", "RunOutputFilterTests"], RunCommandKind.swiftTest),
        (["/usr/bin/swift", "build"], RunCommandKind.swiftBuild),
        (["xcodebuild", "-scheme", "Gizmo", "test"], RunCommandKind.xcodebuild),
        (["swift", "run", "sift"], RunCommandKind.unrecognized),
        (["swift", "package", "resolve"], RunCommandKind.unrecognized),
        (["swift"], RunCommandKind.unrecognized),
        (["make", "build"], RunCommandKind.unrecognized),
        ([], RunCommandKind.unrecognized),
    ])
    func argvDecidesTheFilter(arguments: [String], expected: RunCommandKind) {
        #expect(RunCommandKind.recognize(arguments) == expected)
    }

    /// A question about the project is not a build of it, and the filter would keep nothing at all from one.
    ///
    /// `swift build --show-bin-path` prints one path and `xcodebuild -list` a scheme list: filtering those leaves a receipt naming a log the caller then has to read, which spends the whole saving backwards. The subcommand says build in every case here — the flag is the only thing that tells them apart.
    @Test(arguments: [
        ["swift", "build", "--show-bin-path"],
        ["swift", "build", "--show-dependencies"],
        ["swift", "test", "--list-tests"],
        ["swift", "test", "list"],
        ["swift", "test", "list", "--skip-build"],
        ["swift", "test", "--skip-build", "list"],
        ["swift", "test", "--scratch-path", ".build", "list"],
        ["swift", "test", "--filter", "X", "-c", "release", "list"],
        ["swift", "test", "--show-codecov-path"],
        ["swift", "test", "--enable-code-coverage", "--show-codecov-path", "--scratch-path", ".build/w"],
        ["swift", "build", "--scratch-path", ".build/w", "--show-bin-path"],
        ["swift", "build", "--help"],
        ["xcodebuild", "-list"],
        ["xcodebuild", "-showBuildSettings", "-scheme", "Gizmo"],
        ["xcodebuild", "-showsdks"],
        ["xcodebuild", "-version"],
    ])
    func aQuestionAboutTheProjectIsNotAFilteredRun(arguments: [String]) {
        #expect(RunCommandKind.recognize(arguments) == .unrecognized)
    }

    /// A build or test that skips the build compiles nothing, so it never stands for the tree having been built.
    @Test(arguments: [
        (["swift", "build"], true),
        (["swift", "test"], true),
        (["swift", "test", "--filter", "X"], true),
        (["xcodebuild", "-scheme", "App", "build"], true),
        (["xcodebuild", "-scheme", "App", "test"], true),
        (["swift", "test", "--skip-build"], false),
        (["swift", "test", "--filter", "X", "--skip-build"], false),
        (["xcodebuild", "-scheme", "App", "test-without-building"], false),
        (["swiftlint", "lint"], false),
    ])
    func aRunThatSkipsTheBuildDoesNotCompileTheTree(arguments: [String], compiles: Bool) {
        #expect(RunCommandKind.compilesTree(arguments) == compiles)
    }

    @Test
    func onlyARecognizedCommandIsFiltered() {
        #expect(RunCommandKind.swiftBuild.isFiltered)
        #expect(RunCommandKind.swiftTest.isFiltered)
        #expect(RunCommandKind.xcodebuild.isFiltered)
        #expect(!RunCommandKind.unrecognized.isFiltered)
    }

    /// The key files the action beside the tool, which is the word a population needs and recognition alone never had.
    ///
    /// Recognition is by *executable*, which is all a filter needs: `xcodebuild build` and `xcodebuild test` are one kind, and one key for both would leave nothing downstream able to tell a run that could have executed a test from one that could not. The action comes from the reading that already decides which verdict the command owes, so the two answers can never disagree about what was invoked.
    @Test(arguments: [
        (["swift", "test", "--filter", "RunOutputFilterTests"], "swift test"),
        (["swift", "build", "-c", "release"], "swift build"),
        (["make", "build"], "unfiltered"),
        (["xcodebuild", "-scheme", "Gizmo", "test"], "xcodebuild test"),
        (["xcodebuild", "-scheme", "Gizmo", "build"], "xcodebuild build"),
        (["xcodebuild", "-quiet", "test-without-building"], "xcodebuild test-without-building"),
        (["xcodebuild", "-scheme", "Gizmo", "build-for-testing"], "xcodebuild build-for-testing"),
        // The manual page's own default, and the last action of several, exactly as the verdict reads them.
        (["xcodebuild", "-project", "Gizmo.xcodeproj", "-scheme", "Gizmo"], "xcodebuild build"),
        (["xcodebuild", "clean", "build"], "xcodebuild build"),
    ])
    func theLogKeyNamesTheActionAndNotOnlyTheTool(arguments: [String], expected: String) {
        #expect(RunCommandKind.logKey(of: arguments) == expected)
    }

    /// An action argv leaves in doubt is not guessed into a key, and the bare tool name is where that lands.
    ///
    /// `-scheme test` names a scheme, and an export replaces the build with a mode whose closing line nobody here has measured. Both file exactly as a line recorded without its action does — under `xcodebuild`, which ``RunCommandKind/population(of:)`` refuses to count. Guessing either into a population is the failure this whole path is arranged to prevent, and the fallback for it is the one already on disk.
    @Test
    func anActionArgvLeavesInDoubtFilesUnderTheBareToolName() {
        #expect(RunCommandKind.logKey(of: ["xcodebuild", "-scheme", "test", "-project", "Gizmo.xcodeproj"]) == "xcodebuild")
        #expect(RunCommandKind.logKey(of: ["xcodebuild", "-exportArchive", "-archivePath", "A.xcarchive"]) == "xcodebuild")
        #expect(RunCommandKind.population(of: "xcodebuild") == nil)
    }

    /// The two actions that execute a test bundle share one population; everything else is its own, and the key that names no action is none.
    ///
    /// `test-without-building` is the second half of the `build-for-testing` split, running the same suite the same way, so splitting the two would halve one repository's test history. `build-for-testing` itself is on the other side of that line: it compiles the bundle and executes nothing, which is exactly the run that must never stand in a test's denominator.
    @Test
    func onlyTheActionsThatExecuteTestsShareAPopulation() {
        #expect(RunCommandKind.population(of: "xcodebuild test") == RunCommandKind.population(of: "xcodebuild test-without-building"))
        #expect(RunCommandKind.population(of: "xcodebuild build") != RunCommandKind.population(of: "xcodebuild test"))
        #expect(RunCommandKind.population(of: "xcodebuild build-for-testing") != RunCommandKind.population(of: "xcodebuild test"))
        // A run that could not have executed a test is still a population of its own — measured, listing
        // nothing — which is what `swift build` has always been and is why it needs no rule of its own.
        #expect(RunCommandKind.population(of: "xcodebuild build") == "xcodebuild build")
        #expect(RunCommandKind.population(of: "swift test") == "swift test")
        #expect(RunCommandKind.population(of: "swift build") == "swift build")
        #expect(RunCommandKind.population(of: "unfiltered") == "unfiltered")
    }

    /// `sift run`'s tree key is proof only a test-executing command can ever redeem, so a build must not compute one to have it sit unread.
    ///
    /// `swift build` and a linter are filtered — ``RunCommandKind/isFiltered`` is true for both — but neither executes a test, so a key taken for either would cost a `git add` and a `write-tree` never asked for.
    @Test
    func onlyATestExecutingCommandExecutesTests() {
        #expect(RunCommandKind.executesTests(["swift", "test"]))
        #expect(RunCommandKind.executesTests(["xcodebuild", "-scheme", "Gizmo", "test"]))
        #expect(!RunCommandKind.executesTests(["swift", "build"]))
        #expect(!RunCommandKind.executesTests(["xcodebuild", "-scheme", "Gizmo", "build"]))
        #expect(!RunCommandKind.executesTests(["swiftlint"]))
    }
}
