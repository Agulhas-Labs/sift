//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// The page's account of *who* made the calls it prices — a file of its own, borrowing the page fixtures next door.
@Suite(.temporaryDirectories)
struct ReportAttributionTests {
    /// The line that introduces the attribution agrees with the line it introduces.
    ///
    /// The note names the agents ("is work 2 subagents did"), so a fixed singular in front of it read as a rendering fault on a page whose whole job is to be believed about its numbers.
    @Test
    func theAttributionLineAgreesWithTheCountItIntroduces() throws {
        // A directory each: the log is named for the directory it sits in, so two of them cannot share one.
        let manyDirectory = try TemporaryDirectory.make("report")
        let oneDirectory = try TemporaryDirectory.make("report")
        let two = try ReportPageTests.writeLog([
            ReportPageTests.entry(tool: "digest", target: "Widget", bytes: (out: 100, source: 1000), agent: "aaa"),
            ReportPageTests.entry(tool: "digest", target: "Engine", bytes: (out: 100, source: 1000), agent: "bbb"),
        ], in: manyDirectory)
        let one = try ReportPageTests.writeLog([
            ReportPageTests.entry(tool: "digest", target: "Widget", bytes: (out: 100, source: 1000), agent: "aaa"),
        ], in: oneDirectory)

        let plural = ReportPage.render(ReportPageTests.assemble(log: two, projects: manyDirectory))
        #expect(plural.contains("2 of those calls came from subagents:"))
        #expect(plural.contains("is work 2 subagents did"))

        let singular = ReportPage.render(ReportPageTests.assemble(log: one, projects: oneDirectory))
        #expect(singular.contains("1 of those calls came from a subagent:"))
        #expect(singular.contains("is work 1 subagent did"))
    }
}
