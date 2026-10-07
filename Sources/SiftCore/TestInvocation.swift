//
// Copyright © Agulhas Labs
//

import Foundation

/// The decided flags of one `sift test` run, and the exact `xcodebuild` command lines they make.
///
/// **sift supplies `xcodebuild` and the action; the caller supplies what every run needs and nothing else.** Short flags for the scheme, the device, the OS, the plan, the inclusions and the exclusions, and a pass-through after `--` for the rest, so this command never has to chase `xcodebuild`'s option list as it changes. What the short flags already name is refused in the pass-through, each with its own sentence — see ``TestInvocationError``.
///
/// **Nothing here launches anything.** Every member is a pure function from the decided flags to an argument vector whose first element is `xcodebuild`, or from bytes the tool printed to the one fact wanted out of them. The OS version arrives resolved: picking the newest installed runtime for a device type is a question about the machine, and this type answers only questions about the command line.
public struct TestInvocation: Sendable, Equatable {
    /// The scheme to build and run — required, because `xcodebuild` needs one to find the test targets.
    public let scheme: String

    /// The device *type* as `simctl list devicetypes` spells it, which names both what sift creates and the destination the one build is made for.
    public let deviceType: String

    /// The runtime version the build is made for, resolved by the caller.
    public let osVersion: String

    /// The test plan, when the caller named one.
    public let plan: String?

    /// `--only` values, in the `Target` / `Target/Class` / `Target/Class/test` spellings `xcodebuild` selects with.
    public let only: [String]

    /// `--skip` values, in the same spellings.
    public let skip: [String]

    /// The project or workspace the scheme lives in, when the caller named one.
    public let container: Container?

    /// Everything after `--`, handed to `xcodebuild` untouched — on the invocations the caller asked to influence, which the enumeration and the build-settings read are not.
    public let passThrough: [String]

    /// Checks the flags against each other, or throws the sentence saying which one cannot stand.
    ///
    /// The checks run here rather than at each argument vector because a refusal is owed **before anything is launched**: a pass-through that only failed at the shard step would have already paid for a build and an enumeration, and the caller would read the refusal as something the run did rather than something it was asked for.
    public init(
        scheme: String,
        deviceType: String,
        osVersion: String,
        plan: String? = nil,
        only: [String] = [],
        skip: [String] = [],
        container: Container? = nil,
        passThrough: [String] = []
    ) throws {
        try TestInvocation.check(only: only, skip: skip, passThrough: passThrough)
        self.scheme = scheme
        self.deviceType = deviceType
        self.osVersion = osVersion
        self.plan = plan
        self.only = only
        self.skip = skip
        self.container = container
        self.passThrough = passThrough
    }
}

// MARK: - Where the scheme lives

public extension TestInvocation {
    /// The project or workspace the scheme lives in, when the caller named one.
    enum Container: Sendable, Equatable {
        case project(String)
        case workspace(String)
    }
}

// MARK: - The destinations

public extension TestInvocation {
    /// The destination the one build is made for, and the one the enumeration and the build settings are read against.
    ///
    /// A device *type* and a runtime rather than a udid, because the build happens before any device exists: products built for one destination are accepted by any device of the same type and runtime, which is what lets provisioning overlap the build.
    var namedDestination: String {
        "platform=iOS Simulator,name=\(deviceType),OS=\(osVersion)"
    }

    /// The destination one shard runs on — the simulator sift created for it, by udid.
    static func destination(ofDevice udid: String) -> String {
        "platform=iOS Simulator,id=\(udid)"
    }
}

// MARK: - The command lines

public extension TestInvocation {
    /// The one build, for the named device type and runtime.
    ///
    /// The pass-through is carried here: this is the invocation the caller's own flags are about, and `sift run`'s filter answers a failed build exactly as it answers a failed `sift run -- xcodebuild build`.
    ///
    /// `resultBundle` is absolute and inside the run's own directory, or `xcodebuild` writes one into the default derived data's `Logs` that nothing ever removes.
    func buildForTestingArguments(resultBundle: URL) -> [String] {
        var arguments = ["xcodebuild", "build-for-testing"]
        arguments += containerArguments
        arguments += ["-scheme", scheme]
        if let plan {
            arguments += ["-testPlan", plan]
        }
        arguments += ["-destination", namedDestination]
        arguments += ["-resultBundlePath", resultBundle.path]
        arguments += passThrough
        return arguments
    }

    /// The enumeration that decides the expected set, run against the `.xctestrun` the build wrote.
    ///
    /// **No pass-through.** This is a question *about* the project — which tests would run — and not one of the invocations the caller asked to influence; a flag that moved its answer would move the inventory every count in the final answer is reconciled against, and the reconciliation would then agree with itself about the wrong set.
    ///
    /// It names the build's destination rather than one of the run's devices, and starts none, which is what lets it run while they boot; `resultBundle` keeps its result bundle in the run's own directory, as the build's does.
    func enumerationArguments(xctestrun: URL, outputPath: URL, resultBundle: URL) -> [String] {
        var arguments = [
            "xcodebuild", "test-without-building",
            "-xctestrun", xctestrun.path,
            "-destination", namedDestination,
            "-enumerate-tests",
            "-test-enumeration-style", "flat",
            "-test-enumeration-format", "json",
            "-test-enumeration-output-path", outputPath.path,
            "-resultBundlePath", resultBundle.path,
        ]
        arguments += only.map { "-only-testing:\($0)" }
        arguments += skip.map { "-skip-testing:\($0)" }
        return arguments
    }

    /// The read that finds `BUILD_DIR`, which is where the build wrote the `.xctestrun` files.
    ///
    /// **The pass-through is carried, unlike the enumeration's.** The enumeration asks what the project contains and must not be steered; this asks where *the build that just ran* put its products, so it has to be asked in the terms that build was made in. `-derivedDataPath` is the case that proves it: without the flag here the answer is the default derived data's `BUILD_DIR`, the products are not in it, and a run that built perfectly is refused for writing no `.xctestrun`.
    var buildSettingsArguments: [String] {
        var arguments = ["xcodebuild", "-showBuildSettings", "-json"]
        arguments += containerArguments
        arguments += ["-scheme", scheme, "-destination", namedDestination]
        arguments += passThrough
        return arguments
    }

    /// One shard: the tests it was given, on the device it was given, writing its own result bundle.
    ///
    /// **`-skip-testing` is not passed.** A shard's list is explicit — every test it is to run is named by `-only-testing:` — so an exclusion could only ever subtract from a set that was already decided, and a shard running fewer tests than the planner charged it for is a shard the reconciliation would report as missing them.
    ///
    /// `resultBundle` must be absolute; ``absoluteURL(_:relativeTo:)`` is how one is built, because `xcodebuild` resolves a relative path against its own working directory rather than the caller's.
    func shardArguments(xctestrun: URL, deviceUDID: String, tests: [TestIdentifier], resultBundle: URL) -> [String] {
        var arguments = [
            "xcodebuild", "test-without-building",
            "-xctestrun", xctestrun.path,
            "-destination", TestInvocation.destination(ofDevice: deviceUDID),
            "-parallel-testing-enabled", "NO",
            "-collect-test-diagnostics", "never",
        ]
        arguments += tests.map(\.onlyTestingArgument)
        arguments += ["-resultBundlePath", resultBundle.path]
        arguments += passThrough
        return arguments
    }

    private var containerArguments: [String] {
        switch container {
        case let .project(path):
            ["-project", path]
        case let .workspace(path):
            ["-workspace", path]
        case nil:
            []
        }
    }
}

// MARK: - What the flags refuse

public extension TestInvocation {
    /// The flags a refusal is owed for, checked without building an invocation.
    ///
    /// A caller that has to spawn `simctl` to resolve the runtime before it can name an `osVersion` would otherwise have launched something before the refusal it already owed — and the refusal would read as something the run did rather than something it was asked for.
    static func check(only: [String], skip: [String], passThrough: [String]) throws {
        try checkSelectors(only, option: "--only")
        try checkSelectors(skip, option: "--skip")
        try checkPassThrough(passThrough)
    }
}

extension TestInvocation {
    /// Every argument of the pass-through that stands on its own is checked against the words the short flags already name.
    ///
    /// **A refused word standing as another option's value is not a refusal.** `-configuration test` names a configuration, and refusing it would be this command inventing a conflict out of somebody's build setting. ``RunVerdict/Contract/standsAlone(in:)`` is what tells the two apart, reading the same option table the run verdict reads an action with, so there is one answer to "is this word a value" in the codebase rather than two that can drift.
    private static func checkPassThrough(_ arguments: [String]) throws {
        for (argument, alone) in zip(arguments, RunVerdict.Contract.standsAlone(in: arguments)) where alone {
            try refuse(argument)
        }
    }

    private static func refuse(_ argument: String) throws {
        if RunVerdict.Contract.isXcodebuildAction(argument) {
            throw TestInvocationError.action(argument)
        }
        // A flag that carries its value in its own name is refused by its head: `-only-testing:X` is
        // the same flag as `-only-testing`, and the value behind the colon is not what settles it.
        switch String(argument.prefix { $0 != ":" }) {
        case "-destination":
            throw TestInvocationError.destination(argument)
        case "-only-testing", "-skip-testing":
            throw TestInvocationError.testSelection(argument)
        case "-testPlan":
            throw TestInvocationError.testPlan(argument)
        case "-scheme":
            throw TestInvocationError.scheme(argument)
        case "-project", "-workspace":
            throw TestInvocationError.container(argument)
        case "-xctestrun":
            throw TestInvocationError.xctestrun(argument)
        case "-resultBundlePath":
            throw TestInvocationError.resultBundlePath(argument)
        case "-parallel-testing-enabled":
            throw TestInvocationError.parallelTesting(argument)
        case "-collect-test-diagnostics":
            throw TestInvocationError.diagnostics(argument)
        case "-enumerate-tests":
            throw TestInvocationError.enumeration(argument)
        default:
            return
        }
    }

    /// `--only` and `--skip` take `Target`, `Target/Class` or `Target/Class/test`, and nothing else names a set of tests `xcodebuild` can select.
    ///
    /// The check is on shape alone — one to three non-empty parts, no whitespace at a part's edges (a target may be named `Demo Spaced Tests`, and `-only-testing:` was measured to want exactly that spelling), and not something that would read as a flag — because whether a target or a class of that name exists is a question the enumeration answers later, with the whole inventory in hand.
    private static func checkSelectors(_ values: [String], option: String) throws {
        for value in values {
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            let wellFormed = (1 ... 3).contains(parts.count)
                && !value.hasPrefix("-")
                && parts.allSatisfy { !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespaces) && !$0.contains(where: \.isNewline) }
            guard wellFormed else {
                throw TestInvocationError.malformedSelector(value, option: option)
            }
        }
    }
}

// MARK: - Reading what the build wrote

public extension TestInvocation {
    /// The one `.xctestrun` file the named plan wrote, among the file names in the products directory.
    ///
    /// **Globbed by the `_<Plan>_` segment, never composed.** One build emits one file per plan and the name embeds the simulator OS and architecture (`TestDemo_Default_iphonesimulator27.0-arm64.xctestrun`, sometimes `-undefined_arch`), so a composed name would be a guess about a suffix this tool does not control. The segment is matched with its underscores on both sides, which is what keeps the plan `Default` off `TestDemo_DefaultFast_….xctestrun`: a bare `contains(plan)` would take the longer plan's file and run a set of targets nobody asked for.
    ///
    /// None, or several for the one plan, is a refusal that names what it found.
    static func xctestrunName(among names: [String], plan: String) throws -> String {
        let runs = names.filter { $0.hasSuffix(".xctestrun") }.sorted()
        let candidates = runs.filter { $0.contains("_\(plan)_") }
        guard let match = candidates.first else {
            throw TestInvocationError.noXCTestRun(plan: plan, found: runs)
        }
        guard candidates.count == 1 else {
            throw TestInvocationError.severalXCTestRuns(plan: plan, found: candidates)
        }
        return match
    }

    /// `BUILD_DIR` out of `xcodebuild -showBuildSettings -json`, which **is** the directory the products sit in.
    ///
    /// Measured on the demo project (17 Sep 2026): `build-for-testing` wrote `TestDemo_Default_iphonesimulator27.0-arm64.xctestrun` and its siblings into `<derived>/Build/Products/`, and that path is what `BUILD_DIR` held — so the `.xctestrun` files are globbed in this directory itself rather than in a `Products` subdirectory of it.
    ///
    /// `-showBuildSettings` prints one entry per target and every one of them carries the same `BUILD_DIR`. The distinct values are collected and exactly one is required: more than one would mean the entries disagree about where the build wrote, and there would be no way to tell which held the file the shards run from.
    static func buildDirectory(inBuildSettings data: Data) throws -> String {
        let entries: [SettingsEntry]
        do {
            entries = try JSONDecoder().decode([SettingsEntry].self, from: data)
        } catch {
            throw TestInvocationError.unreadableBuildSettings("\(error)")
        }
        let directories = Set(entries.compactMap(\.buildSettings?.buildDirectory)).sorted()
        guard let directory = directories.first else {
            throw TestInvocationError.noBuildDirectory
        }
        guard directories.count == 1 else {
            throw TestInvocationError.severalBuildDirectories(directories)
        }
        return directory
    }

    /// `path` as an absolute file URL, resolved against `directory` only when it is relative.
    ///
    /// **The branch is written out because `appendingPathComponent` has none of its own**: handed `/tmp/shard-1.xcresult` it concatenates rather than replaces, so the shard would write to `<directory>/tmp/shard-1.xcresult` and the answer would name a path nobody asked for. `-resultBundlePath` is the argument that has to be absolute, since `xcodebuild` resolves a relative one against its own working directory.
    static func absoluteURL(_ path: String, relativeTo directory: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
    }

    /// One entry of `-showBuildSettings -json`, decoded no more deeply than `BUILD_DIR`.
    fileprivate struct SettingsEntry: Decodable {
        let buildSettings: TestInvocation.SettingsEntry.Settings?
    }
}

// MARK: - The build settings' own shape

extension TestInvocation.SettingsEntry {
    /// One entry's settings, read for `BUILD_DIR` alone — every other key decodes to nothing, whatever its value's type.
    struct Settings: Decodable {
        let buildDirectory: String?
    }
}

extension TestInvocation.SettingsEntry.Settings {
    /// The one setting read, under the name `xcodebuild` prints it by.
    enum CodingKeys: String, CodingKey {
        case buildDirectory = "BUILD_DIR"
    }
}
