//
// Copyright © Agulhas Labs
//

import Foundation

/// How many test bundles a run was *expected* to report, which is the one thing its own log never says.
///
/// **A bundle that reported nothing is invisible in the output it did not produce.** The log counts the processes that started (``RunReport/testProcessOpenings``) and the counts they closed on, so a bundle that launched and died is already visible as an opening with no closing. A bundle that never *built* announces nothing at all — no opening, no tally, no counter — while every surviving line still says `passed`, and that silence is what `Docs/Design.md`'s `totals:` contract could not name until something outside the log said how many there should have been.
///
/// **The count comes from the package, because the run does not carry it.** The `<Name>Tests-product` names in a build's progress lines look like the answer and are not: they include whatever packages the suite itself builds as fixtures, and a run where nothing needed rebuilding prints no progress lines at all — five of eight recorded runs of this repository have none. What is stable is the manifest: `swift test` builds one test bundle per `.testTarget` the package declares, and each of those bundles closes on a tally of its own.
///
/// **So it degrades to ``undetermined`` on every shape where that reasoning does not hold**, and an undetermined expectation prints nothing — the answer states how many bundles reported and says nothing about how many were owed, exactly as it did before this existed. That is the case for any command but `swift test`, for a directory with no readable `Package.swift`, for a manifest that declares no test target under a literal name — one built in a loop or from a computed value reads as none rather than as a wrong count, since ``SwiftPMManifest`` is deliberately syntactic — and for any run whose arguments narrow what runs or where it runs (``narrowingOptions``).
public enum RunTestBundles: Sendable, Equatable {
    /// Nothing outside the log is in a position to say how many bundles were owed a count.
    case undetermined
    /// How many `.testTarget`s the package's own manifest declares, which is how many test bundles `swift test` builds and runs.
    case declaredByManifest(Int)
}

public extension RunTestBundles {
    /// What the package in `directory` declares, for a run of `arguments` — and ``undetermined`` for anything this reasoning does not cover.
    ///
    /// Reads one file and parses it syntactically, so a wrapped run pays a manifest parse and never a subprocess; it is asked for only where the answer can carry a `totals:` line, which is `swift test` alone.
    static func declared(forRunOf arguments: [String], in directory: URL) -> RunTestBundles {
        guard RunCommandKind.recognize(arguments) == .swiftTest else {
            return .undetermined
        }
        guard !arguments.contains(where: { argument in
            narrowingOptions.contains(where: { argument == $0 || argument.hasPrefix($0 + "=") })
        }) else {
            return .undetermined
        }
        let manifest = SwiftPMManifest.parse(fileAt: directory.appendingPathComponent("Package.swift"))
        // A `#if`-guarded test target is written whatever the platform and built only on some, and which is
        // which cannot be decided from the text — so its count is about the manifest, not about this run.
        guard !manifest.conditionalTestTargets else {
            return .undetermined
        }
        let declared = manifest.testTargets
        return declared.isEmpty ? .undetermined : .declaredByManifest(declared.count)
    }

    /// The `swift test` options that make the manifest's count a statement about the package rather than about this run.
    ///
    /// `--package-path`, `-C` and `--chdir` move the run to another package, so the manifest beside the reader is not the one that ran. The rest narrow *what runs*: `swift test --filter` builds and runs only the test products holding a match, so a healthy filtered run prints one tally where the package declares two — and the shortfall clause would then accuse the run of losing a bundle it was never asked for. `--skip` and `--test-product` narrow the same way, and disabling a framework can silence a bundle rather than a test: a bundle with no `XCTestCase` closes only on `Executed 0 tests, with 0 failures`, which is vestigial and never shown, so it stops being counted as reporting at all.
    ///
    /// **This is the one arithmetic in the line that is not the log's, so it fails toward saying nothing.** A missing clause costs a reader the bundle question on a narrowed run; a wrong one contradicts the answer's own `✔` headline on a run where nothing is wrong, and turns the inner-loop command this repository's conventions ask for — the narrowest test that covers the change — into a red gate.
    static var narrowingOptions: [String] {
        ["--package-path", "-C", "--chdir", "--filter", "--skip", "--test-product", "--disable-swift-testing", "--disable-xctest", "-s", "--specifier"]
    }

    /// The expected count, or `nil` where there is none to compare a run against.
    var count: Int? {
        switch self {
        case .undetermined: nil
        case let .declaredByManifest(count): count
        }
    }
}
