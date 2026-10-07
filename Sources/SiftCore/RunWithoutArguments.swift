//
// Copyright © Agulhas Labs
//

import Foundation

/// What `run --without` needs of the command it is handed: a test run that builds before it runs, with the tests named, and one outcome per test to compare.
public struct RunWithoutArguments: Sendable {
    private init() {}
}

public extension RunWithoutArguments {
    /// Throws when `arguments`, run with `environment`, cannot prove anything run twice around a set-aside.
    ///
    /// `pathspecs` are the ones `--without` already took, which a refusal needs to hand back a runnable command rather than one that sets aside half the caller's change. It is not defaulted for that reason: a call that leaves it out spells a remedy that quietly drops them.
    ///
    /// `environment` is the one the command will run with: `RunLauncher` hands it this process's own, unchanged, which is why that is the default.
    ///
    /// `workingDirectory` is where a token before the command is checked for existing on disk, when deciding whether it is a pathspec; it defaults to the process's own, which is where a caller with none of its own to hand should leave it.
    ///
    /// `flag` names the flag the caller actually used — `--without` or `--without-line` — so a refusal's remedy repeats it rather than assuming `--without`.
    static func check(
        _ arguments: [String],
        pathspecs: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        flag: String = "--without"
    ) throws {
        if let extra = pathspecsBeforeTheCommand(arguments, workingDirectory: workingDirectory) {
            throw RunWithoutError.pathspecsRunTogether(extra: extra, all: pathspecs + extra, flag: flag)
        }
        let kind = RunCommandKind.recognize(arguments)
        let rest = arguments.dropFirst()
        switch kind {
        case .swiftTest:
            if rest.contains("--skip-build") {
                throw RunWithoutError.prebuilt("`--skip-build`")
            }
            if let flag = rest.first(where: { $0 == "--parallel" || $0 == "--num-workers" || $0.hasPrefix("--num-workers=") }) {
                throw RunWithoutError.parallel("`\(flag.split(separator: "=")[0])`")
            }
            guard rest.contains(where: { $0 == "--filter" || $0.hasPrefix("--filter=") }) else {
                throw RunWithoutError.unnamed("add `--filter <tests>`")
            }
        case .xcodebuild:
            let action = RunVerdict.Contract.xcodebuildAction(of: arguments)
            if action == "test-without-building" {
                throw RunWithoutError.prebuilt("`test-without-building`")
            }
            guard action == "test" else {
                throw RunWithoutError.notATestRun(arguments.joined(separator: " "))
            }
            if rest.contains("-run-tests-until-failure") {
                throw RunWithoutError.repeated("`-run-tests-until-failure`")
            }
            let parallel = rest.firstIndex(of: "-parallel-testing-enabled").map { rest.index(after: $0) }
            if let value = parallel, value < rest.endIndex, rest[value].uppercased() == "YES" {
                throw RunWithoutError.parallelClones("`-parallel-testing-enabled YES`")
            }
            if rest.contains("-test-iterations"), !rest.contains("-retry-tests-on-failure") {
                throw RunWithoutError.repeated("`-test-iterations` without `-retry-tests-on-failure`")
            }
            if let setting = rest.first(where: { Self.settingName(of: $0).map(Self.isBuildLocation) ?? false }) {
                throw RunWithoutError.buildLocation("`\(setting)`")
            }
            if rest.contains("-xcconfig") {
                throw RunWithoutError.buildSettingsFile("`-xcconfig`", remedy: "Drop it")
            }
            // Honoured by xcodebuild, observed: a `SYMROOT` in the file it named took the products out of
            // `-derivedDataPath`. Not by `swift build`, observed too, so only xcodebuild is refused it.
            if let xcconfigFile = environment["XCODE_XCCONFIG_FILE"] {
                if xcconfigFile.isEmpty {
                    throw RunWithoutError.emptyBuildSettingsFile
                }
                throw RunWithoutError.buildSettingsFile(
                    "`XCODE_XCCONFIG_FILE` in the environment",
                    remedy: "Unset it for this run with `env -u XCODE_XCCONFIG_FILE sift run --without …`, not by setting it empty, which is refused too"
                )
            }
            guard rest.contains(where: { $0 == "-only-testing" || $0.hasPrefix("-only-testing:") }) else {
                throw RunWithoutError.unnamed("add `-only-testing:<Target/Suite/test>`")
            }
        case .swiftBuild, .linter, .unrecognized:
            throw RunWithoutError.notATestRun(arguments.joined(separator: " "))
        }
    }

    /// The commit `--since` names, resolved by git before anything is recorded or any lock is taken; `nil` where the caller gave none.
    ///
    /// Resolved to an object name rather than kept as the caller wrote it, so a branch that moves while the tests run cannot change what the second half of the run compares against. A working directory that is in no repository is left to the capture itself to refuse, which already says so in the words a set-aside owes.
    static func revision(_ named: String?, pathspecs: [String], workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> String? {
        guard let named else {
            return nil
        }
        guard !pathspecs.isEmpty else {
            throw RunWithoutError.sinceWithoutPathspec
        }
        guard let root = GitContext.discoverRoot(from: workingDirectory) else {
            return named
        }
        let git = SetAsideGit(directory: workingDirectory, repositoryRoot: root, children: SetAsideChildren())
        guard let commit = try? git.text(["rev-parse", "--verify", "--quiet", "\(named)^{commit}"]), !commit.isEmpty else {
            throw RunWithoutError.unresolvedRevision(named)
        }
        // `git diff <rev> HEAD` is a two-point diff: naming something HEAD does not descend from would set
        // aside the reverse of whatever the other branch did, not "what the commits since it changed".
        guard (try? git.run(["merge-base", "--is-ancestor", commit, "HEAD"])) != nil else {
            throw RunWithoutError.notAnAncestor(named)
        }
        return commit
    }

    /// The pathspecs a caller wrote after the first one instead of repeating `--without`; `nil` when the command is their own, or when a token in front of it does not look like a path — a wrapper such as `/usr/bin/env`, `xcrun` or `caffeinate`, and whatever it hands the wrapped command, land here too, and are not pathspecs.
    ///
    /// Passthrough capture hands everything from the second pathspec onwards to the wrapped command, so nothing in the parser can tell one of them from a command of that name. What the arguments themselves say is that the whole list names no command this could run while some token further along starts one, which on its own is just as well explained by a wrapper token as by a genuine pathspec — so before this is believed, every token in front of the command is required to actually look like one: it exists on disk under `workingDirectory`, it contains a `/`, or it ends in a known source extension. A terminator the caller wrote between the two is one of the tokens in front of that command, and is dropped from what they are told to set aside — it names no path, and is never why the check fails.
    private static func pathspecsBeforeTheCommand(_ arguments: [String], workingDirectory: URL) -> [String]? {
        guard case .unrecognized = RunCommandKind.recognize(arguments) else {
            return nil
        }
        for start in arguments.indices.dropFirst() {
            if case .unrecognized = RunCommandKind.recognize(Array(arguments[start...])) {
                continue
            }
            let extra = arguments[..<start].filter { $0 != "--" }
            guard !extra.isEmpty else {
                return nil
            }
            guard extra.allSatisfy({ Self.looksLikeAPathspec($0, workingDirectory: workingDirectory) }) else {
                return nil
            }
            return Array(extra)
        }
        return nil
    }

    /// Whether `token` looks like a path rather than part of a wrapper's own invocation — `env`, `FOO=1`, `xcrun`, `--verbose` — which a caller never meant to set aside.
    private static func looksLikeAPathspec(_ token: String, workingDirectory: URL) -> Bool {
        if token.contains("/") {
            return true
        }
        if knownSourceExtensions.contains(where: { token.hasSuffix($0) }) {
            return true
        }
        return FileManager.default.fileExists(atPath: workingDirectory.appendingPathComponent(token).path)
    }

    /// Extensions a bare token — no `/`, not found on disk — is still read as a path by, rather than as part of a wrapper's own invocation.
    private static let knownSourceExtensions: Set<String> = [
        ".swift", ".m", ".mm", ".h", ".hpp", ".c", ".cc", ".cpp",
        ".plist", ".xcconfig", ".storyboard", ".xib", ".entitlements",
        ".json", ".yml", ".yaml", ".md", ".strings",
    ]

    /// Whether the command retries a failing test, so a name that finishes more than once is one test counted by its last attempt rather than several tests that disagree.
    static func retriesFailures(_ arguments: [String]) -> Bool {
        guard case .xcodebuild = RunCommandKind.recognize(arguments) else {
            return false
        }
        return arguments.contains("-retry-tests-on-failure")
    }

    /// The build setting `argument` assigns — `KEY` of `KEY=value`, or of `KEY[condition]=value` — or `nil` when it assigns none.
    ///
    /// The conditional spelling counts: `SYMROOT[sdk=macosx*]=…` took the products out of `-derivedDataPath` when tried.
    private static func settingName(of argument: String) -> String? {
        guard let equals = argument.firstIndex(of: "=") else {
            return nil
        }
        return String(argument[..<equals].prefix { $0 != "[" })
    }

    /// `xcodebuild` build settings that name where products or intermediates land — refused as `KEY=VALUE` on the command line, whatever else the setting is worth, because the first run's build would then land where the caller's own build, or the second run, reads.
    ///
    /// Named one by one rather than matched by a `ROOT` or `DIR` suffix, since `SDKROOT` names an SDK, not a place to write. `MODULE_CACHE_DIR` is among them because the Clang modules it holds would be built against the set-aside headers and shared with every build that names the same cache.
    private static let buildLocationSettings: Set<String> = [
        "SYMROOT", "OBJROOT", "BUILD_DIR", "BUILD_ROOT", "CONFIGURATION_BUILD_DIR", "SHARED_PRECOMPS_DIR",
        "TEMP_ROOT", "PROJECT_TEMP_ROOT", "PROJECT_TEMP_DIR", "CONFIGURATION_TEMP_DIR", "TARGET_TEMP_DIR",
        "OBJECT_FILE_DIR", "BUILT_PRODUCTS_DIR", "TARGET_BUILD_DIR", "MODULE_CACHE_DIR",
        "DERIVED_FILE_DIR", "PROJECT_DERIVED_FILE_DIR",
    ]

    /// Whether the setting `name` is one of ``buildLocationSettings``, or `OBJECT_FILE_DIR_<variant>` — `OBJECT_FILE_DIR_normal`, the per-variant spelling objects are written through, which names the same place `OBJECT_FILE_DIR` does.
    private static func isBuildLocation(_ name: String) -> Bool {
        buildLocationSettings.contains(name) || name.hasPrefix("OBJECT_FILE_DIR_")
    }
}
