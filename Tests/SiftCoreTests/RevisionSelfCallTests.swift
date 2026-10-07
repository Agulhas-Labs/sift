//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `where Box.init --at` reads the revision's files spelling a `Self(x)` call too, as the working-tree sweep parses them: a protocol extension in a file of its own spells neither the type nor `init`, and left unread its calls were missing from the count.
@Suite(.temporaryDirectories)
struct RevisionSelfCallTests {
    @Test
    func anInitializerSweepAtARevisionCountsTheSelfCallsTheWorkingTreeCounts() async throws {
        let root = try SyntacticCallerSelfCallTests.repo()
        let caveat = "but Self(…) in an extension is called once with those labels on a type the scan cannot tell"

        let working = try await WhereInitializerCallsTests.lookup("Box.init(size:)", in: root)
        let revision = try await SiftEngine(directory: root).lookup(symbol: "Box.init(size:)", at: "HEAD")

        #expect(working.contains(caveat), "\(working)")
        #expect(revision.contains(caveat), "\(revision)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(revision).contains("  Sources/App/Maker.swift:2  in Maker.make()"), "\(revision)")
        #expect(revision.contains("those naming `init` or `Box` or spelling `Self(`"), "\(revision)")
    }
}
