//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The merges behind `install-hook --agent cursor`: the exact shapes written into `hooks.json` and `mcp.json`, recognition by shape, foreign entries carried verbatim, and removal as the exact inverse.
struct CursorConfigMergeTests {
    private static var binary: String {
        "/opt/tools/bin/sift"
    }

    /// A `hooks.json` holding someone else's hook on two of the events this registers for, plus a key this tool never writes.
    private static var foreignHooks: String {
        #"{"hooks":{"preToolUse":[{"command":"/usr/local/bin/audit-log.sh","failClosed":true}],"stop":[{"command":"/usr/local/bin/notify.sh"}]},"telemetry":false,"version":1}"#
    }

    /// A `mcp.json` holding another server.
    private static var foreignServers: String {
        #"{"mcpServers":{"notes":{"args":["serve"],"command":"/opt/notes/bin/notes"}}}"#
    }

    private static func object(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any], sourceLocation: sourceLocation)
    }

    /// `data` reserialized the way the merge writes a file, so a fixture and a merge's output compare byte for byte.
    private static func canonical(_ text: String) throws -> Data {
        try CursorConfigJSON.encode(object(Data(text.utf8)))
    }

    @Test
    func anEmptyHooksFileGetsTheThreeEventsWithTheAgentFlagAndNothingElse() throws {
        let change = try CursorHooksFile.apply(to: nil, binaryWord: Self.binary)

        #expect(change.changed)
        let file = try Self.object(change.data)
        #expect(file["version"] as? Int == 1)
        let hooks = try #require(file["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["sessionStart", "preToolUse", "postToolUse"])
        for (event, subcommand) in [("sessionStart", "session-start"), ("preToolUse", "pre-tool-use"), ("postToolUse", "post-tool-use")] {
            let entries = try #require(hooks[event] as? [[String: Any]])
            #expect(entries.count == 1, "\(event)")
            #expect(entries.first?.keys.sorted() == ["command"], "\(event): only the command, never failClosed")
            #expect(entries.first?["command"] as? String == "\(Self.binary) \(subcommand) --agent cursor", "\(event)")
        }
    }

    @Test
    func aSecondApplyChangesNothingAndRemovalRestoresTheForeignFileByteForByte() throws {
        let foreign = try Self.canonical(Self.foreignHooks)
        let installed = try CursorHooksFile.apply(to: foreign, binaryWord: Self.binary)
        #expect(installed.changed)

        let again = try CursorHooksFile.apply(to: installed.data, binaryWord: Self.binary)
        #expect(!again.changed)
        #expect(again.data == installed.data)

        let file = try Self.object(installed.data)
        let preToolUse = try #require((file["hooks"] as? [String: Any])?["preToolUse"] as? [[String: Any]])
        #expect(preToolUse.count == 2)
        #expect(preToolUse.first?["command"] as? String == "/usr/local/bin/audit-log.sh")
        #expect(preToolUse.first?["failClosed"] as? Bool == true)
        #expect(file["telemetry"] as? Bool == false)

        let removed = try CursorHooksFile.remove(from: installed.data)
        #expect(removed.removed.count == 3)
        #expect(removed.data == foreign)
        #expect(try !CursorHooksFile.remove(from: removed.data).changed)
    }

    @Test
    func aClaudeCodeRegistrationAndALookalikeAreNeverClaimed() throws {
        let hooks = #"{"hooks":{"sessionStart":[{"command":"/opt/tools/bin/sift session-start"},{"command":"/opt/siftscience/sift-agent session-start --agent cursor"}]},"version":1}"#
        let foreign = try Self.canonical(hooks)

        #expect(try !CursorHooksFile.remove(from: foreign).changed)
        let installed = try CursorHooksFile.apply(to: foreign, binaryWord: Self.binary)
        let sessionStart = try #require((Self.object(installed.data)["hooks"] as? [String: Any])?["sessionStart"] as? [[String: Any]])
        #expect(sessionStart.compactMap { $0["command"] as? String } == [
            "/opt/tools/bin/sift session-start",
            "/opt/siftscience/sift-agent session-start --agent cursor",
            "\(Self.binary) session-start --agent cursor",
        ])
    }

    @Test
    func aMovedBinaryIsRepointedInPlaceAndADuplicateDropped() throws {
        let stale = #"{"hooks":{"sessionStart":[{"command":"/old/sift session-start --agent cursor","timeout":9},{"command":"/usr/local/bin/notify.sh"},{"command":"/old/sift session-start --agent cursor"}]},"version":1}"#

        let change = try CursorHooksFile.apply(to: Self.canonical(stale), binaryWord: Self.binary)

        #expect(change.replaced == ["/old/sift session-start --agent cursor"])
        let sessionStart = try #require((Self.object(change.data)["hooks"] as? [String: Any])?["sessionStart"] as? [[String: Any]])
        #expect(sessionStart.compactMap { $0["command"] as? String } == ["\(Self.binary) session-start --agent cursor", "/usr/local/bin/notify.sh"])
        #expect(sessionStart.first?["timeout"] as? Int == 9)
    }

    @Test(arguments: [#"[1,2]"#, #"{"hooks":[]}"#, #"{"hooks":{"preToolUse":{"command":"x"}}}"#])
    func aHooksFileOfAnotherShapeIsRefused(text: String) throws {
        #expect(throws: CursorConfigJSON.Unmergeable.self) { try CursorHooksFile.apply(to: Data(text.utf8), binaryWord: Self.binary) }
        #expect(throws: CursorConfigJSON.Unmergeable.self) { try CursorHooksFile.remove(from: Data(text.utf8)) }
    }

    @Test
    func theServerIsRegisteredByAbsolutePathWithMcpAloneAndRemovedToTheForeignFile() throws {
        let foreign = try Self.canonical(Self.foreignServers)

        let installed = try CursorMcpFile.apply(to: foreign, binary: Self.binary)

        #expect(installed.outcome == .registered)
        let servers = try #require(Self.object(installed.data)["mcpServers"] as? [String: Any])
        let sift = try #require(servers["sift"] as? [String: Any])
        #expect(sift.keys.sorted() == ["args", "command"])
        #expect(sift["command"] as? String == Self.binary)
        #expect(sift["args"] as? [String] == ["mcp"])
        #expect(servers["notes"] != nil)

        let again = try CursorMcpFile.apply(to: installed.data, binary: Self.binary)
        #expect(again.outcome == .unchanged)
        #expect(again.data == installed.data)

        let removed = try CursorMcpFile.remove(from: installed.data)
        #expect(removed.outcome == .removed("\(Self.binary) mcp"))
        #expect(removed.data == foreign)
        #expect(try CursorMcpFile.remove(from: removed.data).outcome == .unchanged)
    }

    @Test(arguments: [
        #"{"mcpServers":{"sift":{"args":["mcp","--root","/work/app"],"command":"/opt/tools/bin/sift"}}}"#,
        #"{"mcpServers":{"sift":{"args":["-y","sift","mcp"],"command":"npx"}}}"#,
        #"{"mcpServers":{"sift":{"args":["mcp"],"command":"/opt/siftscience/sift-agent"}}}"#,
    ])
    func aServerNamedSiftOfAnotherShapeIsReportedAndLeftAlone(text: String) throws {
        let foreign = try Self.canonical(text)

        let installed = try CursorMcpFile.apply(to: foreign, binary: Self.binary)
        let removed = try CursorMcpFile.remove(from: foreign)

        guard case .foreign = installed.outcome else {
            Issue.record("\(installed.outcome)")
            return
        }
        #expect(installed.data == foreign)
        #expect(!installed.changed)
        guard case .foreign = removed.outcome else {
            Issue.record("\(removed.outcome)")
            return
        }
        #expect(removed.data == foreign)
    }

    @Test
    func aMovedServerIsRepointedKeepingWhatElseItsEntryHolds() throws {
        let stale = #"{"mcpServers":{"sift":{"args":["mcp"],"command":"/old/sift","env":{"SIFT_LOG":"1"}}}}"#

        let change = try CursorMcpFile.apply(to: Self.canonical(stale), binary: Self.binary)

        #expect(change.outcome == .replaced(previous: "/old/sift mcp"))
        let sift = try #require((Self.object(change.data)["mcpServers"] as? [String: Any])?["sift"] as? [String: Any])
        #expect(sift["command"] as? String == Self.binary)
        #expect((sift["env"] as? [String: String]) == ["SIFT_LOG": "1"])
    }
}
