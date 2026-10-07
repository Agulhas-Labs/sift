//
// Copyright © Agulhas Labs
//

import Foundation

/// Everything one sharded test run is asked for, in one value, so the invocation, the ledger, the watcher and the planner all read the same request.
public struct TestRunRequest: Sendable {
    /// The scheme to build and run.
    public let scheme: String

    /// The device *type* as `simctl list devicetypes` spells it, which names both what is created and what the one build is made for.
    public let deviceTypeName: String

    /// The runtime version asked for, or `nil` for the newest installed one that runs the device type.
    public let osVersion: String?

    /// The test plan, when the caller named one.
    public let plan: String?

    /// `--only` values, in the `Target` / `Target/Class` / `Target/Class/test` spellings.
    public let only: [String]

    /// `--skip` values, in the same spellings.
    public let skip: [String]

    /// The project or workspace the scheme lives in, when the caller named one.
    public let container: TestInvocation.Container?

    /// Everything after `--`, handed to `xcodebuild` untouched.
    public let passThrough: [String]

    /// The shards the caller asked for, or `nil` to take the host's own count.
    public let requestedShards: Int?

    /// The floor `--shard-timeout` sets under a shard's bound, or `nil` for the built-in ten minutes.
    public let shardTimeoutSeconds: TimeInterval?

    /// Where the caller ran the command, which is where every wrapped `xcodebuild` is started.
    public let workingDirectory: URL

    /// The repository whose `.sift/` holds the ledger, the durations and the run logs.
    public let repositoryRoot: URL

    /// The running `sift`, which is what the watcher is started from — a detached copy of this binary is the only thing that can finish the cleanup after a kill.
    public let executable: URL

    public init(
        scheme: String,
        deviceTypeName: String,
        osVersion: String? = nil,
        plan: String? = nil,
        only: [String] = [],
        skip: [String] = [],
        container: TestInvocation.Container? = nil,
        passThrough: [String] = [],
        requestedShards: Int? = nil,
        shardTimeoutSeconds: TimeInterval? = nil,
        workingDirectory: URL,
        repositoryRoot: URL,
        executable: URL
    ) {
        self.scheme = scheme
        self.deviceTypeName = deviceTypeName
        self.osVersion = osVersion
        self.plan = plan
        self.only = only
        self.skip = skip
        self.container = container
        self.passThrough = passThrough
        self.requestedShards = requestedShards
        self.shardTimeoutSeconds = shardTimeoutSeconds
        self.workingDirectory = workingDirectory
        self.repositoryRoot = repositoryRoot
        self.executable = executable
    }
}

extension TestRunRequest {
    /// The `sift test` invocation that reproduces this run's scheme, device, OS, plan and container — everything a re-run needs before `--shards 1` and the failing `--only` arguments are appended.
    var rerunCommandPrefix: String {
        var words = ["sift", "test", "--scheme", Self.shellQuoted(scheme), "--device", Self.shellQuoted(deviceTypeName)]
        if let osVersion {
            words += ["--os", Self.shellQuoted(osVersion)]
        }
        if let plan {
            words += ["--plan", Self.shellQuoted(plan)]
        }
        switch container {
        case let .project(path):
            words += ["--project", Self.shellQuoted(path)]
        case let .workspace(path):
            words += ["--workspace", Self.shellQuoted(path)]
        case nil:
            break
        }
        return words.joined(separator: " ")
    }

    /// The caller's pass-through as the tail of a re-run line, ` -- <words>`, or `nil` where there was none.
    var rerunCommandSuffix: String? {
        passThrough.isEmpty ? nil : " -- " + passThrough.map(Self.shellQuoted).joined(separator: " ")
    }

    /// A value as one shell word: itself, unquoted, when it holds nothing the shell would split or expand, else itself in single quotes with any single quote of its own escaped — so a printed command is safe to paste and run rather than a claim the reader has to repair first.
    static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./-"))
        guard !value.isEmpty, value.unicodeScalars.allSatisfy(safe.contains) else {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return value
    }
}
