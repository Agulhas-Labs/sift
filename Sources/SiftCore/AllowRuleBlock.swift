//
// Copyright © Agulhas Labs
//

import Foundation

/// The mechanics every set of allow rules `install-hook` offers shares: appended as one contiguous block, taken back out as the last such block.
///
/// Each set is its own block rather than one longer list, so an install over a settings file that already holds the older set adds only the new one, and an uninstall takes each set out whole whichever version wrote it.
struct AllowRuleBlock {
    /// The rules, in the order an install appends them.
    let rules: [String]

    func missing(from data: Data?) throws -> [String] {
        let present = try Self.allowList(in: Self.parse(data))
        return rules.filter { rule in !present.contains { $0 as? String == rule } }
    }

    func adding(to data: Data?) throws -> Data? {
        var settings = try Self.parse(data)
        var permissions = try Self.object(settings["permissions"])
        var allow = try Self.allowList(in: settings)
        guard try !missing(from: data).isEmpty else { return nil }
        allow.append(contentsOf: rules)
        permissions["allow"] = allow
        settings["permissions"] = permissions
        return try Self.encoded(settings)
    }

    func removing(from data: Data?) throws -> Data? {
        var settings = try Self.parse(data)
        var permissions = try Self.object(settings["permissions"])
        var allow = try Self.allowList(in: settings)
        guard let start = allow.indices.reversed().first(where: { isBlock(in: allow, at: $0) }) else { return nil }
        allow.removeSubrange(start ..< start + rules.count)
        if allow.isEmpty {
            permissions.removeValue(forKey: "allow")
        } else {
            permissions["allow"] = allow
        }
        if permissions.isEmpty {
            settings.removeValue(forKey: "permissions")
        } else {
            settings["permissions"] = permissions
        }
        return try Self.encoded(settings)
    }

    /// Whether `list` holds the whole set, in order, starting at `index`.
    private func isBlock(in list: [Any], at index: Int) -> Bool {
        guard index + rules.count <= list.count else { return false }
        return rules.indices.allSatisfy { list[index + $0] as? String == rules[$0] }
    }

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookRegistrationError.settingsNotAnObject
        }
        return object
    }

    /// The `permissions` object, empty where it is absent, refused where it is something else.
    private static func object(_ value: Any?) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let object = value as? [String: Any] else {
            throw HookRegistrationError.permissionsNotMergeable(key: "permissions")
        }
        return object
    }

    /// The `permissions.allow` list walked as `[Any]`, so an element of another shape is carried through rather than dropping the list.
    private static func allowList(in settings: [String: Any]) throws -> [Any] {
        guard let value = try object(settings["permissions"])["allow"] else { return [] }
        guard let list = value as? [Any] else {
            throw HookRegistrationError.permissionsNotMergeable(key: "allow")
        }
        return list
    }

    private static func encoded(_ settings: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
