//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers where the *expected* bundle count comes from, which is the one fact about a test run that its own log never carries.
///
/// A bundle that failed to build announces nothing — no process opening, no counter, no tally — so no reading of the output can miss it, and every line that did print still says `passed`. The count has to come from the package instead, and every shape where that reasoning does not hold has to degrade to `undetermined` rather than assert a number: an expectation that is wrong prints a missing bundle that was never owed.
@Suite(.temporaryDirectories)
struct RunTestBundlesTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Widget",
            targets: [
                .target(name: "Widget"),
                .testTarget(name: "WidgetTests", dependencies: ["Widget"]),
                .testTarget(name: "LegacyWidgetTests", dependencies: ["Widget"]),
            ]
        )
        """
    }

    private static func package(_ source: String = manifest) throws -> URL {
        let directory = try TemporaryDirectory.make("bundles")
        try source.write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        return directory
    }

    /// `swift test` builds one test bundle per `.testTarget`, and each closes on a tally of its own — so the manifest's count is how many counts the run owed.
    @Test
    func theManifestsTestTargetsAreTheBundlesASwiftTestOwesACountFrom() throws {
        let directory = try Self.package()

        #expect(RunTestBundles.declared(forRunOf: ["swift", "test"], in: directory) == .declaredByManifest(2))
        #expect(RunTestBundles.declared(forRunOf: ["swift", "test"], in: directory).count == 2)
    }

    /// A run pointed at another package is undetermined: the manifest beside the reader is then not the one that ran, and a count taken from it would name a bundle the run never owed.
    @Test
    func aRunPointedAtAnotherPackageIsUndetermined() throws {
        let directory = try Self.package()

        #expect(RunTestBundles.declared(forRunOf: ["swift", "test", "--package-path", "Vendor/Thing"], in: directory) == .undetermined)
        #expect(RunTestBundles.declared(forRunOf: ["swift", "test", "--package-path=Vendor/Thing"], in: directory) == .undetermined)
    }

    /// Only `swift test` builds SwiftPM test bundles, and only its answer carries the line this count is for.
    @Test
    func anyCommandButSwiftTestIsUndetermined() throws {
        let directory = try Self.package()

        #expect(RunTestBundles.declared(forRunOf: ["swift", "build"], in: directory) == .undetermined)
        #expect(RunTestBundles.declared(forRunOf: ["xcodebuild", "test", "-scheme", "Widget"], in: directory) == .undetermined)
    }

    /// No manifest, and a manifest whose test targets are not written as literals, both read as *nobody said* rather than as a count of none — the parser is deliberately syntactic, so a computed name is invisible to it and a zero there would be a bundle count no package has.
    @Test
    func aPackageThatCannotBeReadIsUndeterminedRatherThanACountOfNone() throws {
        let empty = try TemporaryDirectory.make("bundles-empty")
        #expect(RunTestBundles.declared(forRunOf: ["swift", "test"], in: empty) == .undetermined)

        let computed = try Self.package("""
        // swift-tools-version: 6.0
        import PackageDescription

        let suffix = "Tests"
        let package = Package(name: "Widget", targets: [.testTarget(name: "Widget" + suffix)])
        """)
        #expect(RunTestBundles.declared(forRunOf: ["swift", "test"], in: computed) == .undetermined)
        #expect(RunTestBundles.declared(forRunOf: ["swift", "test"], in: computed).count == nil)
    }

    /// An argument that narrows *what runs* makes the manifest's count a statement about the package rather than about this run, so there is nothing to compare against.
    ///
    /// `swift test --filter` builds and runs only the test products holding a match, so a healthy filtered run of a two-bundle package prints one tally. Compared against the manifest that reads as a bundle lost, and the answer then says `⚠ incomplete` under its own `✔ swift test` headline — on a run where nothing is wrong, for the command this repository's conventions ask for between edits.
    @Test
    func anArgumentThatNarrowsWhatRunsIsUndetermined() throws {
        let directory = try Self.package()

        for narrowing in [
            ["--filter", "WidgetTests"],
            ["--filter=WidgetTests"],
            ["--skip", "GizmoTests"],
            ["--skip=GizmoTests"],
            ["--test-product", "WidgetTests"],
            ["--test-product=WidgetTests"],
            ["--disable-swift-testing"],
            ["--disable-xctest"],
        ] {
            #expect(
                RunTestBundles.declared(forRunOf: ["swift", "test"] + narrowing, in: directory) == .undetermined,
                "\(narrowing.joined(separator: " ")) narrows what runs, so the manifest cannot speak for it"
            )
        }

        // The control: the same package, run whole, still has an expectation to compare against.
        #expect(RunTestBundles.declared(forRunOf: ["swift", "test"], in: directory).count != nil)
    }

    /// A `#if`-guarded test target is written whatever the platform and built only on some, so counting it makes every healthy run of that package report a bundle short.
    ///
    /// The manifest is parsed syntactically — deliberately, since executing one is slow and arbitrary — and SwiftSyntax hands back both branches of an `#if` as written. Which branch this build took cannot be recovered from the text, so the count is declined rather than guessed.
    @Test
    func aConditionalTestTargetIsUndeterminedRatherThanCounted() throws {
        let conditional = try Self.package("""
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Widget",
            targets: [
                .testTarget(name: "WidgetTests"),
                #if os(Linux)
                    .testTarget(name: "DepotKitTests"),
                #endif
            ]
        )
        """)

        let manifest = SwiftPMManifest.parse(fileAt: conditional.appendingPathComponent("Package.swift"))

        // The parse still sees both, which is right for every other reader of it — a source path maps the same
        // whatever the platform. It is this count, and only this count, that cannot use them.
        #expect(manifest.testTargets == ["WidgetTests", "DepotKitTests"])
        #expect(manifest.conditionalTestTargets)
        #expect(RunTestBundles.declared(forRunOf: ["swift", "test"], in: conditional) == .undetermined)
    }
}
