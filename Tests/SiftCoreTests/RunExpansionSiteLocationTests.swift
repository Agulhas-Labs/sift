//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// An error raised inside a macro expansion is about the file the expansion sits in, not the buffer the compiler locates it in: the census counts that file, and `run --without` asks that file whether it holds tests.
struct RunExpansionSiteLocationTests {
    private static var message: String {
        "property access can throw, but it is not marked with 'try' and the error is not handled"
    }

    private static var testFile: String {
        "Tests/WidgetTests/WidgetTests.swift"
    }

    /// An ordinary error and an expansion's error in one test file are one file, and both are in it when the tree changed it.
    ///
    /// Counted on the buffer, `macro expansion #require` was a second file and one the working tree never changes.
    @Test func theCensusCountsTheFileAnExpansionSitsIn() {
        var filter = RunOutputFilter(invokedAs: ["swift", "build"])
        filter.consume(line: "\(Self.testFile):3:5: error: cannot find 'Gadget' in scope")
        filter.consume(line: "macro expansion #require:1:54: error: \(Self.message)")
        filter.consume(line: "`- \(Self.testFile):7:49: note: expanded code originates here")
        let report = filter.finish(exitCode: 1)
        let shape = RunErrorShape.of(report.errors, changedFiles: .of([Self.testFile]))

        #expect(report.errors.count == 2)
        #expect(shape.census.fileCount == 1)
        #expect(shape.census.inChangedFiles == .count(2))
    }
}

extension RunWithoutAnswerTests {
    /// An error inside a `#require` expansion in a test file, without the change, is the tests not compiling — the same as an error written in that file.
    ///
    /// Asked of the buffer's name, `macro expansion #require` imports nothing, and the run was misread as a build that failed.
    @Test
    func anExpansionErrorInATestFileIsTheTestsNotCompiling() throws {
        let directory = try Self.directory(holding: ["Tests/WidgetTests/WidgetTests.swift": "import Testing\n@testable import Widgets\n"])
        let without = Self.failedBeforeTests("""
        macro expansion #require:1:54: error: property access can throw, but it is not marked with 'try' and the error is not handled
        `- Tests/WidgetTests/WidgetTests.swift:7:49: note: expanded code originates here

        """)

        let judged = Self.judged(without: without, with: Self.run(["shoutingWorks()": true]), workingDirectory: directory)
        let text = judged.render().text

        #expect(text.hasPrefix("◇ the tests did not compile without Sources/ — evidence they need it, not a failing assertion; 1 of 1 passes with it"), "\(text)")
        #expect(!judged.proven)
    }
}
