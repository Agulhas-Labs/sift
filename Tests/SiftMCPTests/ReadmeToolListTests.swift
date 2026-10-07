//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the one sentence in the README that tells a reader what they have just registered.
///
/// It sits on the page that explains `claude mcp add`, read by someone with no other way to find out, and a stale count is worse than a vague one: `search` and `strings` are exactly the tools an agent has to be told about, since neither is something you would guess at from `digest` and `where`. It drifts in the other direction too — a tool removed leaves the sentence naming one that is not there — so the assertion is set-equality against the catalog rather than a count.
struct ReadmeToolListTests {
    private static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent() // SiftMCPTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // the repository root

    /// The names between backticks in one line of prose.
    private static func backticked(in line: some StringProtocol) -> Set<String> {
        Set(line.split(separator: "`", omittingEmptySubsequences: false)
            .enumerated()
            .filter { $0.offset % 2 == 1 }
            .map { String($0.element) })
    }

    /// Read off the catalog rather than counted by hand, so adding a tool without documenting it fails here.
    @Test
    func theReadmeNamesEveryToolTheServerExposesAndNoOthers() throws {
        let readme = try String(contentsOf: Self.repository.appending(path: "README.md"), encoding: .utf8)
        let sentence = try #require(
            readme.split(whereSeparator: \.isNewline).first { $0.contains("The server exposes only the query tools") },
            "the README no longer says what the server exposes"
        )
        let exposed = Set(MCPToolCatalog.tools(loadUpFront: false).compactMap { $0["name"] as? String })

        #expect(!exposed.isEmpty)
        #expect(Self.backticked(in: sentence) == exposed)
    }
}
