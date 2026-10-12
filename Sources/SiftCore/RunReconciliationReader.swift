//
// Copyright © Agulhas Labs
//

import Foundation

/// A finished run's own output, read back and set against the inventory the index declares.
///
/// Its own type rather than more of ``SiftEngine`` for the reason `DiffGatherer` and `WhereRenderer` are: the engine opens the index and owes the header, and everything below that — which container bounds the expected set, how the file decodes, how a path is named — is this one question's.
struct RunReconciliationReader {
    let store: IndexStore

    /// The repository whose index declares the tests, and the root a path in the answer is named relative to.
    let repositoryRoot: URL

    /// The repository-relative directory of the package whose manifest bounds the expected set, empty for the package at the root.
    var packageDirectory = ""

    /// Reads the run at `logURL` and sets it against the inventory the index declares, inside the scope the manifest bounds.
    func reconcile(against logURL: URL) throws -> RunReconciliation {
        let scope = try scope(forRunAt: logURL)
        var outcomes = RunTestOutcomes()
        for line in try Self.lines(ofRunAt: logURL) {
            outcomes.read(line)
        }
        return try reconcile(outcomes, in: scope)
    }

    /// Sets outcomes a run has already parsed against the inventory, inside the same scope; `logURL` only names the run in the answer.
    ///
    /// - Parameter executedNothing: Whether the run's own closing counts showed it executed no test (``RunTestSelector/executedNothing(_:exitCode:testBundles:)``), so outcomes with no test line in them are a run of none, set against the inventory as zero reported, rather than a file that is not a run's output.
    func reconcile(_ outcomes: RunTestOutcomes, loggedAt logURL: URL?, executedNothing: Bool = false) throws -> RunReconciliation {
        try reconcile(outcomes, in: scope(forRunAt: logURL ?? repositoryRoot), executedNothing: executedNothing)
    }

    private func reconcile(_ outcomes: RunTestOutcomes, in scope: RunReconciliation.Scope, executedNothing: Bool = false) throws -> RunReconciliation {
        guard !outcomes.isEmpty || executedNothing else {
            throw RunReconciliationError.noTestsReported(path: scope.logPath)
        }
        let inventory = try TestInventory.read(store: store, repositoryRoot: repositoryRoot)
        return RunReconciler.reconcile(inventory: inventory, outcomes: outcomes, scope: scope)
    }

    /// The container that bounds the expected set: the package manifest in ``packageDirectory`` and the test targets it declares.
    private func scope(forRunAt logURL: URL) throws -> RunReconciliation.Scope {
        let packageURL = packageDirectory.isEmpty ? repositoryRoot : repositoryRoot.appendingPathComponent(packageDirectory)
        let manifestURL = packageURL.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw RunReconciliationError.noManifest(root: packageURL.path)
        }
        let manifestPath = packageDirectory.isEmpty ? "Package.swift" : packageDirectory + "/Package.swift"
        let manifest = SwiftPMManifest.parse(fileAt: manifestURL)
        guard !manifest.testTargets.isEmpty else {
            throw RunReconciliationError.noTestTargets(manifest: manifestPath)
        }
        var scope = RunReconciliation.Scope(
            manifest: manifestPath,
            targets: manifest.testTargets.sorted(),
            conditionalTargets: manifest.conditionalTestTargets,
            logPath: Self.displayPath(of: logURL, under: repositoryRoot)
        )
        scope.directory = packageDirectory
        scope.nestedPackages = try nestedPackages()
        let testNames = Set(manifest.testTargets)
        scope.testTargetDirectories = manifest.targets.filter { testNames.contains($0.name) }.compactMap(\.path).map {
            ([packageDirectory, $0].filter { !$0.isEmpty }.joined(separator: "/") as NSString).standardizingPath
        }
        return scope
    }

    /// The directories under ``packageDirectory`` that hold a manifest of their own, found above the files the index knows (a manifest is not itself in the store).
    private func nestedPackages() throws -> [String] {
        let inside = packageDirectory.isEmpty ? "" : packageDirectory + "/"
        var checked: [String: Bool] = [:]
        var nested: Set<String> = []
        for path in try store.fileInventory().keys {
            var directory = (path as NSString).deletingLastPathComponent
            while !directory.isEmpty, directory.hasPrefix(inside), directory != packageDirectory {
                let holdsManifest = checked[directory] ?? FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent(directory).appendingPathComponent("Package.swift").path)
                checked[directory] = holdsManifest
                if holdsManifest {
                    nested.insert(directory)
                }
                directory = (directory as NSString).deletingLastPathComponent
            }
        }
        return nested.sorted()
    }

    /// One run's output, as lines.
    ///
    /// A run's log carries whatever the tools it ran wrote into it, so a byte that is not UTF-8 must not cost the whole file: the fallback maps every byte to a character, which can garble a stray one but leaves every line boundary — and so every test line this reads — intact. Refusing the file over one bad byte would lose the answer entirely.
    private static func lines(ofRunAt logURL: URL) throws -> [String] {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1)
        else {
            throw RunReconciliationError.unreadableLog(path: logURL.path)
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// A path as the answer names it: repository-relative where it sits under the repository, and absolute where it does not.
    private static func displayPath(of url: URL, under root: URL) -> String {
        let path = CanonicalPath.of(url.path)
        let prefix = CanonicalPath.of(root.path) + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
