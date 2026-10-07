import Foundation
@testable import SiftMCP

/// Fixtures whose whole read the hook answers with a digest at the default context size, for a test whose subject is that answer or whose setup needs it.
struct WorthAnsweringFixture {
    /// The padding of ``repository()``: across the depot's forty members it makes the source about 20 KB, so a whole read of it is worth answering while the digest stays as small as ever.
    static let padding = 500

    /// The trailing comment that gives each member of a fixture of a test's own the same padding.
    static let comment = " //" + String(repeating: "x", count: padding - 3)

    /// The bytes a stubbed answer reports for a whole read of a file about as large as ``repository()``'s `Depot`, so the rule judges the read worth answering at the default context size.
    static let answerBytes = AnswerBytes(served: 1, source: padding * 40)

    /// A repository indexed as a session would have left it, whose `Depot` is large enough that a whole read of it is answered with the digest rather than let through.
    ///
    /// The padding adds no line and changes no digest.
    static func repository() async throws -> URL {
        try await InPlaceAnswerTests.indexedRepository(padding: padding)
    }
}
