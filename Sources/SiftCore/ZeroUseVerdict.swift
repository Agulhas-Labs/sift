//
// Copyright © Agulhas Labs
//

import Foundation

/// The single line `where` replaces a per-declaration "none recorded in the store" block with, for any relation: `no references to X recorded in the store`, `no callers of …`, `no reads or writes of …`, `no uses of …`.
///
/// It is the line a deletion is decided on, and a store built without the test target records no reference from a test: said bare, it states an absence nobody checked, and a type used only by its tests reads as one nothing uses. So where test files have no unit in the store, each verdict says so after `recorded in the store`, and names the build that adds them, as the `used by` tally does; where a test build ran and the files sit outside any target it builds, it names them as that, with no build advice no build would act on.
struct ZeroUseVerdict {
    /// What follows `recorded in the store`: the test files the store does not hold, or empty where it holds every one.
    let hedge: String

    init(store: IndexStore, context: SemanticContext, projectDirectories: [String] = []) throws {
        let coverage = try context.testFileCoverage(in: store)
        let unbuilt = coverage.withoutUnit
        if unbuilt == 0 {
            hedge = ""
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
            hedge = "; not counting " + parts.joined(separator: ", and ")
        } else {
            hedge = "; \(unbuilt) test file\(unbuilt == 1 ? " is" : "s are") not in it (\(coverage.build))"
        }
    }

    /// The verdict for the `empty` declarations of `eligible` asked about, or `nil` where none is empty.
    func summary(_ empty: [String], eligible: Int, noun: String, preposition: String) -> String? {
        guard !empty.isEmpty else { return nil }
        if eligible == 1, let only = empty.first {
            return "no \(noun) \(preposition) \(only) recorded in the store" + hedge
        }
        let scope = empty.count == eligible
            ? "any of the \(eligible) declarations"
            : "\(empty.count) of \(eligible) declarations"
        return "no \(noun) recorded in the store for \(scope): \(empty.joined(separator: ", "))" + hedge
    }
}
