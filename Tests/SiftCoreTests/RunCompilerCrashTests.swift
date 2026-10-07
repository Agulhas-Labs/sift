//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers what `sift run` answers when the Swift compiler crashes: the pass, the function and the verifier's `Error!` line, never the frontend command.
///
/// The lines are the shapes Swift 6.4 printed for a release-build optimizer crash and for a frontend that took a signal, with the capturing machine's paths replaced by the Widget package's; the frontend command is stood in for by one line of the size the real one had.
struct RunCompilerCrashTests {
    /// The optimizer crash the answer was shaped on: a verifier `Error!`, the fatal-error line, a stack dump naming the pass, and the frontend command.
    @Test
    func aCompilerCrashAnswersWithItsPassItsFunctionAndItsErrorLine() {
        let (answer, report) = Self.answer(to: Self.optimizerCrash)

        #expect(report.isUsable(exitCode: 1))
        let lines = answer.split(separator: "\n").map(String.init)
        #expect(lines.first == "✘ swift build — exit 1 — compiler crashed")
        // The demangler is the toolchain's own, so the second line is either spelling of the function.
        #expect(lines.dropFirst().first == "  While running pass #315370 SILFunctionTransform \"CopyPropagation\" on Runner.run()"
            || lines.dropFirst().first == "  While running pass #315370 SILFunctionTransform \"CopyPropagation\" on SILFunction \"@$s6Widget6RunnerV3runyyKF\".")
        #expect(report.compilerCrash?.lines(demangling: { _ in "Runner.run()" }).first == "  While running pass #315370 SILFunctionTransform \"CopyPropagation\" on Runner.run()")
        #expect(lines.contains("    for 'run()' (at /Users/dev/Widget/Sources/Widget/Runner.swift:57:10)"))
        #expect(lines.contains("  Error! Found a leak due to a consuming post-dominance failure!"))
        #expect(lines.contains("    Value:   %5 = load [copy] %4 : $*Optional<String>"))
        #expect(!answer.contains("Failed frontend command"))
        #expect(!answer.contains("Program arguments"))
        #expect(!answer.contains("-frontend"))
        #expect(!answer.contains("fatal error encountered"))
        #expect(answer.utf8.count < 600)
    }

    /// A frontend that took a signal prints no fatal-error line, and the bug-report request and the frontend command still say it crashed.
    @Test
    func aSignalCrashWithNoFatalErrorLineIsStillACompilerCrash() {
        let (answer, report) = Self.answer(to: Self.signalCrash)

        #expect(report.isUsable(exitCode: 1))
        #expect(answer.hasPrefix("✘ swift build — exit 1 — compiler crashed\n"))
        #expect(!answer.contains("Program arguments"))
        #expect(!answer.contains("-frontend"))
        #expect(answer.utf8.count < 400)
    }

    /// A function the demangler cannot read is named as the compiler printed it.
    @Test
    func aSymbolTheDemanglerCannotReadIsNamedAsPrinted() {
        let lines = [
            "Please submit a bug report (https://swift.org/contributing/#reporting-bugs) and include the crash backtrace.",
            "Stack dump:",
            "0.\tProgram arguments: \(Self.frontendCommand)",
            "1.\tWhile running pass #12 SILFunctionTransform \"CopyPropagation\" on SILFunction \"@not_a_symbol\".",
            "error: Build failed",
        ]
        let (answer, _) = Self.answer(to: lines)

        #expect(answer.contains("  While running pass #12 SILFunctionTransform \"CopyPropagation\" on SILFunction \"@not_a_symbol\"."))
    }

    /// A selected run whose build crashed the compiler did not build: the crash is the evidence, since the one line it prints at a file and line is the crash reader's, and the run exits 5 with the crash beneath the headline.
    @Test
    func aSelectedRunWhoseCompilerCrashedDidNotBuild() throws {
        let arguments = ["swift", "test", "--filter", "works"]
        var filter = RunOutputFilter(invokedAs: arguments)
        for line in Self.optimizerCrash {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 1)
        let selector = try #require(RunTestSelector.named(in: arguments))
        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"), selector: selector)
            .render(report, exitCode: 1, logURL: nil)
        let lines = answer.split(separator: "\n").map(String.init)

        #expect(selector.ownExitCode(report, exitCode: 1) == RunTestSelector.didNotBuildExitCode)
        #expect(lines.first == "✘ swift test — did not build — no test ran (the command exited 1; sift run exits 5) — compiler crashed")
        #expect(lines.contains("  Error! Found a leak due to a consuming post-dominance failure!"))
    }

    /// A test that prints a crash's sentences at the head of a line and then fails is a test failure: once a test has started the compiler has stopped, so the lines are the test's, and a note quoting them keeps them.
    @Test
    func aTestPrintingACrashsSentencesIsNotACompilerCrash() throws {
        let (answer, report) = Self.answer(to: [
            "Build complete! (1.20s)",
            "◇ Test run started.",
            "◇ Suite WidgetTests started.",
            "◇ Test aTestThatFailed() started.",
            "error: fatal error encountered during compilation; please submit a bug report",
            "Please submit a bug report (https://swift.org/contributing/#reporting-bugs) and include the crash backtrace.",
            "✘ Test aTestThatFailed() recorded an issue at WidgetTests.swift:6:5: Expectation failed: log.isEmpty",
            "↳ Please submit a bug report (https://swift.org/contributing/#reporting-bugs) and include the crash backtrace.",
            "✘ Test aTestThatFailed() failed after 0.001 seconds with 1 issue.",
            "✘ Suite WidgetTests failed after 0.001 seconds with 1 issue.",
            "✘ Test run with 1 test in 1 suite failed after 0.001 seconds with 1 issue.",
        ], testing: true)
        let note = try #require(report.testFailures.first?.note)

        #expect(report.compilerCrash == nil)
        #expect(!answer.contains("compiler crashed"))
        #expect(answer.contains("aTestThatFailed()"))
        #expect(note.contains("Please submit a bug report"))
    }

    /// An XCTest assertion whose message runs on across unmarked lines can quote a whole stack dump, and none of it is a compiler crash or a pass to name.
    @Test
    func anAssertionMessageQuotingAStackDumpIsNotACompilerCrash() {
        let (answer, report) = Self.answer(to: [
            "Build complete! (1.20s)",
            "Test Suite 'All tests' started at 2026-09-29 12:00:00.000.",
            "Test Suite 'WidgetTests.xctest' started at 2026-09-29 12:00:00.000.",
            "Test Suite 'WidgetTests' started at 2026-09-29 12:00:00.000.",
            "Test Case '-[WidgetTests.WidgetTests testCrashes]' started.",
            "/Users/dev/Widget/Tests/WidgetTests/WidgetTests.swift:12: error: -[WidgetTests.WidgetTests testCrashes] : XCTAssertEqual failed: (\"\") is not equal to (\"crash",
            "Please submit a bug report (https://swift.org/contributing/#reporting-bugs) and include the crash backtrace.",
            "Stack dump:",
            "1.\tWhile running pass #1 SILFunctionTransform \"CopyPropagation\" on SILFunction \"@$s6Widget6RunnerV3runyyKF\".",
            "\")",
            "Test Case '-[WidgetTests.WidgetTests testCrashes]' failed (0.001 seconds).",
            "Test Suite 'WidgetTests' failed at 2026-09-29 12:00:00.001.",
            "\t Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.001) seconds",
            "Test Suite 'WidgetTests.xctest' failed at 2026-09-29 12:00:00.001.",
            "\t Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.001) seconds",
            "Test Suite 'All tests' failed at 2026-09-29 12:00:00.001.",
            "\t Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.001) seconds",
        ], testing: true)

        #expect(report.compilerCrash == nil)
        #expect(!answer.contains("compiler crashed"))
        #expect(!answer.contains("While running pass"))
        #expect(answer.contains("testCrashes"))
    }

    /// A build's own `error: fatal error encountered …` with no `<unknown>:0:` in front is any program's error, not the frontend's crash: only the two lines a crashing compiler prints mark one.
    @Test
    func aBareFatalErrorLineIsNotACompilerCrash() {
        let (answer, report) = Self.answer(to: [
            "[3/9] Compiling Widget Runner.swift",
            "error: fatal error encountered during compilation; please submit a bug report",
            "error: Build failed",
        ])

        #expect(report.compilerCrash == nil)
        #expect(!answer.contains("compiler crashed"))
    }

    /// No line of any answer is the size of a line a log can carry: the indented cause an error ending in `:` carries with it is quoted in full by both forms of the errors block, so one running to tens of kilobytes is cut at the cap, with the count of what the raw log still holds.
    @Test
    func noLineOfAnAnswerIsTheSizeOfALineTheLogCarried() {
        let lines = [
            "error: Could not resolve package dependencies:",
            "  \(Self.frontendCommand)",
        ]
        let (answer, _) = Self.answer(to: lines)
        let widest = answer.split(separator: "\n").map(\.utf8.count).max() ?? 0

        #expect(widest <= RunReportRenderer.lineCap + 500)
        #expect(answer.contains("characters — see the raw log)"))
        #expect(answer.utf8.count < 2 * RunReportRenderer.lineCap)
    }

    /// A compile error spelling a long type is a complete listing, and the cap is far enough above it that its tail, the part naming the target type, survives.
    @Test
    func anErrorLineOfAFewKilobytesKeepsItsTail() {
        let type = "Wrapped<" + String(repeating: "VStack<Group<(Text, Image)>>, ", count: 118) + "Text>"
        let error = "/Users/dev/Widget/Sources/Widget/Screen.swift:9:5: error: cannot convert value of type '\(type)' to specified type 'Target'"
        #expect(error.utf8.count > 3500)
        #expect(error.utf8.count < 4000)
        let (answer, _) = Self.answer(to: (1 ... 60).map { "[\($0)/60] Compiling Widget File\($0).swift" } + [error, "error: Build failed"])

        #expect(answer.contains("to specified type 'Target'"))
        #expect(!answer.contains("the raw log keeps this line whole"))
    }
}

private extension RunCompilerCrashTests {
    /// One line the size of the frontend command a module of a few hundred files is compiled with.
    static let frontendCommand = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend -c"
        + String(repeating: " /Users/dev/Widget/Sources/Widget/Widget.swift", count: 1300)

    static let optimizerCrash = [
        "Building for production...",
        "[412 / 590] Compiling Widget Runner.swift",
        "Error! Found a leak due to a consuming post-dominance failure!",
        "    Value:   %5 = load [copy] %4 : $*Optional<String>",
        "    Post Dominating Failure Blocks:",
        "        bb3",
        "<unknown>:0: error: fatal error encountered during compilation; please submit a bug report (https://swift.org/contributing/#reporting-bugs) and include the crash backtrace",
        "Please submit a bug report (https://swift.org/contributing/#reporting-bugs) and include the crash backtrace.",
        "Stack dump:",
        "0.\tProgram arguments: \(frontendCommand)",
        "1.\tApple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)",
        "2.\tCompiling with the current language version",
        "3.\tWhile evaluating request ExecuteSILPipelineRequest(Run pipelines { Mandatory Diagnostic Passes + Enabling Optimization Passes, Serialization, Rest of Onone } on SIL for Widget)",
        "4.\tWhile running pass #315370 SILFunctionTransform \"CopyPropagation\" on SILFunction \"@$s6Widget6RunnerV3runyyKF\".",
        " for 'run()' (at /Users/dev/Widget/Sources/Widget/Runner.swift:57:10)",
        "Stack dump without symbol names (ensure you have llvm-symbolizer in your PATH or set the environment var `LLVM_SYMBOLIZER_PATH` to point to it):",
        "0  swift-frontend           0x0000000109a3c1f0 start + 6688",
        "Failed frontend command:",
        frontendCommand,
        "error: Build failed",
    ]

    static let signalCrash = [
        "Building for production...",
        "[18 / 25]",
        "Please submit a bug report (https://swift.org/contributing/#reporting-bugs) and include the crash backtrace.",
        "Stack dump:",
        "0.\tProgram arguments: \(frontendCommand)",
        "1.\tApple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)",
        "2.\tCompiling with the current language version",
        "Stack dump without symbol names (ensure you have llvm-symbolizer in your PATH or set the environment var `LLVM_SYMBOLIZER_PATH` to point to it):",
        "0  swift-frontend           0x000000010984fbd0 start + 56",
        "Failed frontend command:",
        frontendCommand,
        "error: Build failed",
    ]

    /// `lines` read as a failed `swift build -c release`'s output — or, `testing`, a failed `swift test`'s — and rendered as `sift run` answers it.
    static func answer(to lines: [String], testing: Bool = false) -> (String, RunReport) {
        var filter = RunOutputFilter(invokedAs: testing ? ["swift", "test"] : ["swift", "build", "-c", "release"])
        for line in lines {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 1)
        let answer = RunReportRenderer(kind: testing ? .swiftTest : .swiftBuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(report, exitCode: 1, logURL: URL(fileURLWithPath: "/Users/dev/Widget/.sift/runs/run-20260929-120000-0a1b2c3d.log"))
        return (answer, report)
    }
}
