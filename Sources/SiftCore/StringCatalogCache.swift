//
// Copyright © Agulhas Labs
//

import Foundation

/// Caches each string catalog's parsed content, so a long-lived engine does not re-read and re-parse the same catalog file on every `strings` call.
///
/// The MCP server keeps one engine per root open across a session, so this is what turns a session's repeated `strings` calls into one parse instead of one per call. Kept fresh on the same terms a Swift file is (`SiftEngine.reparseNeed(of:)`): identity is the file's path, and a cached parse is served only while the file's size and mtime still match what was parsed. A changed size invalidates it outright; an edit that leaves the size the same still invalidates it the moment mtime moves, which a save always does. A file that no longer exists, or a catalog that fails to parse, is never cached — the caller reads that exactly as a fresh, uncached read would.
final class StringCatalogCache: @unchecked Sendable {
    private let mutex = NSLock()
    private var entries: [String: Entry] = [:]

    /// The catalog at `url`, parsed fresh or served from cache — `nil` when the file cannot be read or parsed, exactly as a fresh, uncached read would answer.
    func content(at url: URL, isXcstrings: Bool) -> CatalogContent? {
        let path = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64,
              let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
        else {
            invalidate(path)
            return nil
        }
        if let cached = cached(path, size: size, mtime: modified) {
            return cached
        }
        guard let parsed = Self.parse(url: url, isXcstrings: isXcstrings) else {
            invalidate(path)
            return nil
        }
        store(path, size: size, mtime: modified, content: parsed)
        return parsed
    }

    private func cached(_ path: String, size: Int64, mtime: Double) -> CatalogContent? {
        mutex.lock()
        defer { mutex.unlock() }
        guard let entry = entries[path], entry.size == size, entry.mtime == mtime else { return nil }
        return entry.content
    }

    private func store(_ path: String, size: Int64, mtime: Double, content: CatalogContent) {
        mutex.lock()
        entries[path] = Entry(size: size, mtime: mtime, content: content)
        mutex.unlock()
    }

    private func invalidate(_ path: String) {
        mutex.lock()
        entries[path] = nil
        mutex.unlock()
    }

    private static func parse(url: URL, isXcstrings: Bool) -> CatalogContent? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if isXcstrings {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let strings = object["strings"] as? [String: Any]
            else {
                return nil
            }
            let sourceLanguage = object["sourceLanguage"] as? String ?? "en"
            return .modern(sourceLanguage: sourceLanguage, strings: strings)
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let table = plist as? [String: String]
        else {
            return nil
        }
        return .legacy(table)
    }
}

private extension StringCatalogCache {
    struct Entry {
        let size: Int64
        let mtime: Double
        let content: CatalogContent
    }
}
