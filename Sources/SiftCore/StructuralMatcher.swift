//
// Copyright © Agulhas Labs
//

import SwiftParser
import SwiftSyntax

/// Walks one syntax tree and emits the declarations satisfying a `StructuralQuery`.
///
/// Follows the same rule as `SymbolVisitor`: the tree is walked once, and nothing but value records leaves — no node outlives the file (Docs/Design.md §2).
///
/// Unlike the indexing visitor this one *does* descend into bodies, because body shape is the whole question. The cost is paid only when the query asks for it: a query of purely declaration-level terms (`kind:`, `attr:`, `name:`, `modifier:`) never runs a body scan, and a body scan runs only for declarations whose declaration-level terms already passed.
final class StructuralMatcher: SyntaxVisitor {
    /// The `kind:` values this matcher can walk: every `SymbolKind` with a `visit` override above, in declaration order, plus the syntactic-only `deinit`.
    ///
    /// `StructuralQuery` validates a parsed `kind:` term against this list, so a kind added to `SymbolKind` without a matching visitor here refuses instead of silently answering empty.
    static let supportedKinds: [String] = [
        SymbolKind.structKind, .classKind, .actor, .enumKind, .protocolKind, .extensionKind,
        .function, .initializer, .subscriptKind, .variable, .enumCase,
        .typealiasKind, .associatedType, .operatorKind, .precedenceGroup, .macro,
    ].map(\.rawValue) + ["deinit"]

    private let query: StructuralQuery
    /// The query's terms in the order they are applied, held once rather than rebuilt for every declaration.
    private let appliedTerms: [StructuralQuery.Term]
    private let path: String
    private let converter: SourceLocationConverter
    private let sourceBytes: [UInt8]
    private var nameStack: [String] = []
    private(set) var matches: [StructuralMatch] = []
    /// For each position in the applied order, how many declarations that term was the first to reject — what a miss reads to name the term that emptied it.
    private(set) var eliminations: [Int: Int] = [:]

    init(query: StructuralQuery, path: String, converter: SourceLocationConverter, sourceBytes: [UInt8]) {
        self.query = query
        appliedTerms = query.appliedOrder
        self.path = path
        self.converter = converter
        self.sourceBytes = sourceBytes
        super.init(viewMode: .sourceAccurate)
    }

    /// Parses `source` and returns its matches; the tree is local to this call.
    static func matches(in source: String, path: String, query: StructuralQuery) -> [StructuralMatch] {
        scan(source, path: path, query: query).matches
    }

    /// Parses `source` and returns its matches, with how many declarations each applied term was the first to reject; the tree is local to this call.
    static func scan(_ source: String, path: String, query: StructuralQuery) -> (matches: [StructuralMatch], eliminations: [Int: Int]) {
        let tree = Parser.parse(source: source)
        // Imports gate the whole file, mirroring `path:` — a failing file contributes no declarations. Checked after parsing because only the tree knows them, but before the walk, which the gate then saves entirely.
        if query.hasImportTerms, !query.admitsImports(Self.importedModules(in: tree)) {
            return ([], [:])
        }
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let matcher = StructuralMatcher(query: query, path: path, converter: converter, sourceBytes: Array(source.utf8))
        matcher.walk(tree)
        return (matcher.matches, matcher.eliminations)
    }

    /// The module names a file imports: each import's first path component plus the full dotted path when they differ, from top-level statements and — both branches, same honesty rule as the indexer — inside `#if` blocks.
    static func importedModules(in tree: SourceFileSyntax) -> Set<String> {
        var names: Set<String> = []
        collectImports(in: tree.statements, into: &names)
        return names
    }

    private static func collectImports(in statements: CodeBlockItemListSyntax, into names: inout Set<String>) {
        for statement in statements {
            if let importDecl = statement.item.as(ImportDeclSyntax.self) {
                let components = importDecl.path.map(\.name.text)
                if let first = components.first {
                    names.insert(first)
                }
                if components.count > 1 {
                    names.insert(components.joined(separator: "."))
                }
            }
            if let ifConfig = statement.item.as(IfConfigDeclSyntax.self) {
                for clause in ifConfig.clauses {
                    if let elements = clause.elements?.as(CodeBlockItemListSyntax.self) {
                        collectImports(in: elements, into: &names)
                    }
                }
            }
        }
    }

    // MARK: Containers

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node, Candidate(kind: .structKind, name: SymbolNaming.name(of: node.name), headEnd: node.memberBlock.position, modifiers: node.modifiers, attributes: node.attributes, inheritance: node.inheritanceClause))
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node, Candidate(kind: .classKind, name: SymbolNaming.name(of: node.name), headEnd: node.memberBlock.position, modifiers: node.modifiers, attributes: node.attributes, inheritance: node.inheritanceClause))
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node, Candidate(kind: .actor, name: SymbolNaming.name(of: node.name), headEnd: node.memberBlock.position, modifiers: node.modifiers, attributes: node.attributes, inheritance: node.inheritanceClause))
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node, Candidate(kind: .enumKind, name: SymbolNaming.name(of: node.name), headEnd: node.memberBlock.position, modifiers: node.modifiers, attributes: node.attributes, inheritance: node.inheritanceClause))
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node, Candidate(kind: .protocolKind, name: SymbolNaming.name(of: node.name), headEnd: node.memberBlock.position, modifiers: node.modifiers, attributes: node.attributes, inheritance: node.inheritanceClause))
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node, Candidate(kind: .extensionKind, name: SymbolNaming.unbackticked(node.extendedType.trimmedDescription), headEnd: node.memberBlock.position, modifiers: node.modifiers, attributes: node.attributes, inheritance: node.inheritanceClause))
    }

    override func visitPost(_: StructDeclSyntax) {
        nameStack.removeLast()
    }

    override func visitPost(_: ClassDeclSyntax) {
        nameStack.removeLast()
    }

    override func visitPost(_: ActorDeclSyntax) {
        nameStack.removeLast()
    }

    override func visitPost(_: EnumDeclSyntax) {
        nameStack.removeLast()
    }

    override func visitPost(_: ProtocolDeclSyntax) {
        nameStack.removeLast()
    }

    override func visitPost(_: ExtensionDeclSyntax) {
        nameStack.removeLast()
    }

    // MARK: Leaf declarations

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let headEnd = node.genericWhereClause?.endPosition ?? node.signature.endPosition
        consider(node, Candidate(
            kind: .function,
            name: SymbolNaming.labeledName(base: SymbolNaming.name(of: node.name), parameters: node.signature.parameterClause.parameters),
            headEnd: headEnd,
            modifiers: node.modifiers,
            attributes: node.attributes,
            effects: Effects(signature: node.signature)
        ))
        // Nested declarations inside a function body are not API and are never matched, mirroring the indexing visitor.
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let headEnd = node.genericWhereClause?.endPosition ?? node.signature.endPosition
        consider(node, Candidate(
            kind: .initializer,
            name: SymbolNaming.labeledName(base: "init", parameters: node.signature.parameterClause.parameters),
            headEnd: headEnd,
            modifiers: node.modifiers,
            attributes: node.attributes,
            effects: Effects(signature: node.signature)
        ))
        return .skipChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        consider(node, Candidate(
            kind: .subscriptKind,
            name: SymbolNaming.subscriptName(parameters: node.parameterClause.parameters),
            headEnd: node.returnClause.endPosition,
            modifiers: node.modifiers,
            attributes: node.attributes
        ))
        return .skipChildren
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        consider(node, Candidate(deinitializer: true, name: "deinit", headEnd: node.deinitKeyword.endPosition, modifiers: node.modifiers, attributes: node.attributes))
        return .skipChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let first = node.bindings.first else { return .skipChildren }
        let name = SymbolNaming.unbackticked(first.pattern.trimmedDescription)
        consider(node, Candidate(kind: .variable, name: name, headEnd: first.typeAnnotation?.endPosition ?? first.pattern.endPosition, modifiers: node.modifiers, attributes: node.attributes))
        return .skipChildren
    }

    /// Each name in `case a, b` is a declaration of its own, as the index holds it: its own name, signature and associated values, at the line the `case` is written on.
    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        for element in node.elements {
            var candidate = Candidate(kind: .enumCase, name: SymbolNaming.enumCaseName(of: element), headEnd: node.endPosition, modifiers: node.modifiers, attributes: node.attributes)
            candidate.signature = SymbolNaming.enumCaseSignature(of: element)
            candidate.scope = Syntax(element)
            consider(node, candidate)
        }
        return .skipChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        consider(node, Candidate(kind: .typealiasKind, name: SymbolNaming.name(of: node.name), headEnd: node.endPosition, modifiers: node.modifiers, attributes: node.attributes))
        return .skipChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        consider(node, Candidate(kind: .associatedType, name: SymbolNaming.name(of: node.name), headEnd: node.endPosition, modifiers: node.modifiers, attributes: node.attributes))
        return .skipChildren
    }

    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        consider(node, Candidate(kind: .macro, name: SymbolNaming.name(of: node.name), headEnd: node.endPosition, modifiers: node.modifiers, attributes: node.attributes))
        return .skipChildren
    }

    override func visit(_ node: OperatorDeclSyntax) -> SyntaxVisitorContinueKind {
        consider(node, Candidate(kind: .operatorKind, name: SymbolNaming.name(of: node.name), headEnd: node.endPosition, modifiers: DeclModifierListSyntax([]), attributes: AttributeListSyntax([])))
        return .skipChildren
    }

    override func visit(_ node: PrecedenceGroupDeclSyntax) -> SyntaxVisitorContinueKind {
        consider(node, Candidate(kind: .precedenceGroup, name: SymbolNaming.name(of: node.name), headEnd: node.endPosition, modifiers: DeclModifierListSyntax([]), attributes: node.attributes))
        return .skipChildren
    }
}

// MARK: - Matching

private extension StructuralMatcher {
    /// A container: record it if it matches, then descend regardless — a non-matching type still holds matching members.
    func enter(_ node: some SyntaxProtocol, _ candidate: Candidate) -> SyntaxVisitorContinueKind {
        consider(node, candidate)
        nameStack.append(candidate.name)
        return .visitChildren
    }

    func consider(_ node: some SyntaxProtocol, _ candidate: Candidate) {
        let kindName = candidate.kind
        let name = candidate.name
        // A `sig:` term needs the slice before matching; without one it is computed only for matches, as before.
        let signature = candidate.signature.map { SourceSlicer.cut($0, at: SourceSlicer.signatureCap) } ?? (query.needsSignature
            ? SourceSlicer.collapsedSlice(of: sourceBytes, from: node.positionAfterSkippingLeadingTrivia, to: candidate.headEnd)
            : nil)
        let facts = DeclarationFacts(
            kind: kindName,
            name: name,
            attributes: Self.attributeNames(candidate.attributes),
            modifiers: Set(candidate.modifiers.map(\.name.text)),
            inherited: Self.inheritedNames(candidate.inheritance),
            effects: candidate.effects,
            signature: signature
        )
        if let rejecting = firstRejectingDeclarationTerm(facts) {
            eliminations[rejecting, default: 0] += 1
            return
        }
        // The subtree walk is the expensive half, so it runs only once every cheap term has already passed.
        if query.needsBodyScan, let rejecting = firstRejectingBodyTerm(BodyFacts(node: candidate.scope ?? Syntax(node))) {
            eliminations[rejecting, default: 0] += 1
            return
        }
        let start = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        let end = converter.location(for: node.endPosition)
        matches.append(StructuralMatch(
            path: path,
            line: start.line,
            endLine: end.line,
            kind: kindName,
            qualifiedName: (nameStack + [name]).joined(separator: "."),
            signature: signature ?? SourceSlicer.collapsedSlice(of: sourceBytes, from: node.positionAfterSkippingLeadingTrivia, to: candidate.headEnd)
        ))
    }

    /// The applied-order position of the first declaration term `facts` fails, or `nil` when every one passes.
    func firstRejectingDeclarationTerm(_ facts: DeclarationFacts) -> Int? {
        for (position, term) in appliedTerms.enumerated() where !term.field.isBodyScoped {
            let matched: Bool = switch term.field {
            case .kind: term.anyAlternative { facts.kind == $0 }
            case .attr: term.anyAlternative(facts.attributes.contains)
            case .name: term.namePattern?.matches(facts.name) ?? false
            case .inherits: term.anyAlternative { wanted in facts.inherited.contains { $0 == wanted || $0.hasPrefix(wanted + "<") } }
            case .modifier: term.anyAlternative(facts.modifiers.contains)
            case .effect: term.anyAlternative(facts.effects.contains)
            case .sig: term.textMatches(facts.signature ?? "")
            case .owner: term.anyAlternative { Self.isOwned(by: $0, within: nameStack) }
            // Path and import terms already gated the file; re-checking here would double-negate a negated term.
            case .imports, .path: !term.negated
            case .calls, .uses, .has: true
            }
            guard term.accepts(matched) else { return position }
        }
        return nil
    }

    /// The applied-order position of the first body term `body` fails, or `nil` when every one passes.
    func firstRejectingBodyTerm(_ body: BodyFacts) -> Int? {
        for (position, term) in appliedTerms.enumerated() where term.field.isBodyScoped {
            let matched: Bool = switch term.field {
            case .calls: term.anyAlternative(body.calledNames.contains)
            case .uses: term.anyAlternative(body.usedNames.contains)
            case .has: term.anyAlternative { StructuralQuery.Shape(rawValue: $0).map(body.shapes.contains) ?? false }
            default: true
            }
            guard term.accepts(matched) else { return position }
        }
        return nil
    }

    /// Whether `value` names the innermost type or extension around a declaration — its name or its qualified path, generic arguments dropped on both sides; a top-level declaration has no owner.
    static func isOwned(by value: String, within stack: [String]) -> Bool {
        guard !stack.isEmpty else { return false }
        let owner = droppingGenericArguments(stack.joined(separator: "."))
        let wanted = droppingGenericArguments(value)
        return owner == wanted || owner.hasSuffix("." + wanted)
    }

    /// `name` with every `<…>` span removed, nesting included: `Box<Int>.Item` reads as `Box.Item`.
    static func droppingGenericArguments(_ name: String) -> String {
        var depth = 0
        return name.filter { character in
            switch character {
            case "<":
                depth += 1
                return false
            case ">":
                depth = max(0, depth - 1)
                return false
            default:
                return depth == 0
            }
        }
    }

    static func attributeNames(_ attributes: AttributeListSyntax) -> Set<String> {
        var names: Set<String> = []
        for element in attributes {
            guard case let .attribute(attribute) = element else { continue }
            names.insert(attribute.attributeName.trimmedDescription)
        }
        return names
    }

    static func inheritedNames(_ clause: InheritanceClauseSyntax?) -> [String] {
        guard let clause else { return [] }
        return clause.inheritedTypes.map { entry in
            entry.type.trimmedDescription
                .split(separator: " ")
                .filter { !$0.hasPrefix("@") }
                .joined(separator: " ")
        }
    }
}

// MARK: - Fact values

extension StructuralMatcher {
    /// One declaration offered to the query, bundled so `consider` stays within the parameter budget (the same reason `SymbolVisitor.RecordDetails` exists).
    struct Candidate {
        let kind: String
        let name: String
        let headEnd: AbsolutePosition
        let modifiers: DeclModifierListSyntax
        let attributes: AttributeListSyntax
        var inheritance: InheritanceClauseSyntax?
        var effects = Effects()
        /// The signature when it is not the slice from the node to `headEnd`: one name of a `case a, b`.
        var signature: String?
        /// The subtree a body term walks when it is not the whole node: one name of a `case a, b`.
        var scope: Syntax?

        init(kind: SymbolKind, name: String, headEnd: AbsolutePosition, modifiers: DeclModifierListSyntax, attributes: AttributeListSyntax, inheritance: InheritanceClauseSyntax? = nil, effects: Effects = Effects()) {
            self.kind = kind.rawValue
            self.name = name
            self.headEnd = headEnd
            self.modifiers = modifiers
            self.attributes = attributes
            self.inheritance = inheritance
            self.effects = effects
        }

        /// `deinit` has no `SymbolKind` — it is queryable but never indexed.
        init(deinitializer _: Bool, name: String, headEnd: AbsolutePosition, modifiers: DeclModifierListSyntax, attributes: AttributeListSyntax) {
            kind = "deinit"
            self.name = name
            self.headEnd = headEnd
            self.modifiers = modifiers
            self.attributes = attributes
        }
    }

    /// What a declaration says about itself, before any body is walked.
    struct DeclarationFacts {
        let kind: String
        let name: String
        let attributes: Set<String>
        let modifiers: Set<String>
        let inherited: [String]
        let effects: Effects
        /// The collapsed signature slice, present only when the query carries a `sig:` term.
        let signature: String?
    }

    /// The `async` / `throws` effects of a function-like declaration.
    struct Effects {
        var isAsync = false
        var isThrowing = false

        init() {}

        init(signature: FunctionSignatureSyntax) {
            isAsync = signature.effectSpecifiers?.asyncSpecifier != nil
            isThrowing = signature.effectSpecifiers?.throwsClause != nil
        }

        func contains(_ effect: String) -> Bool {
            switch effect {
            case "async": isAsync
            case "throws": isThrowing
            default: false
            }
        }
    }
}
