//
// Copyright © Agulhas Labs
//

import Foundation

/// Why a command cannot be run with and without a change.
public enum RunWithoutError: Error, CustomStringConvertible, Sendable {
    case notATestRun(String)
    /// Every pathspec the caller wrote beside the first one, where `--without` takes one at a time, and `all` the pathspecs the corrected command needs — the ones already behind a flag of their own and these.
    ///
    /// `flag` names the flag the caller actually used, so the remedy repeats it rather than assuming `--without`.
    case pathspecsRunTogether(extra: [String], all: [String], flag: String)
    /// The tests are not named, and the argument that names them.
    case unnamed(String)
    /// The command runs what was built before, and the flag or action that says so.
    case prebuilt(String)
    /// The command runs tests in parallel, which SwiftPM reports without a line for an XCTest that passed.
    case parallel(String)
    /// The command runs each test more than once and keeps every outcome.
    case repeated(String)
    /// `xcodebuild` runs the tests in parallel clones of the test runner, and reports each in lines this does not read as an outcome.
    case parallelClones(String)
    /// The command names where `xcodebuild` writes its build products or intermediates, which would put the first run's where the caller's own build, or the second run, could read them.
    case buildLocation(String)
    /// The command hands `xcodebuild` a file of build settings — on the command line or in the environment — that can set where it writes its build products, and what the caller does instead.
    case buildSettingsFile(String, remedy: String)
    /// `XCODE_XCCONFIG_FILE` is set in the environment to an empty string, which names no file at all but which xcodebuild still fails to open.
    case emptyBuildSettingsFile
    /// `--since` was given with no pathspec to read it against.
    case sinceWithoutPathspec
    /// `--since` named something git could not resolve to a commit, as the caller wrote it.
    case unresolvedRevision(String)
    /// `--since` named a commit HEAD does not descend from, as the caller wrote it.
    case notAnAncestor(String)

    public var description: String {
        switch self {
        case let .notATestRun(command):
            "sift run --without runs the named tests with and without a change, so it needs `swift test --filter <tests>` or `xcodebuild test -only-testing:<tests>`; `\(command)` is neither."
        case let .pathspecsRunTogether(extra, all, flag):
            "sift run \(flag) takes one pathspec, and repeats: everything after that pathspec is read as the command to run, which is where `\(extra.joined(separator: " "))` went. Give each its own flag — `\(all.map { "\(flag) \($0)" }.joined(separator: " "))` — and they are set aside together, as one unit."
        case let .unnamed(remedy):
            "sift run --without needs the tests named — \(remedy). Unnamed, every test in the suite runs twice, and every one that never touched the change is reported as pinning nothing."
        case let .prebuilt(spelling):
            "sift run --without cannot use \(spelling): it runs what the last build produced, which was built with the change in it, so setting the change aside would prove nothing. Drop it so the run builds first."
        case let .parallel(spelling):
            "sift run --without cannot use \(spelling): run in parallel, SwiftPM prints no line when an XCTest passes, so a test that passed would read as one that never ran. Drop it — the named tests run one after another."
        case let .parallelClones(spelling):
            "sift run --without cannot use \(spelling): run in parallel, xcodebuild reports each test from a clone of the test runner, in lines this does not read as one outcome per test. Drop it — the named tests run one after another."
        case let .repeated(spelling):
            "sift run --without cannot use \(spelling): it runs each test several times and keeps every outcome, so there is no one outcome per test to compare between the two runs. Drop it, or add `-retry-tests-on-failure` to count each test by its last attempt."
        case let .buildLocation(spelling):
            "sift run --without cannot use \(spelling): it names where xcodebuild writes its build products or intermediates, so the first run's would land where the caller's own build, or the second run, reads them — the very failure a build directory of its own exists to prevent. Drop it — the run already builds in a directory of its own."
        case let .buildSettingsFile(spelling, remedy):
            "sift run --without cannot use \(spelling): the file it names can set where xcodebuild writes its build products, so the first run's could land where the caller's own build, or the second run, reads them — the very failure a build directory of its own exists to prevent. \(remedy) — the run already builds in a directory of its own."
        case .emptyBuildSettingsFile:
            "sift run --without cannot use `XCODE_XCCONFIG_FILE` in the environment: it is set but empty, which xcodebuild cannot open; unset it with `env -u XCODE_XCCONFIG_FILE sift run --without …`."
        case .sinceWithoutPathspec:
            "sift run --since says which commit's version of a path to set aside, so it needs `--without <pathspec>` to say which paths. Add one — `sift run --without <pathspec> --since <rev> -- <tests>`."
        case let .unresolvedRevision(named):
            "sift run --without: git cannot resolve `\(named)` to a commit, so there is no version of the pathspec to set the change aside to. Name one it knows — a commit, a tag, a branch, or a form like `HEAD~1`."
        case let .notAnAncestor(named):
            "sift run --without: `\(named)` is not an ancestor of HEAD, so there are no commits since it on this branch — `--since` would set aside the reverse of whatever it changed instead. Name a revision HEAD descends from, such as `origin/main` after a fetch."
        }
    }
}
