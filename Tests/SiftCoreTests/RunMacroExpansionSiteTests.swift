//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A compile error raised inside a macro expansion is located in the expansion's buffer, which names no file a reader can open; the source line it sits at comes from the compiler's note beneath it.
struct RunMacroExpansionSiteTests {
    private static var message: String {
        "property access can throw, but it is not marked with 'try' and the error is not handled"
    }

    private static var testFile: String {
        "/Users/dev/Widget/Tests/WidgetTests/WidgetTests.swift"
    }

    /// Two `#require`s failing the same way, in the compiler's default diagnostic style: each error names only `macro expansion #require:1:54`, and the `` `- <file>:<line>:<col>: note: expanded code originates here`` beneath it names the source line.
    ///
    /// Both errors print the same buffer location and the same sentence, so before the site was read the second was dropped as a copy of the first.
    @Test func anErrorInsideAMacroExpansionCarriesTheSourceLineItSitsAt() throws {
        let report = try TestSources.runReport("swift-test-macro-expansion-error", invokedAs: ["swift", "test"], exitCode: 1)

        #expect(report.errors.map(\.described) == [
            "macro expansion #require:1:54: error: \(Self.message) (expanded at \(Self.testFile):7)",
            "macro expansion #require:1:54: error: \(Self.message) (expanded at \(Self.testFile):13)",
        ])
    }

    /// Under `-diagnostic-style=llvm` a nested expansion prints one note per level, innermost first: the `#require` inside `#expect(...)` is noted at the `#expect` expansion's own buffer, and only then at the source line the `#expect` sits at.
    @Test func aNestedExpansionIsWalkedToTheSourceLineOfTheOutermost() throws {
        let report = try TestSources.runReport("swift-test-macro-expansion-error-llvm", invokedAs: ["swift", "test"], exitCode: 1)
        let described = report.errors.map(\.described)
        try #require(described.count == 2)

        #expect(described[0].contains("@__swiftmacro_"))
        #expect(described[0].hasSuffix("error: \(Self.message) (expanded at \(Self.testFile):7)"))
        #expect(described[1].contains("@__swiftmacro_"))
        #expect(described[1].hasSuffix("error: \(Self.message) (expanded at \(Self.testFile):13)"))
    }

    /// The site's path is stated the way the answer states every other path: relative to the directory it is read in.
    @Test func theRenderedAnswerStatesTheSiteRelativeToTheReader() throws {
        let report = try TestSources.runReport("swift-test-macro-expansion-error", invokedAs: ["swift", "test"], exitCode: 1)
        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(report, exitCode: 1, logURL: URL(fileURLWithPath: "/Users/dev/Widget/.sift/runs/run-20000101-120000-00000000.log"))
        let lines = answer.components(separatedBy: "\n")

        #expect(lines.contains("  macro expansion #require:1:54: error: \(Self.message) (expanded at Tests/WidgetTests/WidgetTests.swift:7)"))
        #expect(lines.contains("  macro expansion #require:1:54: error: \(Self.message) (expanded at Tests/WidgetTests/WidgetTests.swift:13)"))
    }

    /// Served as a sample, an example's sentence is clipped and the site after it is not: it is the one location in the line a reader can open.
    @Test func aClippedExampleKeepsItsSite() {
        let long = "type of expression is ambiguous without a type annotation " + String(repeating: "and the words go on ", count: 12)
        var filter = RunOutputFilter(invokedAs: ["swift", "build"])
        for line in 1 ... 12 {
            filter.consume(line: "macro expansion #expect:1:9: error: \(long)")
            filter.consume(line: "`- \(Self.testFile):\(line * 3):5: note: expanded code originates here")
        }
        let report = filter.finish(exitCode: 1)
        #expect(report.errors.count == 12)
        let rendered = RunErrorShape.of(report.errors, changedFiles: .unavailable("not consulted")).rendered()
        let example = rendered.first { $0.contains("characters — see the raw log") }
        #expect(example?.hasSuffix("(expanded at \(Self.testFile):3)  ×12") == true)
    }

    /// With no note beneath it, an expansion's error reads as it always has: the buffer's location alone, and a second identical one collapsing into the first.
    @Test func anExpansionErrorWithNoNoteIsUnchanged() {
        var filter = RunOutputFilter(invokedAs: ["swift", "build"])
        filter.consume(line: "macro expansion #require:1:54: error: \(Self.message)")
        filter.consume(line: "Failed frontend command:")
        filter.consume(line: "macro expansion #require:1:54: error: \(Self.message)")
        let report = filter.finish(exitCode: 1)

        #expect(report.errors.map(\.described) == ["macro expansion #require:1:54: error: \(Self.message)"])
    }

    /// A note about an expansion is read only for an error raised inside one: beneath an error in a source file it is the compiler's excerpt, and the error keeps its own location alone.
    @Test func anExpansionNoteBeneathAnOrdinaryErrorIsNotRead() {
        var filter = RunOutputFilter(invokedAs: ["swift", "build"])
        filter.consume(line: "\(Self.testFile):7:25: error: cannot find 'widget' in scope")
        filter.consume(line: "`- \(Self.testFile):9:5: note: expanded code originates here")
        let report = filter.finish(exitCode: 1)

        #expect(report.errors.map(\.described) == ["\(Self.testFile):7:25: error: cannot find 'widget' in scope"])
    }
}
