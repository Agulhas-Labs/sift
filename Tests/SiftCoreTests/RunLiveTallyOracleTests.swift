//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the hand-written line reads the live tally and the test outcomes take on every line against the regexes and Foundation calls they replaced, and the byte screen in front of the tally against reading every line.
struct RunLiveTallyOracleTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 0)

    private static let captures = [
        "swift-test-fail", "swift-test-pass", "swift-test-mixed-xctest-failure", "swift-test-colored-warning-and-failure",
        "swift-test-display-name", "swift-build-success", "xcodebuild-test-failure", "xcodebuild-test-success",
        "xcodebuild-retry-iterations", "swift-test-parallel-filter-pass",
    ]

    /// Every hand-written read answers what the code it replaced answered, on every line of every capture and of a generated corpus, at every point of the line a caller could hand it.
    @Test
    func everyReadAnswersWhatTheOldCodeAnswered() throws {
        var lines = try Self.captures.flatMap { try TestSources.runOutput($0).components(separatedBy: "\n") }
        var generator = SplitMix64(seed: 7)
        lines += (0 ..< 3000).map { _ in Self.corpusLine(using: &generator) }
        for raw in lines {
            let line = RunOutputLines.cleaned(raw)
            #expect(RunLineScan.parallelTestName(in: line) == Oracle.parallelTestName(in: line), "\(line.debugDescription)")
            #expect(RunLineScan.trimmingWhitespace(line[...]) == line.trimmingCharacters(in: .whitespaces), "\(line.debugDescription)")
            #expect(RunBuildStep.named(in: line) == Oracle.buildStep(in: line), "\(line.debugDescription)")
            // Every point a duration or an iteration could be read from, on a line naming either; the line's start on any other.
            let readsANumber = line.contains("second") || line.contains("Iteration")
            let points = readsANumber ? line.indices.filter { " (s".contains(line[$0]) } + [line.startIndex, line.endIndex] : [line.startIndex]
            for index in points {
                let tail = line[index...]
                #expect(RunLineScan.xctestSeconds(in: tail) == Oracle.xctestSeconds(in: tail), "\(tail.debugDescription)")
                #expect(RunLineScan.swiftTestingSeconds(in: tail) == Oracle.swiftTestingSeconds(in: tail), "\(tail.debugDescription)")
                #expect(RunLineScan.iterationNumber(in: tail) == Oracle.iterationNumber(in: tail), "\(tail.debugDescription)")
            }
        }
    }

    /// The screened tally, fed chunks cut at random bytes, stands after every chunk where a tally handed each line that chunk completed, unscreened, does: a line the screen skips is one no reader could have counted.
    ///
    /// The first seeds generate no test line, so the run stays building and every step a line names is compared.
    @Test(arguments: 0 ..< 40)
    func theScreenedTallyMatchesOneReadingEveryLine(seed: UInt64) throws {
        var generator = SplitMix64(seed: seed)
        let buildOnly = seed < 10
        var text = (0 ..< 400).map { _ in Self.corpusLine(using: &generator, buildOnly: buildOnly) + (generator.chance(4) ? "\r\n" : "\n") }.joined()
        if seed.isMultiple(of: 2), !buildOnly {
            text += try TestSources.runOutput(Self.captures[Int(seed) % Self.captures.count])
        }
        if generator.chance(2) {
            text += "[7/9] Testing Widget"
        }
        let bytes = Data(text.utf8)
        var cutter = RunOutputLines()
        let lines = cutter.split(bytes)
        let trailing = cutter.remainder()

        var screened = RunLiveTally(startedAt: Self.start)
        var unscreened = RunLiveTally(startedAt: Self.start)
        var offset = 0
        var linesRead = 0
        while offset < bytes.count {
            let length = min(bytes.count - offset, 1 + Int(generator.next() % 300))
            screened.consume(bytes.subdata(in: offset ..< offset + length), now: Self.start)
            offset += length
            let completed = bytes.prefix(offset).count { $0 == UInt8(ascii: "\n") }
            for line in lines[linesRead ..< completed] {
                unscreened.consume(line: line, now: Self.start)
            }
            linesRead = completed
            #expect(screened.state == unscreened.state, "after byte \(offset)")
        }
        _ = screened.finish(now: Self.start)
        if let trailing {
            unscreened.consume(line: trailing, now: Self.start)
        }

        #expect(screened.state == unscreened.state)
    }

    /// Each line the screen skips leaves a tally in either phase exactly as it found it.
    @Test
    func aLineTheScreenSkipsChangesNothing() {
        var generator = SplitMix64(seed: 11)
        var building = RunLiveTally(startedAt: Self.start)
        var testing = RunLiveTally(startedAt: Self.start)
        testing.consume(line: "Test Suite 'All tests' started at 2026-01-01", now: Self.start)
        for _ in 0 ..< 3000 {
            let line = Self.corpusLine(using: &generator)
            let skipped = Array(line.utf8).withUnsafeBytes { !RunLiveLineScreen.mayMatter($0) }
            guard skipped else {
                continue
            }
            for tally in [building, testing] {
                var reading = tally
                reading.consume(line: line, now: Self.start.addingTimeInterval(1))
                #expect(reading.state == tally.state, "\(line.debugDescription)")
            }
            building.consume(line: "[1/2] Compiling Widget A.swift", now: Self.start)
            testing.consume(line: "Test Case '-[WidgetTests shoutingWorks]' started.", now: Self.start)
        }
    }
}

extension RunLiveTallyOracleTests {
    /// The pieces the generated corpus is built of: every shape the tally reads, its near misses, and lines nothing reads.
    private static let bodies = [
        "[12/340] Compiling Widget Gizmo.swift", "[12/340] Compiling WidgetTests Gizmo.swift", "[5/6] Linking WidgetTests",
        "[3/12] Testing WidgetTests/shoutingWorks", "[3/12] Testing ", "[3/12]Testing Widget", "[3/] Testing Widget", "[/3] Testing Widget",
        "[3/12] Testing a\rb", "[3/12] Testing a\u{0B}b", "[3/12] Testing a\u{0C}b", "[\u{661}/\u{662}] Testing Widget", "[3/12] Testing Gizmó",
        "[32\u{2009}/\u{2009}55]\u{2009}Pallet", "[32 / 55]", "[32 / 55]  ", "[4/6]\u{2009}Compiling MixedTests Modern.swift", "[x/y] Widget", "[",
        "SwiftCompile normal arm64 /src/Gizmo/Gizmo.swift (in target 'Gizmo' from project 'Gizmo')",
        "SwiftCompile normal arm64 /src/My\\ Gizmo/Big\\ Gizmo.swift (in target 'Gizmo' from project 'Gizmo')",
        "CompileSwift normal arm64 /src/Gizmo/Gizmó.swift (in target 'Gizmo' from project 'Gizmo')",
        "CompileSwift normal arm64 /src/Gizmo/", "SwiftCompile normal arm64 Gizmo.swift", "CompileSwift normal arm64 /a/b (in target 'Gizmo",
        "Test Case '-[WidgetTests shoutingWorks]' started.", "Test Case '-[WidgetTests shoutingWorks]' started (Iteration 2 of 3).",
        "Test Case '-[WidgetTests shoutingWorks]' started (Iteration \u{663} of 3).", "Test Case '-[WidgetTests shoutingWorks]' passed (0.001 seconds).",
        "Test Case '-[WidgetTests shoutingWorks]' failed (1. seconds) (2.5 seconds).", "Test Case '-[WidgetTests shoutingWorks]' skipped (\u{663} seconds) (1 seconds).",
        "Test Case '-[WidgetTests shoutingWorks]' passed (12 seconds", "Test case 'WidgetTests.shoutingWorks()' passed on 'Mac - xctest (1)' (0.1 seconds)",
        "\u{25C7} Test shoutingWorks() started.", "\u{2714} Test shoutingWorks() passed after 0.001 seconds.",
        "\u{2718} Test shoutingWorks() failed after 1.5 seconds with 1 issue.", "Test shoutingWorks() passed after \u{663} seconds.",
        "Test \"The grid keeps its headings\" passed after 2 seconds.", "Test shoutingWorks() with 3 test cases passed after 0.2 seconds.",
        "Test shoutingWorks() started (repetition 2).", "Test shoutingWorks() skipped.", "Test shoutingWorks() passed after 1_0 seconds.",
        "Test run started.", "Test run with 3 tests in 1 suite passed after 0.1 seconds.", "Testing started", "  Testing started\t",
        " \u{301}Testing started", "\u{2009}Testing started\u{3000}", "Testing started.", "Test Suite 'All tests' started at 2026-01-01",
        "Test suite 'WidgetTests' started on 'Mac'", "Te\u{1B}[0mst Case '-[WidgetTests shoutingWorks]' passed (0.5 seconds).",
        "Another instance of SwiftPM is already running using '/src/.build', waiting until that process has finished execution...Test Suite 'All tests' started at 2026",
        "/src/Widget.swift:3:5: error: cannot find 'Gizmo' in scope", "/src/Widget.swift:4:1: warning: unused", "error: fatal", "warning: Widget",
        "/src/Widget.swift:3:5: err\u{1B}[0mor: split by colour", "    cd /src/Gizmo", "Linking Widget", "", "Ld /src/WidgetTests normal",
        "Build complete!", "Compiling Widget", "SwiftDriver Gizmo normal arm64", "Apple Gizmo", "\u{00E9}rror: Widget",
    ]

    /// The bodies no test runner prints, which leave a run building however many of them arrive.
    private static let buildBodies = bodies.filter { !$0.contains("Test") && !$0.contains("\u{1B}") }

    /// One generated line: a body, sometimes wrapped in colour, sometimes behind an output barrier, sometimes with a leading carriage return.
    private static func corpusLine(using generator: inout SplitMix64, buildOnly: Bool = false) -> String {
        let pool = buildOnly ? buildBodies : bodies
        var line = pool[Int(generator.next() % UInt64(pool.count))]
        if generator.chance(5) {
            line = "\u{1B}[1m" + line + "\u{1B}[0m"
        }
        if generator.chance(6) {
            line = RunOutputLines.outputBarrier + line
        }
        if generator.chance(20) {
            line = "\r" + line
        }
        return line
    }

    /// A seeded generator, so a failing corpus is the same corpus on the next run.
    private struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        /// True one time in `odds`.
        mutating func chance(_ odds: UInt64) -> Bool {
            next() % odds == 0
        }
    }

    /// The reads as they stood before they were hand-written, copied verbatim: the answer each new one must give.
    private struct Oracle {
        static func parallelTestName(in line: String) -> String? {
            guard line.hasPrefix("["), let match = line.prefixMatch(of: #/\[\d+/\d+\] Testing (.+)/#) else {
                return nil
            }
            return String(match.output.1)
        }

        static func iterationNumber(in tail: Substring) -> Int {
            guard let match = tail.prefixMatch(of: #/started \(Iteration (\d+) of \d+\)/#) else {
                return 1
            }
            return Int(match.output.1) ?? 1
        }

        static func xctestSeconds(in tail: Substring) -> Double? {
            guard let match = tail.firstMatch(of: #/\((\d+(?:\.\d+)?) seconds\)/#) else {
                return nil
            }
            return Double(match.output.1)
        }

        static func swiftTestingSeconds(in tail: Substring) -> Double? {
            guard let match = tail.prefixMatch(of: #/ \w+ after (\d+(?:\.\d+)?) seconds/#) else {
                return nil
            }
            return Double(match.output.1)
        }

        static func buildStep(in line: String) -> String? {
            if line.hasPrefix("[") {
                return swiftPMStep(in: line)
            }
            if line.hasPrefix("SwiftCompile ") || line.hasPrefix("CompileSwift ") {
                return xcodebuildCompile(in: line)
            }
            return nil
        }

        private static func swiftPMStep(in line: String) -> String? {
            guard let close = line.firstIndex(of: "]") else {
                return nil
            }
            let counter = line[line.index(after: line.startIndex) ..< close]
            guard counter.contains("/"), counter.allSatisfy({ $0.isNumber || $0 == "/" || $0.isWhitespace }) else {
                return nil
            }
            var step = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if step.hasPrefix("Compiling ") {
                step = String(step.dropFirst("Compiling ".count))
            }
            return step.isEmpty ? nil : step
        }

        private static func xcodebuildCompile(in line: String) -> String? {
            var body = Substring(line)
            var target: Substring?
            if let clause = line.range(of: " (in target '", options: .backwards) {
                body = line[..<clause.lowerBound]
                let rest = line[clause.upperBound...]
                target = rest.range(of: "'").map { rest[..<$0.lowerBound] }
            }
            guard let slash = body.lastIndex(of: "/") else {
                return nil
            }
            let file = body[body.index(after: slash)...].replacingOccurrences(of: "\\ ", with: " ")
            guard !file.isEmpty else {
                return nil
            }
            return target.map { "\($0) \(file)" } ?? file
        }
    }
}
