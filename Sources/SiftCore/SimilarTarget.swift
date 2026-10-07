//
// Copyright © Agulhas Labs
//

/// Resolving a `similar` target — `Type.member`, a labeled `Type.save(_:to:)`, or `File.swift:12-40` — against the declarations the scan found.
///
/// Reuses the two pieces `digest` resolves its own targets through: `DigestLineRange` reads the line form and `QualifiedPath` reads the dotted one, so an unqualified or container-qualified target names the same member for both tools. A second spelling of either would be a target one tool answers and the other does not recognise, which is the failure `DigestLineRange`'s own note is about. A module-qualified target (`SiftCore.SimilarityScore.jaccard`) is not full parity with `digest`: this scan has no build graph to resolve a real module name against, so it is answered by a heuristic — retrying with the leading qualifier dropped — rather than `digest`'s resolved one.
///
/// What it does not reuse is the lookup. `digest` resolves against stored rows; this answer is a working-tree read with no index in it at all (Docs/Design.md §3), so the candidate set is the scan's own output and resolution never has a freshness axis to refuse on.
struct SimilarTarget {
    static func resolve(_ target: String, among fingerprints: [DeclarationFingerprint]) -> Resolution {
        if let range = DigestLineRange.parse(target) {
            return resolve(range, among: fingerprints)
        }
        return resolve(dotted: target, among: fingerprints)
    }

    /// A dotted target: the last component names the declaration, the rest qualify it.
    ///
    /// A labeled form is matched exactly and an unlabeled one by base name, so `Type.save(_:to:)` picks one overload out and `Type.save` lists them — which is the behaviour a caller who wrote the short form is asking for.
    private static func resolve(dotted target: String, among fingerprints: [DeclarationFingerprint]) -> Resolution {
        let components = QualifiedPath.components(of: target)
        guard let requested = components.last else { return .missing }
        let qualifiers = Array(components.dropLast())
        let base = QualifiedPath.baseName(of: requested)
        let wasLabeled = requested != base
        func answering(to qualifiers: [String]) -> [DeclarationFingerprint] {
            let normalizedQualifiers = qualifiers.map(Self.canonicalTypeSpelling)
            return fingerprints.filter { fingerprint in
                let chain = QualifiedPath.components(of: fingerprint.declaration.qualifiedName)
                guard let ownName = chain.last else { return false }
                guard wasLabeled ? ownName == requested : QualifiedPath.baseName(of: ownName) == base else { return false }
                let normalizedChain = Array(chain.dropLast()).map(Self.canonicalTypeSpelling)
                return QualifiedPath.matches(qualifiers: normalizedQualifiers, chain: normalizedChain, module: "")
            }
        }
        // No module to offer: this scan reads files, and nothing in it resolves a build graph, so `module` is passed empty and the module-qualified branch inside `matches` never fires. A caller who wrote one anyway (`SiftCore.SimilarityScore.jaccard`) is answered by retrying once with that leading qualifier dropped — only when the path as written named nothing, so a full spelling that resolves is never made ambiguous by a shorter one — on the working assumption that it named a module rather than a container.
        let asWritten = answering(to: qualifiers)
        guard asWritten.isEmpty, qualifiers.count > 1 else { return decide(asWritten) }
        return decide(answering(to: Array(qualifiers.dropFirst())))
    }

    /// A line-range target: the declaration whose extent covers the lines asked for.
    ///
    /// Nested declarations are never candidates, so at most one declaration per file can contain a given range and containment is unambiguous within a file. When nothing contains the range — a range pasted across two declarations, or one that starts in the space between them — the declarations it *overlaps* are listed instead of the target being called missing, since a caller holding line numbers is closer to an answer than a caller holding nothing.
    private static func resolve(_ range: DigestLineRange, among fingerprints: [DeclarationFingerprint]) -> Resolution {
        let inFile = fingerprints.filter { covers(path: $0.declaration.path, requested: range.path) }
        let containing = inFile.filter { $0.declaration.line <= range.start && range.end <= $0.declaration.endLine }
        guard containing.isEmpty else { return decide(containing) }
        return decide(inFile.filter { $0.declaration.line <= range.end && range.start <= $0.declaration.endLine })
    }

    /// Whether a repository-relative path answers to what the caller wrote: the path itself, or a suffix of it at a component boundary — `digest`'s own rule for a file target.
    private static func covers(path: String, requested: String) -> Bool {
        path == requested || path.hasSuffix("/" + requested)
    }

    /// A written type's sugar spelling reduced to the generic one it means, so `[T]`, `[K: V]` and `T?` compare equal to `Array<T>`, `Dictionary<K, V>` and `Optional<T>` — an extension's own type name is recorded however its source wrote it, and a caller asking `Array<Int>.member` or `[Int].member` means the same declaration either way.
    private static func canonicalTypeSpelling(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("?") {
            return "Optional<\(canonicalTypeSpelling(String(trimmed.dropLast())))>"
        }
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return trimmed }
        let inner = String(trimmed.dropFirst().dropLast())
        guard let colon = inner.firstIndex(of: ":") else { return "Array<\(canonicalTypeSpelling(inner))>" }
        let key = canonicalTypeSpelling(String(inner[inner.startIndex ..< colon]))
        let value = canonicalTypeSpelling(String(inner[inner.index(after: colon)...]))
        return "Dictionary<\(key), \(value)>"
    }

    private static func decide(_ matched: [DeclarationFingerprint]) -> Resolution {
        switch matched.count {
        case 0: .missing
        case 1: .one(matched[0])
        default: .ambiguous(matched)
        }
    }
}

extension SimilarTarget {
    enum Resolution {
        case one(DeclarationFingerprint)
        /// Several answer to it — listed, the way a digest of an overloaded name lists its labeled candidates, rather than one of them being picked.
        case ambiguous([DeclarationFingerprint])
        case missing
    }
}
