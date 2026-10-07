//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftCore
@testable import SiftMCP
import Testing

/// A recorded repository's `.mcp.json` that is there and cannot be read is named as not checked, never passed over as naming no server.
@Suite(.temporaryDirectories)
struct UninstallUnreadableMcpJsonTests {
    private typealias Fixture = UninstallCommandTests

    @Test
    func aMcpJsonThatIsNotJsonIsNamedNotCheckedAndLeftUntouched() throws {
        let installed = try Fixture.install()
        defer { try? FileManager.default.removeItem(at: installed.home) }
        let file = installed.recorded.appendingPathComponent(".mcp.json")
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)

        let (lines, status) = try Fixture.exiting(installed, remover: Fixture.ServerRemover())

        #expect(status == 1, "\(lines)")
        #expect(lines.contains { $0.hasPrefix("mcp: not checked — ") && $0.contains("\(file.path) could not be read") }, "\(lines)")
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ not json")
    }

    @Test
    func aMcpJsonThatCannotBeReadIsNamedNotChecked() throws {
        let installed = try Fixture.install()
        let file = installed.recorded.appendingPathComponent(".mcp.json")
        try #"{"mcpServers":{}}"#.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: installed.home)
        }

        let (lines, status) = try Fixture.exiting(installed, remover: Fixture.ServerRemover())

        #expect(status == 1, "\(lines)")
        #expect(lines.contains { $0.hasPrefix("mcp: not checked — ") && $0.contains("\(file.path) could not be read") }, "\(lines)")
    }

    @Test
    func aMissingMcpJsonStaysSilent() throws {
        let installed = try Fixture.install()
        defer { try? FileManager.default.removeItem(at: installed.home) }

        let (lines, status) = try Fixture.exiting(installed, remover: Fixture.ServerRemover())

        #expect(status == 0, "\(lines)")
        #expect(!lines.contains { $0.contains(".mcp.json") }, "\(lines)")
    }
}
