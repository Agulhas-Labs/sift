//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// The basename pointer of an answer read at a revision is spelled for the face that asked: a tool call over MCP, the command line's arguments on the CLI.
@Suite(.serialized, .temporaryDirectories)
struct AtPointerSpellingTests {
    static var path: String {
        "Sources/App/Extensions.swift"
    }

    static var toolCall: String {
        #"digest target:"Sources/App/Extensions.swift" at:"HEAD""#
    }

    static func makeRepo() throws -> URL {
        try MCPTestRepo.make(declaring: "Widget", extending: "Int")
    }

    @Test func theToolCallSpellingNamesTheRevisionAsAnArgument() {
        #expect(CallSpelling.toolCall.digest(Self.path, at: "HEAD~1") == #"digest target:"Sources/App/Extensions.swift" at:"HEAD~1""#)
        #expect(CallSpelling.commandLine.digest(Self.path, at: "HEAD~1") == "digest Sources/App/Extensions.swift --at HEAD~1")
    }

    @Test func anMCPDigestMissAtARevisionNamesTheFileAsAToolCall() throws {
        let root = try Self.makeRepo()
        let answer = try SiftEngine(directory: root).digest(targets: ["Extensions"], at: "HEAD", options: DigestOptions(spelling: .toolCall))

        #expect(answer.contains(Self.toolCall), "\(answer)")
        #expect(!answer.contains(" --at "), "\(answer)")
    }

    @Test func anMCPWhereMissAtARevisionNamesTheFileAsAToolCall() async throws {
        let root = try Self.makeRepo()
        let answer = try await SiftEngine(directory: root).lookup(symbol: "Extensions", at: "HEAD", options: WhereOptions(spelling: .toolCall))

        #expect(answer.contains(Self.toolCall), "\(answer)")
        #expect(!answer.contains(" --at "), "\(answer)")
    }

    @Test func theCommandLineAnswersKeepTheirSpelling() async throws {
        let root = try Self.makeRepo()
        let engine = try SiftEngine(directory: root)
        let line = "digest Sources/App/Extensions.swift --at HEAD"

        #expect(try engine.digest(targets: ["Extensions"], at: "HEAD", options: DigestOptions()).contains(line))
        #expect(try await engine.lookup(symbol: "Extensions", at: "HEAD").contains(line))
    }

    @Test func aMissedTargetHoldingTheRevisionIsToldToPassItAsAnArgument() {
        let note = MCPServer.spacedTargetNote(arguments: ["target": "Sources/App/Extensions.swift --at HEAD~1"], missed: true)

        #expect(note == #"read target: as one path — pass the revision as at:"HEAD~1", not in target:"#)
    }

    /// A path with ` --at ` inside it is one path wrongly spelled, not the flag pasted in, so it gets the one-path note.
    @Test func aPathHoldingTheFlagWordIsReadAsOnePath() {
        let inside = MCPServer.spacedTargetNote(arguments: ["target": "Sources/my --at dir/File.swift"], missed: true)
        let early = MCPServer.spacedTargetNote(arguments: ["target": "Sources/my --at dir/File HEAD"], missed: true)
        let bare = MCPServer.spacedTargetNote(arguments: ["target": "Sources/App/Extensions.swift --at"], missed: true)

        #expect(inside?.contains("pass the revision") == false)
        #expect(early?.contains("pass the revision") == false)
        #expect(bare == #"read target: as one path — pass the revision as at:"<rev>", not in target:"#)
    }
}
