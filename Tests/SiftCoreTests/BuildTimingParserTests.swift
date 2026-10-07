//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// The compiler's timing lines, read off a real capture — `Fixtures/RunOutput/swift-build-debug-time.txt`, whose provenance is in that directory's `PROVENANCE.md`.
struct BuildTimingParserTests {
    @Test
    func everyTimingLineOfTheCaptureIsReadAndNothingElse() throws {
        let timings = try BuildTimingParser.timings(in: TestSources.runOutput("swift-build-debug-time"))

        #expect(timings.count == 47)
        #expect(timings.count { $0.kind == .body } == 11)
    }

    @Test
    func aBodyLineCarriesTheDeclarationsOwnLocation() {
        let line = "7.42ms\t/Users/dev/Widget/Sources/Widget/Slow.swift:4:10\tinstance method Widget.(file).Ledger.total()@/Users/dev/Widget/Sources/Widget/Slow.swift:4:10"

        #expect(BuildTimingParser.timing(in: line) == BuildTiming(
            milliseconds: 7.42,
            path: "/Users/dev/Widget/Sources/Widget/Slow.swift",
            line: 4,
            column: 10,
            kind: .body,
            declarationDescription: "instance method Widget.(file).Ledger.total()@/Users/dev/Widget/Sources/Widget/Slow.swift:4:10"
        ))
    }

    @Test
    func aLocalFunctionsBodyLineCarriesTheCompilersOwnNestedDescription() {
        let line = "3.39ms\t/Users/dev/Widget/Sources/Widget/Slow.swift:26:10\tlocal function Widget.(file).outer().inner()@/Users/dev/Widget/Sources/Widget/Slow.swift:26:10"

        #expect(BuildTimingParser.timing(in: line)?.declarationDescription == "local function Widget.(file).outer().inner()@/Users/dev/Widget/Sources/Widget/Slow.swift:26:10")
    }

    @Test
    func anExpressionLineHasNoThirdField() {
        let line = "3.22ms\t/Users/dev/Widget/Sources/Widget/Slow.swift:5:19"

        #expect(BuildTimingParser.timing(in: line) == BuildTiming(
            milliseconds: 3.22,
            path: "/Users/dev/Widget/Sources/Widget/Slow.swift",
            line: 5,
            column: 19,
            kind: .expression
        ))
    }

    @Test(arguments: [
        "Build complete! (0.54s)",
        "[5/9] Compiling Widget Slow.swift",
        "-Xcc -I/Users/dev/Widget0.37ms\t/Users/dev/Widget/Sources/Widget/main.swift:1:14",
        "0.01ms\t<invalid loc>",
        "0.01ms\t/Users/dev/Widget/Sources/Widget/Slow.swift:4",
        "fastms\t/Users/dev/Widget/Sources/Widget/Slow.swift:4:10",
    ])
    func aLineThatIsNotATimingReadsAsNone(line: String) {
        #expect(BuildTimingParser.timing(in: line) == nil)
    }
}
