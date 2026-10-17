//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a parameterised test, which a run prints with its argument labels, being matched by its bare name wherever a name is matched.
@Suite(.temporaryDirectories)
struct RunWithoutGuardParameterizedTests {
    /// Each printed shape reduces to the bare name; a quoted display name is unchanged by the label rule, so `"the widget (beta)"` still reduces to its last word.
    @Test(arguments: [
        ("aRunsWidget()", "aRunsWidget"),
        ("aRunsWidget(count:label:)", "aRunsWidget"),
        ("aRunsWidget(_:)", "aRunsWidget"),
        ("GizmoTests/aRunsWidget(count:)", "aRunsWidget"),
        ("GizmoTests.aRunsWidget()", "aRunsWidget"),
        ("\"the widget (beta)\"", "beta"),
    ])
    func aPrintedNameReducesToItsBareName(printed: String, bare: String) {
        #expect(RunWithoutAnswer.identifier(of: printed) == bare)
    }

    /// A guard written as a bare name, or with `()`, matches the test printed with its argument labels.
    @Test(arguments: ["aRunsWidget", "aRunsWidget()"])
    func aGuardMatchesAParameterizedTestPrintedWithItsLabels(named: String) {
        #expect(RunWithoutGuards.matches("aRunsWidget(count:label:)", named))
    }

    /// A set-aside test file that declares a parameterised test is found for the name the run printed, so the note says the committed test ran.
    @Test
    func aParameterizedTestsDeclarationIsFoundByItsPrintedName() throws {
        let directory = try RunWithoutAnswerTests.directory(holding: [
            "Tests/GizmoTests/GizmoTests.swift": "import Testing\n@Test(arguments: [1, 2]) func aRunsWidget(count: Int) {\n}\n",
        ])

        let judged = RunWithoutAnswerTests.judged(
            without: RunWithoutAnswerTests.run(["aRunsWidget(count:)": true]),
            with: RunWithoutAnswerTests.run(["aRunsWidget(count:)": true]),
            workingDirectory: directory,
            alsoSetAside: ["Tests/GizmoTests/GizmoTests.swift"]
        )

        #expect(judged.render().text.contains("  note: Tests/GizmoTests/GizmoTests.swift was also set aside, so this ran the committed test"))
    }
}
