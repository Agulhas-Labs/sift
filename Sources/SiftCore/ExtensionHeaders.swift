//
// Copyright © Agulhas Labs
//

/// The headers of the extensions written through a type's name that ``ExtensionPlacement`` places as another type's than the one asked, and the clause a usage verdict says of them.
struct ExtensionHeaders {
    let store: IndexStore

    /// Per file and line, the header of each extension written bare through `name` that ``ExtensionPlacement`` places as another type's than the one `asked` declares, with what to call that type; none where `asked` is not one type at one path in one module.
    ///
    /// A qualified header is left to the qualifier's own caveat. The header is the first site in the extension, since its body follows it.
    func extendingAnother(named name: String, asked: [SymbolRow], sites: [SyntacticCallSite]) throws -> [String: [Int: String]] {
        guard asked.allSatisfy(\.kind.isTypeDeclaration) else { return [:] }
        let placements = try asked.map { try ExtensionPlacement(of: $0, in: store) }
        guard let placement = placements.first, placements.allSatisfy({ $0.module == placement.module && $0.path == placement.path }) else { return [:] }
        var headers: [String: [Int: String]] = [:]
        for written in try ExtensionPaths.written(endingIn: name, in: store) where !written.path.contains(".") {
            guard try placement.place(written) == .another else { continue }
            let extended = written.row
            let span = extended.line ... max(extended.line, extended.endLine)
            guard let header = sites.filter({ $0.path == extended.path && span.contains($0.line) }).map(\.line).min() else { continue }
            headers[extended.path, default: [:]][header] = extended.module == placement.module ? "another \(name)" : "another module's \(name)"
        }
        return headers
    }

    /// Per file, the lines of the header of each extension written through a qualifier that ``ExtensionPlacement`` places as another type's than the one `asked` declares.
    ///
    /// `extension Shelf.Box` beside the tree's `Alpha.Box`, where `Shelf` is another module's name. Such a header is no use of `asked`, so it is neither counted nor listed; none where `asked` is not one type at one path in one module. Each header line maps to the qualifier it is written through, so only that spelling is left out: an unqualified use on the same line, as in `extension Holder.Item { func convert() -> Item { Item() } }`, still counts.
    func qualifiedAsAnother(named name: String, asked: [SymbolRow], sites: [SyntacticCallSite]) throws -> [String: [Int: String]] {
        guard asked.allSatisfy(\.kind.isTypeDeclaration) else { return [:] }
        let placements = try asked.map { try ExtensionPlacement(of: $0, in: store) }
        guard let placement = placements.first, placements.allSatisfy({ $0.module == placement.module && $0.path == placement.path }) else { return [:] }
        var headers: [String: [Int: String]] = [:]
        for written in try ExtensionPaths.written(endingIn: name, in: store) where written.path.contains(".") {
            guard try placement.place(written) == .another else { continue }
            let extended = written.row
            let span = extended.line ... max(extended.line, extended.endLine)
            let qualifier = String(written.path.dropLast(name.count + 1))
            guard let header = sites.filter({ $0.path == extended.path && span.contains($0.line) && $0.qualifier == qualifier }).map(\.line).min() else { continue }
            headers[extended.path, default: [:]][header] = qualifier
        }
        return headers
    }

    /// The verdict's clause for the lines of `used` that are the header of a bare extension placed as another type's, or `nil` where there are none.
    static func placedClause(named name: String, kind: String, used: [String: Set<Int>], headers: [String: [Int: String]]) -> String? {
        let count = headers.reduce(0) { total, file in total + file.value.keys.count { used[file.key]?.contains($0) == true } }
        guard count > 0 else { return nil }
        let writes = count == 1 ? "writes" : "write"
        let extends = count == 1 ? "extends" : "extend"
        return "\(count) of them \(writes) \"\(name)\" as the header of an extension the index places as another type's, so \(extends) that type rather than this \(kind) — counted all the same, as a placement read from the index alone is not proof"
    }
}
