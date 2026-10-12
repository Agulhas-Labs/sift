//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A build file that renames a target's module through a setting this tool cannot read does declare those files; the banner and `sift init` say so, rather than that nothing declares them, and `init` proposes no module for them, since the target's own name is the one the build replaces.
@Suite(.temporaryDirectories)
struct UnreadableRenameBannerTests {
    /// A spec whose framework target `Kit` over `Sources/Kit` is renamed through `$(FOO)`, beside a directory no build file claims.
    private static func writeRepo(at root: URL) throws {
        try TestSources.write(
            """
            name: Pair
            targets:
              Kit:
                type: framework
                platform: iOS
                sources: [Sources/Kit]
                settings:
                  PRODUCT_MODULE_NAME: $(FOO)

            """,
            to: "project.yml",
            in: root
        )
        try TestSources.write("public struct Widget {}\n", to: "Sources/Kit/Widget.swift", in: root)
        try TestSources.write("struct Old {}\n", to: "Legacy/Old.swift", in: root)
    }

    @Test
    func aDigestOfAnUnreadablyRenamedFileSaysABuildFileRenamesIt() async throws {
        let root = try TestSources.makeTempRepo()
        try Self.writeRepo(at: root)
        try TestSources.commitAll(in: root, message: "renamed module")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        let digest = try engine.digest(target: "Widget", options: DigestOptions())
        let legacy = try engine.digest(target: "Legacy/Old.swift", options: DigestOptions())

        #expect(digest.contains(GuessedModuleNotice.Reason.unreadableRename.opening + "Sources/Kit/Widget.swift"), Comment(rawValue: digest))
        #expect(!digest.contains(GuessedModuleNotice.bannerOpening), Comment(rawValue: digest))
        #expect(!digest.contains("take its `moduleMap` proposals"), Comment(rawValue: digest))
        #expect(legacy.contains(GuessedModuleNotice.bannerOpening + "Legacy/Old.swift"), Comment(rawValue: legacy))
    }

    @Test
    func initListsAnUnreadableRenameApartAndProposesNoModuleForIt() throws {
        let root = try TestSources.makeTempDirectory()
        try Self.writeRepo(at: root)
        let plan = ConfigPlan.make(repoRoot: root, config: SiftConfig(), paths: ["Sources/Kit/Widget.swift", "Legacy/Old.swift"])

        let report = ConfigPlanRenderer.render(plan: plan, wrote: nil)

        #expect(plan.unreadableRenames.map(\.prefix) == ["Sources/Kit"])
        #expect(plan.unresolvedGroups.map(\.prefix) == ["Legacy"])
        #expect(plan.resolvedFileCount == 0)
        #expect(plan.merged(onto: SiftConfig()).moduleMap == ["Legacy": "Legacy"])
        #expect(report.contains("    \"Sources/Kit\"   — 1 file(s)"), Comment(rawValue: report))
        #expect(!report.contains("\"Sources/Kit\": \"Kit\""), Comment(rawValue: report))
        let flat = report.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for cause in ["conditional value", "settings group", "quoted xcconfig value", "or one that is missing"] {
            #expect(flat.contains(cause), Comment(rawValue: report))
        }
        #expect(report.contains("⚠ 1 file(s) in 1 group(s) have NO declaring build file."), Comment(rawValue: report))
    }

    /// Answers printed as one keep one banner per reason, and a part that opens on both loses both.
    @Test
    func hoistingKeepsOneBannerPerReason() throws {
        let undeclared = try #require(GuessedModuleNotice(paths: ["Legacy/Old.swift"]).banner)
        let renamed = try #require(GuessedModuleNotice(paths: ["Sources/Kit/Widget.swift"], reason: .unreadableRename).banner)

        let (answers, banner) = GuessedModuleNotice.hoisted(from: ["\(undeclared)\n\n\(renamed)\n\nfirst", "\(renamed)\n\nsecond"])

        #expect(answers == ["first", "second"])
        #expect(banner == "\(undeclared)\n\n\(renamed)")
    }

    /// An answer's first part sits past both banners, so its header is still read as one.
    @Test
    func theFirstPartSitsPastBothBanners() throws {
        let undeclared = try #require(GuessedModuleNotice(paths: ["Legacy/Old.swift"]).banner)
        let renamed = try #require(GuessedModuleNotice(paths: ["Sources/Kit/Widget.swift"], reason: .unreadableRename).banner)
        let lines = "\(undeclared)\n\n\(renamed)\n\nWidget — Kit".split(separator: "\n", omittingEmptySubsequences: false)

        #expect(SourcePassthrough.firstPartLine(of: lines) == 4)
    }
}
