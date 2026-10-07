//
// Copyright © Agulhas Labs
//

import Foundation

/// Reading and writing Cursor's two user-level JSON files, `mcp.json` and `hooks.json`, for a merge that must never replace what it cannot read.
///
/// Absent means "start from empty"; present but the wrong shape is refused, because whatever is there is someone's configuration and a merge that treated it as nothing would write over it.
public struct CursorConfigJSON {
    /// The file's top-level object, or an empty one for no file or an empty file.
    static func parse(_ data: Data?, file: String, harness: String = "Cursor") throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Unmergeable(file: file, key: nil, harness: harness)
        }
        guard let object = value as? [String: Any] else {
            throw Unmergeable(file: file, key: nil, harness: harness)
        }
        return object
    }

    /// The object at `key`, empty when absent, refused when present and not an object.
    static func object(_ value: Any?, key: String, file: String, harness: String = "Cursor") throws -> [String: Any] {
        guard let value else { return [:] }
        guard let object = value as? [String: Any] else {
            throw Unmergeable(file: file, key: key, harness: harness)
        }
        return object
    }

    /// The array at `key`, empty when absent, refused when present and not an array.
    static func array(_ value: Any?, key: String, file: String, harness: String = "Cursor") throws -> [Any] {
        guard let value else { return [] }
        guard let array = value as? [Any] else {
            throw Unmergeable(file: file, key: key, harness: harness)
        }
        return array
    }

    /// `object` as the file is written: pretty-printed with sorted keys, so a re-run compares byte for byte.
    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

public extension CursorConfigJSON {
    /// A Cursor file, or a container in it, that is not the shape this tool writes into, so merging would mean replacing it.
    struct Unmergeable: Error, Equatable, CustomStringConvertible, Sendable {
        /// The file's name, `mcp.json` or `hooks.json`.
        public let file: String
        /// The container that is the wrong shape, or `nil` when the file itself is not a JSON object.
        public let key: String?
        /// The harness whose configuration the file is, as a refusal names it.
        public var harness = "Cursor"

        public var description: String {
            let what = key.map { "\(file)'s \"\($0)\" is not the shape \(harness)'s configuration takes" } ?? "\(file) is not a JSON object"
            return "\(what) — refusing to rewrite it, because merging would mean replacing what is there. Fix or move the file, then re-run."
        }
    }
}
