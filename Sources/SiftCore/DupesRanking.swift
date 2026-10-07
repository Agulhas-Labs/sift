//
// Copyright © Agulhas Labs
//

/// What puts one `dupes` group above another: the lines a merge would save, discounted by how far apart the group's weakest pair is, and test and preview code after the rest.
///
/// The audit is read to decide what to fold first, so a group ranks by what folding it is worth rather than by its closest pair alone: on this repository's own tree four hundred groups had a closest pair at 1.00 overlap, so ordering by that number was a tie-break, not a ranking.
struct DupesRanking {
    /// The fewest lines a declaration spans, signature and braces included, and still be paired: a body of one or two lines is cheaper to write again than to share.
    static let sizeFloor = 4

    /// The words a path component ending with marks as test, fixture, preview or generated code.
    static let testOrPreviewSuffixes = ["Test", "Tests", "Mock", "Mocks", "Fixture", "Fixtures", "Stub", "Stubs", "Preview", "Previews", "Generated"]

    /// The words a path component starting with marks the same way; not `Test`, which starts production names (`TestCommand`, `TestSymbol`) as often as test ones.
    static let testOrPreviewPrefixes = ["Mock", "Fixture", "Stub", "Preview", "Generated"]

    /// The fewest control-flow tokens a shared skeleton holds and still mark a copy: two bodies with no branch at all share an empty skeleton for nothing.
    static let shapeFloor = 2

    /// Whether all of a group's members, some two of them, or none share one control-flow skeleton, at least `shapeFloor` tokens long, and one non-empty set of written types.
    ///
    /// Renaming a copy's locals changes the callees a renamed closure or nested function is called by, so its overlap drops; it leaves the control flow and the written types alone, which is what a reimplementation of the same job seldom does.
    static func copies(among members: [DeclarationFingerprint]) -> Copies {
        let shaped = members.filter { $0.skeleton.count >= shapeFloor && !$0.typeNames.isEmpty }
        let shapes = Dictionary(grouping: shaped) { ShapeKey(skeleton: $0.skeleton, typeNames: $0.typeNames) }
        if shapes.count == 1, shaped.count == members.count {
            return .all
        }
        return shapes.values.contains { $0.count > 1 } ? .some : .none
    }

    /// The lines a declaration spans, signature and braces included.
    static func span(of fingerprint: DeclarationFingerprint) -> Int {
        fingerprint.declaration.endLine - fingerprint.declaration.line + 1
    }

    /// The lines folding a group into one body would save: every member's span but the longest one's, which is the copy that stays.
    static func duplicatedLines(of members: [DeclarationFingerprint]) -> Int {
        let spans = members.map(span(of:))
        return spans.reduce(0, +) - (spans.max() ?? 0)
    }

    /// The number groups rank by: the lines a merge would save, times the square of the weakest pair's full score, so a loose group must save far more to outrank a near-exact one.
    static func weight(duplicatedLines: Int, weakestScore: Double) -> Double {
        Double(duplicatedLines) * weakestScore * weakestScore
    }

    /// Whether a declaration is test or preview code: a test function, a SwiftUI `body` or `previews` property, or a file under a path component (a directory, or the file's own name) that ends with one of `testOrPreviewSuffixes`, starts with one of `testOrPreviewPrefixes`, or ends in `.generated`.
    ///
    /// Read from the path and the parse alone, so a test helper in a file named like production code is not recognised; the answer's rule line says what is.
    static func isTestOrPreview(_ fingerprint: DeclarationFingerprint) -> Bool {
        if fingerprint.isTest || isViewProperty(fingerprint.declaration) {
            return true
        }
        return fingerprint.declaration.path.split(separator: "/").contains { component in
            let name = component.hasSuffix(".swift") ? component.dropLast(".swift".count) : component
            return name.lowercased().hasSuffix(".generated")
                || testOrPreviewSuffixes.contains { name.hasSuffix($0) }
                || testOrPreviewPrefixes.contains { name.hasPrefix($0) }
        }
    }

    /// A SwiftUI view's `body` or a preview provider's `previews`, which every view writes the same way.
    private static func isViewProperty(_ declaration: StructuralMatch) -> Bool {
        guard declaration.kind == SymbolKind.variable.rawValue else { return false }
        let name = declaration.qualifiedName.split(separator: ".").last.map(String.init) ?? declaration.qualifiedName
        return (name == "body" || name == "previews") && declaration.signature.contains("some ")
    }
}

extension DupesRanking {
    /// How many of a group's members are copies by shape.
    enum Copies: Sendable, Equatable {
        case all
        case some
        case none
    }

    /// What two copies share: the control flow and the written types.
    private struct ShapeKey: Hashable {
        let skeleton: [DeclarationFingerprint.ControlToken]
        let typeNames: Set<String>
    }
}
