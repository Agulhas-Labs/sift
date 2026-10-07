//
// Copyright © Agulhas Labs
//

import Foundation

/// Why `sift test` will not build an `xcodebuild` command line, refused before anything is launched.
///
/// **Two spellings of one thing is how they come to disagree.** `sift test` supplies `xcodebuild`, the action, the destination, the `.xctestrun`, the selection and the result bundle; a pass-through word naming any of those would either be ignored or silently win, and neither is something a caller can see from the answer. So each one is refused with a sentence of its own naming what the flag already covers — a refusal a reader can act on, rather than a generic complaint about the pass-through.
public enum TestInvocationError: Error, CustomStringConvertible, Sendable {
    /// The pass-through names an action for `xcodebuild` to perform.
    case action(String)
    /// The pass-through names a destination.
    case destination(String)
    /// The pass-through selects or excludes tests.
    case testSelection(String)
    /// The pass-through names a test plan.
    case testPlan(String)
    /// The pass-through names a scheme.
    case scheme(String)
    /// The pass-through names the project or workspace the scheme lives in.
    case container(String)
    /// The pass-through names an `.xctestrun` file.
    case xctestrun(String)
    /// The pass-through names where the result bundle is written.
    case resultBundlePath(String)
    /// The pass-through sets `xcodebuild`'s own parallel testing, either way.
    case parallelTesting(String)
    /// The pass-through sets test diagnostics collection.
    case diagnostics(String)
    /// The pass-through asks for a test enumeration.
    case enumeration(String)
    /// A `--only` or `--skip` value that is not `Target`, `Target/Class` or `Target/Class/test`, and the option it was given to.
    case malformedSelector(String, option: String)
    /// No `.xctestrun` file for the named plan, and the ones that were there.
    case noXCTestRun(plan: String, found: [String])
    /// More than one `.xctestrun` file for the named plan, and their names.
    case severalXCTestRuns(plan: String, found: [String])
    /// `-showBuildSettings -json` printed something this cannot read, and what the decoder said.
    case unreadableBuildSettings(String)
    /// `-showBuildSettings -json` printed no `BUILD_DIR`.
    case noBuildDirectory
    /// `-showBuildSettings -json` printed more than one `BUILD_DIR`, and their paths.
    case severalBuildDirectories([String])

    public var description: String {
        switch self {
        case let .action(word):
            "sift test cannot take `\(word)` after `--`: it names an action for xcodebuild to perform, and sift test supplies the action itself — one build, one enumeration, then one run per shard."
        case let .destination(word):
            "sift test cannot take `\(word)` after `--`: --device and --os already name the destination, and every shard runs on a simulator sift created for it, by udid."
        case let .testSelection(word):
            "sift test cannot take `\(word)` after `--`: --only and --skip already name which tests run, and each shard is handed its own explicit list of them."
        case let .testPlan(word):
            "sift test cannot take `\(word)` after `--`: --plan already names the test plan, and one run is one plan — the plan also decides which .xctestrun file every shard runs from."
        case let .scheme(word):
            "sift test cannot take `\(word)` after `--`: --scheme already names the scheme."
        case let .container(word):
            "sift test cannot take `\(word)` after `--`: --project and --workspace already name where the scheme lives."
        case let .xctestrun(word):
            "sift test cannot take `\(word)` after `--`: the .xctestrun file is the one this run's own build wrote for the named plan, found by globbing the products directory for it."
        case let .resultBundlePath(word):
            "sift test cannot take `\(word)` after `--`: each shard writes its own result bundle, and one path shared between shards is one shard overwriting another's."
        case let .parallelTesting(word):
            "sift test cannot take `\(word)` after `--`: every shard runs with -parallel-testing-enabled NO. Xcode distributes by XCTest class and hands a whole Swift Testing suite one placeholder, so there is nothing for it to distribute and its console carries no per-test line to read — the sharding here is the answer to that same want, done where the tests can still be counted."
        case let .diagnostics(word):
            "sift test cannot take `\(word)` after `--`: every shard runs with -collect-test-diagnostics never, because without it a failing run waits ten minutes for diagnostics it will not use — measured at 610 s of wall clock over 0.2 s of tests, against 7 s with the flag."
        case let .enumeration(word):
            "sift test cannot take `\(word)` after `--`: it enumerates the tests itself, before anything runs, and that enumeration is the set every count in the answer is reconciled against."
        case let .malformedSelector(value, option):
            "sift test cannot use `\(value)` as a \(option) value: xcodebuild takes Target, Target/Class or Target/Class/test, and nothing else names a set of tests it can select."
        case let .noXCTestRun(plan, found):
            found.isEmpty
                ? "sift test found no .xctestrun file for the plan `\(plan)`, and none at all in the products directory — the build wrote nothing to run from."
                : "sift test found no .xctestrun file for the plan `\(plan)`. The products directory holds \(found.joined(separator: ", ")) — check that --plan names a plan this scheme carries."
        case let .severalXCTestRuns(plan, found):
            "sift test found \(found.count) .xctestrun files for the plan `\(plan)`: \(found.joined(separator: ", ")). One build writes one file per plan, so two for one plan means the products directory holds an earlier build's as well — clear it and build again."
        case let .unreadableBuildSettings(reason):
            "sift test could not read xcodebuild's build settings: \(reason). BUILD_DIR is where the build wrote the .xctestrun file every shard runs from, so there is nowhere to look for it."
        case .noBuildDirectory:
            "xcodebuild's build settings named no BUILD_DIR, which is the directory the build wrote its products and its .xctestrun files into. There is nowhere to look for the file the shards run from."
        case let .severalBuildDirectories(paths):
            "xcodebuild's build settings named \(paths.count) different BUILD_DIR values: \(paths.joined(separator: ", ")). One build writes its products into one directory, so sift test cannot tell which of these holds the .xctestrun file the shards would run from."
        }
    }
}
