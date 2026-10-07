//
// Copyright © Agulhas Labs
//

/// The syntactic shape of one declaration that has a body, small enough to outlive the tree it was read from.
///
/// A value type on purpose, and the reason `similar` is allowed to exist at all. Ranking every declaration in a repository against one target means holding the whole tree's shapes at once, and the rule that no syntax tree survives the file it came from (Docs/Design.md §4) is the one this would otherwise break — so the fingerprint is extracted inside the per-file call and the tree is dropped there. Nothing here holds a node, a token or a position.
public struct DeclarationFingerprint: Sendable, Equatable {
    /// Where the declaration is and what it is called — the same locator a `search` hit carries, so a hit here is as directly actionable as one there.
    public let declaration: StructuralMatch
    /// Base names of every call in the subtree, as `BodyFacts` reads them.
    ///
    /// The axis the score is built on, and the only one it is rarity-weighted over.
    public let callees: Set<String>
    /// The control-flow tokens the body opens, in the order a pre-order walk meets them — the skeleton two bodies can share while sharing no name at all.
    public let skeleton: [ControlToken]
    /// Parameter and return type names **as written**: `URL`, `Data`, `Encodable`.
    ///
    /// A type alias and the type it aliases are two names here, because that is all a parse can see.
    public let typeNames: Set<String>
    /// Whether the declaration is a test function: one carrying `@Test`, or a `test`-prefixed instance method of a type whose inheritance clause names `XCTestCase`.
    ///
    /// Read from the parse alone, so a class reaching `XCTestCase` through a base class of its own is not recognised.
    public let isTest: Bool

    public init(
        declaration: StructuralMatch,
        callees: Set<String>,
        skeleton: [ControlToken],
        typeNames: Set<String>,
        isTest: Bool = false
    ) {
        self.declaration = declaration
        self.callees = callees
        self.skeleton = skeleton
        self.typeNames = typeNames
        self.isTest = isTest
    }

    /// Whether two fingerprints name the same declaration — the test that keeps a target out of its own results.
    ///
    /// Path and line, not the qualified name: two overloads share a name, and an extension in another file can declare a member of the same type under the same one.
    public func isSameDeclaration(as other: DeclarationFingerprint) -> Bool {
        declaration.path == other.declaration.path && declaration.line == other.declaration.line
    }
}

public extension DeclarationFingerprint {
    /// One control-flow construct, reduced to the word a reader would say.
    ///
    /// Written forms only, and deliberately coarse: `if` and `guard` stay apart because inverting one into the other is a real difference in shape, while a `for`-`in` over a sequence and one over a range are the same token. The sequence of these — not the set — is what `similar` compares, since two bodies that guard-then-throw twice are alike in a way two bodies holding one `guard` and one `throw` in either order are not.
    enum ControlToken: String, Sendable, CaseIterable {
        case ifToken = "if"
        case guardToken = "guard"
        case forToken = "for"
        case whileToken = "while"
        case repeatToken = "repeat"
        case switchToken = "switch"
        case doToken = "do"
        case catchToken = "catch"
        case deferToken = "defer"
        case returnToken = "return"
        case throwToken = "throw"
    }
}
