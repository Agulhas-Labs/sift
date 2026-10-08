//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A build's or test run's warnings list in log order, and a warning repeating one signature is listed once with its count.
///
/// The acceptance case is `Fixtures/RunOutput/swift-build-release-pcm-warnings.txt`, a trim of a real release build whose unlocated `.pcm` warnings differ only in the path they name. The rest pin what must never be merged.
struct RunWarningSignatureTests {
    private static let root = URL(fileURLWithPath: "/Users/dev/Widget")

    @Test
    func aReleaseBuildsPcmWarningsListAsOneLineWithTheirCount() throws {
        let capture = "swift-build-release-pcm-warnings"
        let report = try TestSources.runReport(
            capture,
            invokedAs: ["swift", "build", "-c", "release", "-Xcc", "-ffile-prefix-map=/Users/dev/Widget=/sift"],
            exitCode: 0
        )
        let printed = try TestSources.runOutput(capture).components(separatedBy: "\n").filter { $0.hasPrefix("warning: ") }
        #expect(printed.count == 23)
        #expect(Set(printed).count == 23)
        #expect(report.warnings.count == 23)
        let first = try #require(printed.first)
        #expect(first.hasSuffix("/CoreFoundation-3QQ9KF0POLJUJTHGEB1BW495J.pcm: No such file or directory"))

        let section = Self.warningsSection(of: report, kind: .swiftBuild)
        #expect(section == ["warnings (23):", "  \(first)  ×23"])
    }

    @Test
    func distinctWarningsAtDistinctSitesKeepTheFlatListing() {
        let section = Self.warningsSection(of: [
            "/Users/dev/Widget/Sources/Widget/Widget.swift:3:9: warning: unused value 19",
            "/Users/dev/Widget/Sources/Widget/Widget.swift:8:9: warning: unused value 20",
            "/Users/dev/Widget/Sources/WidgetRow/WidgetRow.swift:12:5: warning: 'spare' was never used",
        ])

        #expect(section == [
            "warnings (3):",
            "  Sources/Widget/Widget.swift:3:9: warning: unused value 19",
            "  Sources/Widget/Widget.swift:8:9: warning: unused value 20",
            "  Sources/WidgetRow/WidgetRow.swift:12:5: warning: 'spare' was never used",
        ])
    }

    @Test
    func oneMessageAtSeveralSitesIsListedAtItsFirstSiteWithACount() {
        let section = Self.warningsSection(of: [
            "/Users/dev/Widget/Sources/Widget/Widget.swift:3:9: warning: 'spare' was never used",
            "/Users/dev/Widget/Sources/WidgetRow/WidgetRow.swift:12:5: warning: 'spare' was never used",
            "/Users/dev/Widget/Sources/Widget/Widget.swift:8:9: warning: unused value 20",
        ])

        #expect(section == [
            "warnings (3):",
            "  Sources/Widget/Widget.swift:3:9: warning: 'spare' was never used  ×2",
            "  Sources/Widget/Widget.swift:8:9: warning: unused value 20",
        ])
    }

    @Test
    func unlocatedWarningsDifferingInMoreThanAPathStayApart() {
        let section = Self.warningsSection(of: [
            "warning: /sift/out/Darwin-Q8V9J2H3LUDJIYZSYYY9488P.pcm: No such file or directory",
            "warning: /sift/out/Dispatch-AJS5BT0EVS7QPD5VP76UQM0DD.pcm: Permission denied",
            "warning: /sift/out/XPC-B6KCQXQ4625W3PONPO92PXTZ2.pcm: No such file or directory",
            "/Users/dev/Widget/Sources/Widget/Widget.swift:3:9: warning: /sift/out/XPC-B6KCQXQ4625W3PONPO92PXTZ2.pcm: No such file or directory",
        ])

        #expect(section == [
            "warnings (4):",
            "  warning: /sift/out/Darwin-Q8V9J2H3LUDJIYZSYYY9488P.pcm: No such file or directory  ×2",
            "  warning: /sift/out/Dispatch-AJS5BT0EVS7QPD5VP76UQM0DD.pcm: Permission denied",
            "  Sources/Widget/Widget.swift:3:9: warning: /sift/out/XPC-B6KCQXQ4625W3PONPO92PXTZ2.pcm: No such file or directory",
        ])
    }

    @Test
    func unlocatedWarningsAgainstDifferentFilesStayApart() {
        let section = Self.warningsSection(of: [
            "/Users/dev/Widget/Widget.xcodeproj: warning: duplicate output file",
            "/Users/dev/Gadget/Gadget.xcodeproj: warning: duplicate output file",
            "warning: duplicate output file",
        ], kind: .xcodebuild)

        #expect(section.first == "warnings (3):")
        #expect(section.count == 4)
        #expect(section.contains { $0.contains("Widget.xcodeproj") })
        #expect(section.contains { $0.contains("Gadget.xcodeproj") })
        #expect(section.contains("  warning: duplicate output file"))
        #expect(!section.contains { $0.contains("×") })
    }

    @Test
    func onlyAnAbsolutePathIsElided() {
        let section = Self.warningsSection(of: [
            "warning: file '/Users/dev/Widget/a.json' is unhandled",
            "warning: file '/Users/dev/Widget/b.json' is unhandled",
            "ld: warning: linking with dylib '@rpath/XCTest.framework/Versions/A/XCTest'",
            "ld: warning: linking with dylib '@rpath/Gizmo.framework/Gizmo'",
            "warning: read and/or write a.json",
            "warning: read and/or write b.json",
        ])

        #expect(section == [
            "warnings (6):",
            "  warning: file '/Users/dev/Widget/a.json' is unhandled  ×2",
            "  warning: linking with dylib '@rpath/XCTest.framework/Versions/A/XCTest'",
            "  warning: linking with dylib '@rpath/Gizmo.framework/Gizmo'",
            "  warning: read and/or write a.json",
            "  warning: read and/or write b.json",
        ])
    }

    @Test
    func theCapCountsLinesAndTheWithheldCountCountsWarnings() {
        let pcm = (0 ..< 3).map { "warning: /sift/out/Darwin-\($0)Q8V9J2H3LUDJIYZSYYY948.pcm: No such file or directory" }
        let located = (0 ..< 22).map { "/Users/dev/Widget/Sources/Widget/File\($0).swift:1:1: warning: unused value \($0)" }
        let section = Self.warningsSection(of: pcm + located)

        #expect(section.first == "warnings (25):")
        #expect(section.dropFirst().first?.hasSuffix("No such file or directory  ×3") == true)
        // Twenty lines: the grouped one and nineteen located warnings, so 3 of the 25 are withheld.
        #expect(section.count == 22)
        #expect(section.contains("  Sources/Widget/File18.swift:1:1: warning: unused value 18"))
        #expect(!section.contains { $0.contains("unused value 19") })
        #expect(section.last == "  +3 more warnings — see the raw log")
    }

    @Test
    func aTestRunsWarningsGroupTheSameWay() {
        let section = Self.warningsSection(of: [
            "warning: /sift/out/Darwin-Q8V9J2H3LUDJIYZSYYY9488P.pcm: No such file or directory",
            "warning: /sift/out/XPC-B6KCQXQ4625W3PONPO92PXTZ2.pcm: No such file or directory",
        ], kind: .swiftTest)

        #expect(section == [
            "warnings (2):",
            "  warning: /sift/out/Darwin-Q8V9J2H3LUDJIYZSYYY9488P.pcm: No such file or directory  ×2",
        ])
    }
}

private extension RunWarningSignatureTests {
    /// The warnings section of the answer to a run whose log is `lines`.
    static func warningsSection(of lines: [String], kind: RunCommandKind = .swiftBuild) -> [String] {
        var filter = RunOutputFilter(expecting: .unreadable)
        for line in lines {
            filter.consume(line: line)
        }
        return warningsSection(of: filter.finish(), kind: kind)
    }

    /// The `warnings (N):` line and every indented line beneath it.
    static func warningsSection(of report: RunReport, kind: RunCommandKind) -> [String] {
        let answer = RunReportRenderer(kind: kind, workingDirectory: root).render(report, exitCode: 0, logURL: nil)
        let lines = answer.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("warnings (") }) else {
            return []
        }
        return [lines[start]] + lines[(start + 1)...].prefix { $0.hasPrefix("  ") }
    }
}
