//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// The merge `install-hook --agent codex` makes in Codex's `hooks.json`, and its inverse.
struct CodexHooksMergeTests {
    private static var binary: String {
        "/opt/tools/bin/sift"
    }

    /// A `hooks.json` holding someone else's handlers: a group of its own on an event this registers for, and an event this never touches.
    private static var foreignHooks: String {
        #"{"hooks":{"PreToolUse":[{"hooks":[{"command":"/usr/local/bin/audit-log.sh","timeout":5,"type":"command"}],"matcher":"Bash"}],"Stop":[{"hooks":[{"command":"/usr/local/bin/notify.sh","type":"command"}]}]},"telemetry":false}"#
    }

    private static func object(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any], sourceLocation: sourceLocation)
    }

    /// `text` reserialized the way the merge writes a file, so a removal can be compared with it byte for byte.
    private static func canonical(_ text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: object(Data(text.utf8)), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    @Test func anEmptyFileGetsTheThreeEventsInCodexsShapeWithThePlainSubcommands() throws {
        let change = try CodexHooksFile.apply(to: nil, binaryWord: Self.binary)

        #expect(change.changed)
        let written = try Self.object(change.data)
        let expected = try Self.object(Data(#"""
        {"hooks":{
          "SessionStart":[{"hooks":[{"type":"command","command":"/opt/tools/bin/sift session-start"}]}],
          "PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"/opt/tools/bin/sift pre-tool-use"}]}],
          "PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"/opt/tools/bin/sift post-tool-use"}]}]
        }}
        """#.utf8))
        #expect(NSDictionary(dictionary: written).isEqual(to: expected))
    }

    @Test func aSecondApplyChangesNothingAndRemovalRestoresTheForeignFileByteForByte() throws {
        let original = try Self.canonical(Self.foreignHooks)
        let installed = try CodexHooksFile.apply(to: original, binaryWord: Self.binary)
        let again = try CodexHooksFile.apply(to: installed.data, binaryWord: Self.binary)
        let removed = try CodexHooksFile.remove(from: installed.data)
        let removedAgain = try CodexHooksFile.remove(from: removed.data)

        #expect(installed.changed)
        #expect(!again.changed)
        #expect(again.data == installed.data)
        #expect(removed.changed)
        #expect(removed.data == original)
        #expect(removed.removed.count == 3)
        #expect(!removedAgain.changed)
    }

    @Test func aForeignGroupKeepsItsPlaceAndOursIsAppendedAfterIt() throws {
        let installed = try CodexHooksFile.apply(to: Data(Self.foreignHooks.utf8), binaryWord: Self.binary)
        let events = try #require(Self.object(installed.data)["hooks"] as? [String: Any])
        let groups = try #require(events["PreToolUse"] as? [[String: Any]])

        #expect(groups.count == 2)
        #expect(groups.first?["matcher"] as? String == "Bash")
        #expect((groups.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/usr/local/bin/audit-log.sh")
        #expect((groups.last?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/opt/tools/bin/sift pre-tool-use")
        #expect(events["Stop"] != nil)
    }

    @Test func removingOursFromAMixedGroupKeepsTheForeignHandlerAndTheMatcher() throws {
        let mixed = #"{"hooks":{"PreToolUse":[{"hooks":[{"command":"/opt/tools/bin/sift pre-tool-use","type":"command"},{"command":"/usr/local/bin/audit-log.sh","type":"command"}],"matcher":"*"}]}}"#
        let removed = try CodexHooksFile.remove(from: Data(mixed.utf8))
        let groups = try #require((Self.object(removed.data)["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])

        #expect(removed.removed == ["PreToolUse — /opt/tools/bin/sift pre-tool-use"])
        #expect(groups.count == 1)
        #expect(groups.first?["matcher"] as? String == "*")
        #expect((groups.first?["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } == ["/usr/local/bin/audit-log.sh"])
    }

    @Test func aMovedBinaryIsRepointedInPlaceAndADuplicateDropped() throws {
        let stale = #"{"hooks":{"PreToolUse":[{"hooks":[{"command":"/old/bin/sift pre-tool-use","type":"command"}],"matcher":"*"},{"hooks":[{"command":"/other/bin/sift pre-tool-use","type":"command"}],"matcher":"*"}]}}"#
        let change = try CodexHooksFile.apply(to: Data(stale.utf8), binaryWord: Self.binary)
        let groups = try #require((Self.object(change.data)["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])

        #expect(change.replaced == ["/old/bin/sift pre-tool-use"])
        #expect(groups.count == 1)
        #expect((groups.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/opt/tools/bin/sift pre-tool-use")
    }

    @Test func aCursorRegistrationAndALookalikeAreNeverClaimed() throws {
        let others = #"{"hooks":{"PreToolUse":[{"hooks":[{"command":"/opt/tools/bin/sift pre-tool-use --agent cursor","type":"command"},{"command":"/opt/tools/bin/sifter pre-tool-use","type":"command"}]}]}}"#

        #expect(try !CodexHooksFile.remove(from: Data(others.utf8)).changed)
    }

    @Test(arguments: [#"[1,2]"#, #"{"hooks":[]}"#, #"{"hooks":{"PreToolUse":{"hooks":[]}}}"#, #"{"hooks":{"PreToolUse":[{"hooks":{"command":"x"}}]}}"#])
    func aFileOfAnotherShapeIsRefusedNamingCodex(text: String) throws {
        let error = try #require(throws: CursorConfigJSON.Unmergeable.self) { try CodexHooksFile.apply(to: Data(text.utf8), binaryWord: Self.binary) }

        #expect(error.harness == "Codex")
        #expect(!error.description.contains("Cursor"))
    }
}
