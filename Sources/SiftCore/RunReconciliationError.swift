//
// Copyright © Agulhas Labs
//

import Foundation

/// Why a run cannot be reconciled against the inventory, said as the sentence that makes it answerable.
public enum RunReconciliationError: Error, CustomStringConvertible, Sendable {
    /// The file named could not be read as text.
    case unreadableLog(path: String)

    /// No package manifest was found to bound the expected set with.
    case noManifest(root: String)

    /// A manifest was read and declares no test target, so there is nothing a run of it could have covered.
    case noTestTargets(manifest: String)

    /// The file was read and carries no test line at all, which is a file that is not a run's output rather than a run in which nothing ran.
    case noTestsReported(path: String)

    public var description: String {
        switch self {
        case let .unreadableLog(path):
            "\(path) could not be read as text. Pass the file a test run's output was written to — `swift test > run.log 2>&1`, or the log `sift run` kept under .sift/runs/."
        case let .noManifest(root):
            "no Package.swift under \(root), so there is no container to bound the expected set with: a run's output alone cannot say which test targets it covered. This reconciles a `swift test` run of a package; a sharded xcodebuild run is reconciled by `sift test --shards N`, which knows what it handed each shard."
        case let .noTestTargets(manifest):
            "\(manifest) declares no .testTarget, so nothing this package builds could have run the tests in that log. Check the log came from this repository."
        case let .noTestsReported(path):
            "\(path) carries no line either framework prints for a test starting or finishing, so there is nothing in it to reconcile. A run whose tests all failed to start still prints their start lines; a file with none is not a run's output. Check the path, and that the run's output was captured with its standard error."
        }
    }
}
