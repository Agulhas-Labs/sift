//
// Copyright © Agulhas Labs
//

/// One symbol as stored, joined with its file's identity.
public struct SymbolRow: Sendable {
    public let id: Int64
    public let fileID: Int64
    public let path: String
    public let module: String
    public let parentID: Int64?
    public let kind: SymbolKind
    public let name: String
    public let line: Int
    public let column: Int
    public let endLine: Int
    public let accessLevel: AccessLevel
    public let isStatic: Bool
    public let isStored: Bool
    public let signature: String
    public let docSummary: String?
    public let ifConfigCondition: String?
    /// For a `some View` property, the nesting of view constructions in its body — see `ViewOutline`.
    public let viewOutline: String?
}

public extension SymbolRow {
    /// The bare name for labeled function forms — `save(_:to:)` → `save`.
    var baseName: String {
        guard let parenIndex = name.firstIndex(of: "(") else { return name }
        return String(name[name.startIndex ..< parenIndex])
    }

    /// The source range in `path:start-end` form, the anchor for a ranged Read of the body.
    var rangeDescription: String {
        line == endLine ? ":\(line)" : ":\(line)-\(endLine)"
    }
}

extension SymbolRow {
    /// The row `where` lists this declaration with, under `qualifiedName`: with its signature and doc summary, or only its path when `compact`, and the `#if` condition it sits under after its range, as `digest` places it — `condition` where the caller has labelled it (`IfConfigLabel`), the stored one otherwise.
    func declarationLine(qualifiedName: String, compact: Bool, condition: String? = nil) -> String {
        let located = "\(path)\(rangeDescription)" + ((condition ?? ifConfigCondition).map { "  [\($0)]" } ?? "")
        if compact {
            return "  \(qualifiedName) — \(kind.rawValue) — \(located)"
        }
        let line = "  \(qualifiedName) — \(kind.rawValue) — \(SourceSlicer.cut(signature, at: SourceSlicer.signatureCap)) — \(located)"
        return docSummary.map { line + "  /// " + $0 } ?? line
    }
}
