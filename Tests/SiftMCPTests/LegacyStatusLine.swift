//
// Copyright © Agulhas Labs
//

import Foundation

/// The status line an older install wrote into a settings file, as a fixture: sift no longer registers one, but an install or uninstall still finds it there.
struct LegacyStatusLine {
    /// `settings` with a `statusLine` slot running `command`, merged as JSON so a command holding quotes is carried exactly.
    static func adding(command: String, to settings: Data?) throws -> Data {
        var object: [String: Any] = [:]
        if let settings, !settings.isEmpty {
            object = try JSONSerialization.jsonObject(with: settings) as? [String: Any] ?? [:]
        }
        object["statusLine"] = ["type": "command", "command": command]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
