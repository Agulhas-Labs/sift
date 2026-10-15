//
// Copyright © Agulhas Labs
//

import Foundation

/// The single line `where` replaces a per-declaration "none recorded in the store" block with, for any relation: `no references to X recorded in the store`, `no callers of …`, `no reads or writes of …`, `no uses of …`.
///
/// It is the line a deletion is decided on, and a store built without the test target records no reference from a test: said bare, it states an absence nobody checked, and a type used only by its tests reads as one nothing uses. So where test files have no unit in the store, each verdict says so after `recorded in the store`, and names the build that adds them, as the `used by` tally does; where a test build ran and the files sit outside any target it builds, it names them as that, with no build advice no build would act on.
struct ZeroUseVerdict {
    /// What follows `recorded in the store`: the test files and the targets the store does not hold, or empty where it holds every one.
    let hedge: String
    /// The non-test targets no store holds a unit for that write an asked name (``TargetsNotBuilt``), found once for the answer, whose header and tallies read them from here.
    let targetsNotBuilt: TargetsNotBuilt
    /// The test files without a unit where a test build ran, those it skipped and those outside any target it builds; empty where every test file has a unit, and where no test build ran, since the hedge's build advice is then what adds them.
    let filesOutsideTheBuild: [String]
    /// The sites of the asked symbols set aside as recorded only by a build older than their file's last edit, by repo-relative path: an empty answer is then about the current builds, not the whole store.
    private var setAside = SetAsideSites()

    /// What an absence is said to be recorded in.
    var recordedIn: String {
        setAside.isEmpty ? "recorded in the store" : "recorded in the current builds"
    }

    /// Adds the sites the store `store` set aside for the asked symbol `usr`, `byLine` counting them per absolute file path and line.
    mutating func noteSetAside(ofUSR usr: String, inStore store: String, _ byLine: [String: [Int: Int]], relativePath: (String) -> String) {
        setAside.note(ofUSR: usr, inStore: store, byLine, relativePath: relativePath)
    }

    /// Adds what another reader of the same answer noted, a site never counted twice.
    mutating func noteSetAside(_ other: SetAsideSites) {
        setAside.merge(other)
    }

    /// The verdicts of an answer asking about `declarations`, whose names decide the targets not built it names.
    init(store: IndexStore, context: SemanticContext, projectDirectories: [String] = [], declarations: [SymbolRow]) throws {
        targetsNotBuilt = try TargetsNotBuilt(writing: declarations, in: store, context: context, projectDirectories: projectDirectories)
        let targetHedge = Self.targetHedge(targetsNotBuilt.names)
        let coverage = try context.testFileCoverage(in: store)
        let unbuilt = coverage.withoutUnit
        if unbuilt == 0 {
            hedge = targetHedge
            filesOutsideTheBuild = []
        } else if coverage.build.isEmpty {
            // The classification `affected` reads: a file the last build skipped is told apart from one no build would add.
            let classified = try context.testFilesWithoutUnit(in: store, projectDirectories: projectDirectories)
            var parts: [String] = []
            if !classified.unbuilt.isEmpty {
                parts.append("\(classified.unbuilt.count) test file\(classified.unbuilt.count == 1 ? "" : "s") not in the last build — rebuild the tests to count them")
            }
            if !classified.outsideTargets.isEmpty {
                parts.append(classified.unbuilt.isEmpty ? TestFileCoverage.outsideTargets(classified.outsideTargets.count) : "\(classified.outsideTargets.count) outside any built target")
            }
            hedge = "; not counting " + parts.joined(separator: ", and ") + targetHedge
            filesOutsideTheBuild = classified.unbuilt + classified.outsideTargets
        } else {
            filesOutsideTheBuild = []
            hedge = "; \(unbuilt) test file\(unbuilt == 1 ? " is" : "s are") not in it (\(coverage.build))" + targetHedge
        }
    }

    /// The clause naming the targets no store holds a unit for, empty where there are none.
    static func targetHedge(_ targets: [String]) -> String {
        guard !targets.isEmpty else { return "" }
        return "; not counting \(SemanticAxis.namingTargets(targets)), which \(targets.count == 1 ? "is" : "are") not built"
    }

    /// The one line saying how many sites were set aside, or `nil` where none were.
    var setAsideLine: String? {
        setAside.line
    }

    /// The verdict for the `empty` declarations of `eligible` asked about, or `nil` where none is empty.
    func summary(_ empty: [String], eligible: Int, noun: String, preposition: String) -> String? {
        guard !empty.isEmpty else { return nil }
        if eligible == 1, let only = empty.first {
            return "no \(noun) \(preposition) \(only) \(recordedIn)" + hedge
        }
        let scope = empty.count == eligible
            ? "any of the \(eligible) declarations"
            : "\(empty.count) of \(eligible) declarations"
        return "no \(noun) \(recordedIn) for \(scope): \(empty.joined(separator: ", "))" + hedge
    }
}
