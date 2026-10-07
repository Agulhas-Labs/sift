//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// The server's own `tools/list` answer carries the load-up-front mark exactly when it was started to load its tools up front.
@Suite(.temporaryDirectories)
struct ToolListLoadingTests {
    @Test
    func aServerStartedToDeferItsToolsMarksNone() async throws {
        let tools = try await Self.listedTools(loadToolsUpFront: false)

        #expect(tools.count == 4)
        for tool in tools {
            #expect(tool["_meta"] == nil, "\(tool["name"] ?? "?") is marked")
        }
    }

    @Test
    func aServerStartedToLoadItsToolsUpFrontMarksAllFour() async throws {
        let tools = try await Self.listedTools(loadToolsUpFront: true)

        #expect(tools.count == 4)
        for tool in tools {
            let meta = tool["_meta"] as? [String: Any]
            #expect(meta?[MCPToolCatalog.alwaysLoadKey] as? Bool == true, "\(tool["name"] ?? "?") is not marked")
        }
    }
}

private extension ToolListLoadingTests {
    /// The tools a server built with the given load setting answers `tools/list` with, over real pipes.
    static func listedTools(loadToolsUpFront: Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws -> [[String: Any]] {
        let root = try MCPTestRepo.make()
        let toServer = Pipe()
        let fromServer = Pipe()
        let server = MCPServer(
            input: toServer.fileHandleForReading,
            output: fromServer.fileHandleForWriting,
            defaultRoot: root,
            log: { _ in },
            loadToolsUpFront: loadToolsUpFront
        )
        let task = Task { await server.run() }
        var responses = FileHandleLines.lines(from: fromServer.fileHandleForReading).makeAsyncIterator()

        let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        toServer.fileHandleForWriting.write(request + Data("\n".utf8))
        let line = try #require(await responses.next(), sourceLocation: sourceLocation)
        toServer.fileHandleForWriting.closeFile()
        _ = await task.value

        let response = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], sourceLocation: sourceLocation)
        let result = try #require(response["result"] as? [String: Any], sourceLocation: sourceLocation)
        return try #require(result["tools"] as? [[String: Any]], sourceLocation: sourceLocation)
    }
}
