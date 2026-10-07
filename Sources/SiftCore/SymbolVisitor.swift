//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// Walks one syntax tree and emits `ParsedSymbol` records in pre-order.
///
/// The tree is walked exactly once and never retained — the visitor's output is plain value records (the single most important implementation rule in this codebase, see Docs/Design.md §2).
///
/// Function, initializer, subscript, and accessor bodies are skipped entirely: local declarations are not API. Signatures are sliced from the original source (attributes through the return/inheritance clause) so `@MainActor`, `async`, `throws`, and `some`/`any` survive verbatim.
final class SymbolVisitor: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private let sourceBytes: [UInt8]
    private let signatures: Signatures
    private var parentStack: [Int] = []
    private var ifConfigStack: [String] = []
    private(set) var symbols: [ParsedSymbol] = []
    private(set) var imports: [String] = []

    init(converter: SourceLocationConverter, sourceBytes: [UInt8], signatures: Signatures = .display) {
        self.converter = converter
        self.sourceBytes = sourceBytes
        self.signatures = signatures
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: Containers (pre-order record, children visited)

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushContainer(.structKind, name: SymbolNaming.name(of: node.name), head: head(of: node, headEnd: node.memberBlock.position), modifiers: node.modifiers, docTrivia: node.leadingTrivia, inheritance: node.inheritanceClause)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushContainer(.classKind, name: SymbolNaming.name(of: node.name), head: head(of: node, headEnd: node.memberBlock.position), modifiers: node.modifiers, docTrivia: node.leadingTrivia, inheritance: node.inheritanceClause)
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushContainer(.actor, name: SymbolNaming.name(of: node.name), head: head(of: node, headEnd: node.memberBlock.position), modifiers: node.modifiers, docTrivia: node.leadingTrivia, inheritance: node.inheritanceClause)
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushContainer(.enumKind, name: SymbolNaming.name(of: node.name), head: head(of: node, headEnd: node.memberBlock.position), modifiers: node.modifiers, docTrivia: node.leadingTrivia, inheritance: node.inheritanceClause)
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        pushContainer(.protocolKind, name: SymbolNaming.name(of: node.name), head: head(of: node, headEnd: node.memberBlock.position), modifiers: node.modifiers, docTrivia: node.leadingTrivia, inheritance: node.inheritanceClause)
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        pushContainer(.extensionKind, name: SymbolNaming.unbackticked(node.extendedType.trimmedDescription), head: head(of: node, headEnd: node.memberBlock.position), modifiers: node.modifiers, docTrivia: node.leadingTrivia, inheritance: node.inheritanceClause)
    }

    override func visitPost(_: StructDeclSyntax) {
        parentStack.removeLast()
    }

    override func visitPost(_: ClassDeclSyntax) {
        parentStack.removeLast()
    }

    override func visitPost(_: ActorDeclSyntax) {
        parentStack.removeLast()
    }

    override func visitPost(_: EnumDeclSyntax) {
        parentStack.removeLast()
    }

    override func visitPost(_: ProtocolDeclSyntax) {
        parentStack.removeLast()
    }

    override func visitPost(_: ExtensionDeclSyntax) {
        parentStack.removeLast()
    }

    // MARK: Leaf declarations (bodies skipped)

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = SymbolNaming.labeledName(base: SymbolNaming.name(of: node.name), parameters: node.signature.parameterClause.parameters)
        let headEnd = node.genericWhereClause?.endPosition ?? node.signature.endPosition
        record(
            .function,
            name: name,
            head: head(of: node, headEnd: headEnd),
            modifiers: node.modifiers,
            docTrivia: node.leadingTrivia,
            details: RecordDetails(viewOutline: ViewOutline.of(function: node, converter: converter))
        )
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = SymbolNaming.labeledName(base: "init", parameters: node.signature.parameterClause.parameters)
        let headEnd = node.genericWhereClause?.endPosition ?? node.signature.endPosition
        record(.initializer, name: name, head: head(of: node, headEnd: headEnd), modifiers: node.modifiers, docTrivia: node.leadingTrivia)
        return .skipChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = SymbolNaming.subscriptName(parameters: node.parameterClause.parameters)
        let headEnd = requirementAccessorsEnd(node.accessorBlock) ?? node.genericWhereClause?.endPosition ?? node.returnClause.endPosition
        record(.subscriptKind, name: name, head: head(of: node, headEnd: headEnd), modifiers: node.modifiers, docTrivia: node.leadingTrivia)
        return .skipChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.typealiasKind, name: SymbolNaming.name(of: node.name), head: head(of: node, headEnd: node.endPosition), modifiers: node.modifiers, docTrivia: node.leadingTrivia)
        return .skipChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.associatedType, name: SymbolNaming.name(of: node.name), head: head(of: node, headEnd: node.endPosition), modifiers: node.modifiers, docTrivia: node.leadingTrivia)
        return .skipChildren
    }

    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.macro, name: SymbolNaming.name(of: node.name), head: head(of: node, headEnd: node.endPosition), modifiers: node.modifiers, docTrivia: node.leadingTrivia)
        return .skipChildren
    }

    override func visit(_ node: OperatorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.operatorKind, name: SymbolNaming.name(of: node.name), head: head(of: node, headEnd: node.endPosition), modifiers: DeclModifierListSyntax([]), docTrivia: node.leadingTrivia)
        return .skipChildren
    }

    override func visit(_ node: PrecedenceGroupDeclSyntax) -> SyntaxVisitorContinueKind {
        record(.precedenceGroup, name: SymbolNaming.name(of: node.name), head: head(of: node, headEnd: node.endPosition), modifiers: DeclModifierListSyntax([]), docTrivia: node.leadingTrivia)
        return .skipChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // Observer-only accessors (willSet/didSet) are still stored properties; a getter (or get/set) makes it computed.
        let isStored = node.bindings.allSatisfy { binding in
            switch binding.accessorBlock?.accessors {
            case nil:
                true
            case .getter:
                false
            case let .accessors(list):
                list.allSatisfy { accessor in
                    accessor.accessorSpecifier.tokenKind == .keyword(.willSet)
                        || accessor.accessorSpecifier.tokenKind == .keyword(.didSet)
                }
            }
        }
        for binding in node.bindings {
            for identifier in identifierPatterns(in: binding.pattern) {
                record(
                    .variable,
                    name: SymbolNaming.name(of: identifier.identifier),
                    head: head(of: node, headEnd: requirementAccessorsEnd(binding.accessorBlock) ?? variableHeadEnd(binding: binding)),
                    modifiers: node.modifiers,
                    docTrivia: node.leadingTrivia,
                    details: RecordDetails(
                        isStored: isStored,
                        viewOutline: ViewOutline.of(binding: binding, converter: converter)
                    )
                )
            }
        }
        return .skipChildren
    }

    // MARK: Never-API regions (skipped so their locals are not recorded as symbols)

    override func visit(_: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        for element in node.elements {
            record(
                .enumCase,
                name: SymbolNaming.enumCaseName(of: element),
                head: head(of: node, headEnd: node.endPosition),
                modifiers: DeclModifierListSyntax([]),
                docTrivia: node.leadingTrivia,
                details: RecordDetails(signatureOverride: SymbolNaming.enumCaseSignature(of: element))
            )
        }
        return .skipChildren
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        // A scoped import names a declaration after its module, so only the module is the import.
        if node.importKindSpecifier != nil, let module = node.path.first {
            imports.append(module.name.text)
        } else {
            imports.append(node.path.trimmedDescription)
        }
        return .skipChildren
    }

    // MARK: Conditional compilation

    override func visit(_ node: IfConfigClauseSyntax) -> SyntaxVisitorContinueKind {
        if let condition = node.condition {
            ifConfigStack.append(node.poundKeyword.text + " " + condition.trimmedDescription)
        } else {
            ifConfigStack.append("#else")
        }
        return .visitChildren
    }

    override func visitPost(_: IfConfigClauseSyntax) {
        ifConfigStack.removeLast()
    }
}

// MARK: - Record value types

extension SymbolVisitor {
    /// How much of each declaration's head its recorded signature holds.
    enum Signatures {
        /// The whole head, as the index stores it; each answer that prints one shapes it for its own line.
        case display
        /// The whole head, uncapped, with a protocol requirement's accessors (`{ get set }`) as part of it — what `diff` compares, since an edit past a display cap or to a requirement's accessors is a change to what callers can do, and a comparison of cut text would call it unchanged.
        case compared
    }

    /// The three positions a record needs from its node: declaration start, head end, declaration end.
    struct DeclHead {
        let start: AbsolutePosition
        let headEnd: AbsolutePosition
        let end: AbsolutePosition
    }

    /// The seldom-used record extras, bundled so `record` stays within the parameter budget.
    struct RecordDetails {
        var isStored = false
        var signatureOverride: String?
        var inherited: [String] = []
        /// Set only for `some View` properties — see `ViewOutline` for why views get structure where nothing else does.
        var viewOutline: String?

        static var none: RecordDetails {
            RecordDetails()
        }
    }
}

// MARK: - Record construction

private extension SymbolVisitor {
    func head(of node: some SyntaxProtocol, headEnd: AbsolutePosition) -> DeclHead {
        DeclHead(start: node.positionAfterSkippingLeadingTrivia, headEnd: headEnd, end: node.endPosition)
    }

    func pushContainer(_ kind: SymbolKind, name: String, head: DeclHead, modifiers: DeclModifierListSyntax, docTrivia: Trivia, inheritance: InheritanceClauseSyntax?) -> SyntaxVisitorContinueKind {
        record(kind, name: name, head: head, modifiers: modifiers, docTrivia: docTrivia, details: RecordDetails(inherited: inheritedNames(from: inheritance)))
        parentStack.append(symbols.count - 1)
        return .visitChildren
    }

    /// The inheritance clause entries with type attributes (`@unchecked`, `@retroactive`) stripped.
    func inheritedNames(from clause: InheritanceClauseSyntax?) -> [String] {
        guard let clause else { return [] }
        return clause.inheritedTypes.map { entry in
            entry.type.trimmedDescription
                .split(separator: " ")
                .filter { !$0.hasPrefix("@") }
                .joined(separator: " ")
        }
    }

    func record(_ kind: SymbolKind, name: String, head: DeclHead, modifiers: DeclModifierListSyntax, docTrivia: Trivia, details: RecordDetails = .none) {
        let start = converter.location(for: head.start)
        let end = converter.location(for: head.end)
        let signature = details.signatureOverride ?? SourceSlicer.collapsedSlice(of: sourceBytes, from: head.start, to: head.headEnd, cap: nil)
        symbols.append(ParsedSymbol(
            kind: kind,
            name: name,
            parentIndex: parentStack.last,
            line: start.line,
            column: start.column,
            endLine: end.line,
            accessLevel: effectiveAccess(kind: kind, written: writtenAccess(of: modifiers)),
            isStatic: hasStaticModifier(modifiers),
            isStored: details.isStored,
            signature: signature,
            inherited: details.inherited,
            docSummary: SourceSlicer.docSummary(from: docTrivia),
            ifConfigCondition: ifConfigStack.isEmpty ? nil : ifConfigStack.joined(separator: " && "),
            viewOutline: details.viewOutline
        ))
    }

    func writtenAccess(of modifiers: DeclModifierListSyntax) -> AccessLevel? {
        for modifier in modifiers where modifier.detail == nil {
            if let level = AccessLevel(rawValue: modifier.name.text) {
                return level
            }
        }
        return nil
    }

    func hasStaticModifier(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }
    }

    /// Resolves the syntactic access level: the written modifier, else the enclosing extension's written default, else the enclosing protocol/enum access for requirements and cases, else `internal`.
    func effectiveAccess(kind: SymbolKind, written: AccessLevel?) -> AccessLevel {
        if let written {
            return written
        }
        guard let parentIdx = parentStack.last else {
            return .internalLevel
        }
        let parent = symbols[parentIdx]
        return switch parent.kind {
        case .extensionKind:
            parent.explicitExtensionDefault ?? .internalLevel
        case .protocolKind:
            parent.accessLevel
        case .enumKind where kind == .enumCase:
            parent.accessLevel
        default:
            .internalLevel
        }
    }

    /// Every bound identifier in a pattern — plain (`let x`) and tuple (`let (a, b)`) forms alike.
    func identifierPatterns(in pattern: PatternSyntax) -> [IdentifierPatternSyntax] {
        if let identifier = pattern.as(IdentifierPatternSyntax.self) {
            return [identifier]
        }
        if let tuple = pattern.as(TuplePatternSyntax.self) {
            return tuple.elements.flatMap { identifierPatterns(in: $0.pattern) }
        }
        return []
    }

    /// Where a protocol requirement's accessor list ends, when a compared signature carries it — `nil` everywhere else, so the head ends where it always has.
    func requirementAccessorsEnd(_ block: AccessorBlockSyntax?) -> AbsolutePosition? {
        guard signatures == .compared, let block, let parent = parentStack.last, symbols[parent].kind == .protocolKind else { return nil }
        return block.endPosition
    }

    func variableHeadEnd(binding: PatternBindingSyntax) -> AbsolutePosition {
        if let initializer = binding.initializer, initializer.trimmedDescription.count <= 44 {
            return initializer.endPosition
        }
        if let annotation = binding.typeAnnotation {
            return annotation.endPosition
        }
        return binding.pattern.endPosition
    }
}

private extension ParsedSymbol {
    /// The extension's own written access modifier, recoverable from its signature (e.g. `private extension Foo`) — leading attributes (`@available(…)`) are stripped first so they can't hide it.
    var explicitExtensionDefault: AccessLevel? {
        guard kind == .extensionKind else { return nil }
        let stripped = AttributeScanner.strippingLeadingAttributes(signature)
        let firstWords = stripped.split(separator: " ").prefix(2).map(String.init)
        for word in firstWords {
            if let level = AccessLevel(rawValue: word) {
                return level
            }
        }
        return nil
    }
}
