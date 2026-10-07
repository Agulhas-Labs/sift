//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A shell statement's command word is named by its own path text, never by the working directory it runs in.
struct CommandWordNamingTests {
    /// A dot, a directory followed by a dot, and an empty word each name what they spell, so none reads as the directory it would resolve to.
    ///
    /// Resolved against the working directory, the word `.` took the directory's own name and one ending in a dot took its parent's: a sourced script run in a directory named for the tool read as a call of the tool, and a word ending in a dot after the tool's name read as the tool.
    @Test
    func aWordIsNamedByItsTextAlone() {
        #expect(!ShellQuery(". ./env.sh").invokesSift)
        #expect(!ShellQuery("'' status").invokesSift)
        #expect(!ShellQuery("sift/. status").invokesSift)
        #expect(RunCommandKind.recognize(["swift/.", "test"]) == .unrecognized)
        #expect(RunCommandKind.recognize([".", "test"]) == .unrecognized)
        #expect(RunCommandKind.recognize(["", "test"]) == .unrecognized)
        #expect(!InPlaceShape.movesDirectory("cd/. Sources"))

        #expect(ShellQuery("./.build/debug/sift status").invokesSift)
        #expect(ShellQuery("sift where Depot").invokesSift)
        #expect(RunCommandKind.recognize(["/usr/bin/swift", "test"]) == .swiftTest)
        #expect(InPlaceShape.movesDirectory("cd Sources"))
    }
}
