//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Whether an agent's files hold nothing of sift's: each is absent, or readable, parseable and free of anything that could be sift's.
struct DoctorTraces {
    /// Whether a hooks file's bytes hold no command that names sift; `nil` is a file that is not there, and bytes that are not a JSON object are something.
    static func hooksHoldNothing(_ data: Data?) -> Bool {
        guard let data else { return true }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return !mentionsSift(object["hooks"] as Any)
    }

    /// Whether the MCP file at `url` registers no server named sift and none that is this tool's; a file that cannot be read or parsed is something.
    static func serversHoldNothing(in url: URL) -> Bool {
        let data: Data?
        do {
            data = try CursorInstall.read(url)
        } catch {
            return false
        }
        guard let data else { return true }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let servers = object["mcpServers"] else { return true }
        guard let table = servers as? [String: Any] else { return false }
        return table[CursorMcpFile.serverName] == nil && !table.values.contains { CursorMcpFile.isOurs($0) }
    }

    /// Whether any `command` string beneath `value` names sift.
    private static func mentionsSift(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            return dictionary.contains { key, inner in
                if key == "command", let command = inner as? String {
                    return SiftPaths.mentionsThisTool(command)
                }
                return mentionsSift(inner)
            }
        }
        if let array = value as? [Any] {
            return array.contains { mentionsSift($0) }
        }
        return false
    }
}
