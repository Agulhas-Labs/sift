//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// A patch's files are judged together, and the first file's nudge never waits on its later files: a file whose record gained no name costs no scan of its module, and the files worked out when the budget is spent are handed back.
@Suite(.temporaryDirectories)
struct ReuseNudgeBatchTests {
    /// Only the module of a file that gained a name is scanned: the later files, comment-only edits in modules of their own, cost nothing.
    @Test func aFileThatGainedNoNameHasNoModuleScanned() async throws {
        let fixture = try await Fixture()
        try fixture.edit(gaining: [])
        let scans = ScanLog()
        let (files, root) = (fixture.files, fixture.repo.path)

        let found = await InPlaceAnswerTests.onItsOwnThread {
            ReuseNudge.findings(forFiles: files, atRoot: root, budget: 60) { paths, repoRoot in
                scans.note(paths)
                return await SimilarSearch.scan(paths: paths, repoRoot: repoRoot)
            }
        }

        #expect(found[files[0]]?.first?.added.declaration.qualifiedName == "Catalogue.restock()", "\(found)")
        #expect(scans.paths.count == 1, "\(scans.paths)")
        #expect(scans.paths.joined().allSatisfy { $0.hasPrefix("Sources/A/") }, "\(scans.paths)")
    }

    /// The first file's nudge comes back though a later file's scan is still running when the budget is spent.
    ///
    /// The budget's clock starts once B's scan is held, when the first file is worked out however slowly the machine got there, so the budget is spent on the held scan alone.
    @Test func theFilesWorkedOutWhenTheBudgetIsSpentAreHandedBack() async throws {
        let fixture = try await Fixture()
        try fixture.edit(gaining: ["B"])
        let scans = ScanLog()
        let (files, root) = (fixture.files, fixture.repo.path)

        let found = await InPlaceAnswerTests.onItsOwnThread {
            ReuseNudge.findings(
                forFiles: files,
                atRoot: root,
                budget: 0.5,
                scan: { paths, repoRoot in
                    scans.note(paths)
                    if paths.contains(where: { $0.hasPrefix("Sources/B/") }) {
                        await scans.held()
                    }
                    return await SimilarSearch.scan(paths: paths, repoRoot: repoRoot)
                },
                beforeTheBudget: { scans.waitUntilHeld() }
            )
        }
        scans.release()

        #expect(scans.paths.count == 2, "the scan of B's module was never reached: \(scans.paths)")
        #expect(found[files[0]]?.first?.added.declaration.qualifiedName == "Catalogue.restock()", "\(found)")
        #expect(found[files[1]] == nil)
    }
}

extension ReuseNudgeBatchTests {
    /// A package of small modules beside the repository's own: `A` holds `Depot.stock()`, making four calls, and a catalogue; `B`, `C` and `D` one file each.
    struct Fixture {
        static let others = ["B", "C", "D"]

        let repo: URL

        init() async throws {
            repo = try MCPTestRepo.make(declaring: "Anchor")
            let targets = (["App", "A"] + Self.others).map { ".target(name: \"\($0)\")" }.joined(separator: ", ")
            var sources = [
                "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [\(targets)])\n",
                "Sources/A/Depot.swift": "struct Depot {\n    func stock() -> Int {\n        let crates = load()\n        let weight = weigh(crates)\n        label(crates, weight)\n        return ship(crates)\n    }\n}\n",
                "Sources/A/Catalogue.swift": Self.catalogue(adding: ""),
            ]
            for module in Self.others {
                sources["Sources/\(module)/Bay\(module).swift"] = Self.bay(module, adding: "")
            }
            try MCPTestRepo.add(sources, to: repo)
            try await SiftEngine(directory: repo, registry: nil).ensureFresh()
        }

        /// The edited files, in patch order: the catalogue, then each other module's file.
        var files: [String] {
            (["Sources/A/Catalogue.swift"] + Self.others.map { "Sources/\($0)/Bay\($0).swift" }).map { repo.appendingPathComponent($0).path }
        }

        /// Adds `Catalogue.restock()`, whose body is `Depot.stock()`'s, and a doc comment to each other module's file, which in the modules of `gaining` also gains a function.
        func edit(gaining: Set<String>) throws {
            let restock = "\n    func restock() -> Int {\n        let crates = load()\n        let weight = weigh(crates)\n        label(crates, weight)\n        return ship(crates)\n    }\n"
            try Self.catalogue(adding: restock).write(toFile: files[0], atomically: true, encoding: .utf8)
            for (module, file) in zip(Self.others, files.dropFirst()) {
                let added = gaining.contains(module) ? "\n    func extra() -> Int {\n        2\n    }\n" : ""
                try ("/// Moored here.\n" + Self.bay(module, adding: added)).write(toFile: file, atomically: true, encoding: .utf8)
            }
        }

        static func catalogue(adding body: String) -> String {
            "struct Catalogue {\n    func count() -> Int {\n        1\n    }\n\(body)}\n"
        }

        static func bay(_ module: String, adding body: String) -> String {
            "struct Bay\(module) {\n    func size() -> Int {\n        1\n    }\n\(body)}\n"
        }
    }

    /// The paths of each scan asked for, and a hold a scan can wait in until the test lets it go.
    final class ScanLog: @unchecked Sendable {
        private let gate = NSLock()
        private let holding = DispatchSemaphore(value: 0)
        private var scanned: [[String]] = []
        private var released = false

        var paths: [[String]] {
            gate.withLock { scanned }
        }

        func note(_ paths: [String]) {
            gate.withLock { scanned.append(paths.sorted()) }
        }

        func release() {
            gate.withLock { released = true }
        }

        /// Returns once a scan is waiting in ``held()``, or after a minute, so a scan never reached fails the test rather than hanging it.
        func waitUntilHeld() {
            _ = holding.wait(timeout: .now() + 60)
        }

        /// Returns once ``release()`` is called.
        func held() async {
            holding.signal()
            while !gate.withLock({ released }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}
