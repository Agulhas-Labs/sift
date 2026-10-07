//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A purge deletes the record of which repositories the tool ran in, so its answer names what a later run can no longer find, and says `~/.sift` is gone only if it still is.
@Suite(.temporaryDirectories)
struct UninstallPurgeAftermathTests {
    private typealias Fixture = UninstallCommandTests

    /// The second run cannot re-find the `.mcp.json`, so the first one says so while it still can, on the one line that names the file and says what to do.
    @Test
    func aPurgeNamesTheMcpJsonALaterRunWillNotFind() throws {
        let installed = try Fixture.install()
        let file = installed.recorded.appendingPathComponent(".mcp.json")
        try #"{"mcpServers":{"sift":{"command":"sift","args":["mcp"]}}}"#.write(to: file, atomically: true, encoding: .utf8)
        let path = CanonicalPath.of(installed.recorded.path) + "/.mcp.json"

        let lines = try Fixture.uninstall(installed, ["--purge"], remover: Fixture.ServerRemover())

        let named = "mcp: not removed — \(path) registers sift (sift mcp) for everyone who opens that repository; it is the repository's own file, so remove its sift entry by hand: the purge deleted the record naming its repository, so a later `sift uninstall` will not find it"
        #expect(lines.filter { $0.contains(path) } == [named], "\(lines)")
        let sessions = "sessions: any already running keep the hooks and MCP server they started with, and can recreate \(installed.siftHome.path) until they end"
        #expect(lines.contains(sessions), "\(lines)")
    }

    /// Without a purge nothing is deleted, so there is nothing a later run loses and no session can undo.
    @Test
    func withoutAPurgeNeitherLineIsPrinted() throws {
        let installed = try Fixture.install()
        try #"{"mcpServers":{"sift":{"command":"sift","args":["mcp"]}}}"#.write(to: installed.recorded.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)

        let lines = try Fixture.uninstall(installed, remover: Fixture.ServerRemover())

        #expect(!lines.contains { $0.hasPrefix("sessions: ") || $0.contains("will not find it") }, "\(lines)")
    }

    /// A `~/.sift` deleted and there again by the end is not reported purged: it is counted, with what recreated it.
    @Test
    func aHomeThereAgainAfterItsDeleteIsCountedNotPurged() throws {
        let installed = try Fixture.install()
        let locations = SiftUninstall.Locations(settings: installed.settings, claudeConfig: installed.claudeConfig, rule: installed.rule, siftHome: installed.siftHome, logs: [])
        var step = UninstallPurge(purged: [installed.siftHome.path])

        step.settleAftermath(locations, roots: [])

        #expect(step.purged.isEmpty)
        #expect(step.failures == 1)
        #expect(step.notes.first == "not purged: \(installed.siftHome.path) — there again at the end of the uninstall, so something still running recreated it")
    }
}
