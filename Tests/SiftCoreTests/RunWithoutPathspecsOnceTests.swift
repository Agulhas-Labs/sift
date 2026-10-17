//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the set-aside's pathspecs being named in the headline and the set-aside line only, every other line saying "the change".
struct RunWithoutPathspecsOnceTests {
    private static var pathspecs: String {
        "Sources/Alpha.swift Sources/Beta.swift"
    }

    /// A proof over two pathspecs names them twice, however many tests and guards it lists.
    @Test
    func twoPathspecsAreNamedOnlyByTheHeadlineAndTheSetAsideLine() {
        let text = Self.rendered()

        #expect(text.components(separatedBy: Self.pathspecs).count - 1 == 2, "\(text)")
        #expect(text.hasPrefix("✔ 3 of 3 fail without \(Self.pathspecs) and pass with it; 1 named guard passes both ways\n"), "\(text)")
        #expect(text.contains("  set aside and put back: 2 paths under \(Self.pathspecs)"), "\(text)")
    }

    /// Each pinning test's line, and the guard's, say "the change" in place of the list.
    @Test
    func aTestLineSaysTheChangeInPlaceOfThePathspecs() {
        let text = Self.rendered()

        #expect(text.contains("  ✔ shoutingWorks() — fails without the change, passes with it\n"), "\(text)")
        #expect(text.contains("  ✔ sizeIsCarried() — fails without the change, passes with it\n"), "\(text)")
        #expect(text.contains("  ✔ theGridReflows() — a named guard: passes without the change and with it\n"), "\(text)")
    }

    /// A test that passes without the change says so with "the change" too.
    @Test
    func aTestThatPinsNothingSaysTheChangeToo() {
        let text = Self.rendered(without: ["shoutingWorks()": true, "sizeIsCarried()": false, "theGridReflowsAfterARotation()": false, "theGridReflows()": true])

        #expect(text.contains("  ✘ shoutingWorks() — passes without the change too, so it pins nothing\n"), "\(text)")
        #expect(text.components(separatedBy: Self.pathspecs).count - 1 == 2, "\(text)")
    }

    /// Processes stopped before the changes went back are counted without the list.
    @Test
    func theStragglersLineSaysTheChange() {
        let line = RunWithoutAnswer.stragglersLine(2)

        #expect(line == "  stopped 2 processes the run without the change left running, before putting the changes back")
    }

    private static func rendered(
        without: [String: Bool] = ["shoutingWorks()": false, "sizeIsCarried()": false, "theGridReflowsAfterARotation()": false, "theGridReflows()": true]
    ) -> String {
        let record = SetAsideRecord(
            id: "0123456789",
            pathspecs: ["Sources/Alpha.swift", "Sources/Beta.swift"],
            directory: "",
            head: String(repeating: "a", count: 40),
            since: nil,
            owner: 1,
            entries: [
                SetAsideRecord.Entry(path: "Sources/Alpha.swift", status: "1 M. N... 100644 100644 100644 a b", head: nil, index: .absent, worktree: .absent),
                SetAsideRecord.Entry(path: "Sources/Beta.swift", status: "?", head: nil, index: .absent, worktree: .absent),
            ],
            leftInPlace: []
        )
        let passing = ["shoutingWorks()": true, "sizeIsCarried()": true, "theGridReflowsAfterARotation()": true, "theGridReflows()": true]
        let directory = URL(fileURLWithPath: "/nonexistent")
        return RunWithoutAnswer(
            pathspecs: pathspecs,
            without: RunWithoutAnswerTests.run(without),
            with: RunWithoutAnswerTests.run(passing),
            restored: SetAside.Restored(record: record, kept: [], headNow: nil),
            workingDirectory: directory,
            repositoryRoot: directory,
            guards: ["theGridReflows()"]
        ).render().text
    }
}
