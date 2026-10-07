//
// Copyright © Agulhas Labs
//

import SwiftParser
import SwiftSyntax

/// Reads one file's declarations-that-have-bodies into `DeclarationFingerprint` values, then lets the tree go.
///
/// Shaped after `StructuralMatcher`, which answers the other working-tree question over the same nodes: the container walk, the `nameStack` that qualifies a member by its enclosing types, and the signature slice are the same, so a `similar` hit and a `search` hit spell the same declaration the same way.
///
/// What it admits is narrower than what `search` matches, and narrower on purpose. A fingerprint compares *bodies*, so a declaration with none — a protocol requirement, a stored property, a type — has nothing to compare and is left out rather than scored as an empty shape that would rank alike with every other empty shape.
final class FingerprintScanner: SyntaxVisitor {
    private let path: String
    private let converter: SourceLocationConverter
    private let sourceBytes: [UInt8]
    private var nameStack: [String] = []
    /// Per enclosing container, whether it is a class naming `XCTestCase` among its inherited types.
    private var testCaseStack: [Bool] = []
    private(set) var fingerprints: [DeclarationFingerprint] = []

    init(path: String, converter: SourceLocationConverter, sourceBytes: [UInt8]) {
        self.path = path
        self.converter = converter
        self.sourceBytes = sourceBytes
        super.init(viewMode: .sourceAccurate)
    }

    /// Parses `source` and returns its fingerprints; the tree is local to this call and released when it returns.
    static func fingerprints(in source: String, path: String) -> [DeclarationFingerprint] {
        let tree = Parser.parse(source: source)
        let scanner = FingerprintScanner(
            path: path,
            converter: SourceLocationConverter(fileName: path, tree: tree),
            sourceBytes: Array(source.utf8)
        )
        scanner.walk(tree)
        return scanner.fingerprints
    }

    // MARK: Containers

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(SymbolNaming.name(of: node.name))
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let inherited = node.inheritanceClause?.inheritedTypes.map(\.type.trimmedDescription) ?? []
        return enter(SymbolNaming.name(of: node.name), testCase: inherited.contains("XCTestCase"))
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(SymbolNaming.name(of: node.name))
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(SymbolNaming.name(of: node.name))
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(SymbolNaming.name(of: node.name))
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(SymbolNaming.unbackticked(node.extendedType.trimmedDescription))
    }

    override func visitPost(_: StructDeclSyntax) {
        leave()
    }

    override func visitPost(_: ClassDeclSyntax) {
        leave()
    }

    override func visitPost(_: ActorDeclSyntax) {
        leave()
    }

    override func visitPost(_: EnumDeclSyntax) {
        leave()
    }

    override func visitPost(_: ProtocolDeclSyntax) {
        leave()
    }

    override func visitPost(_: ExtensionDeclSyntax) {
        leave()
    }

    // MARK: Declarations with bodies

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let body = node.body else { return .skipChildren }
        record(
            node,
            kind: .function,
            name: SymbolNaming.labeledName(base: SymbolNaming.name(of: node.name), parameters: node.signature.parameterClause.parameters),
            headEnd: node.genericWhereClause?.endPosition ?? node.signature.endPosition,
            body: Syntax(body),
            typeSources: [Syntax(node.signature.parameterClause), node.signature.returnClause.map(Syntax.init)],
            isTest: isTestFunction(node)
        )
        // Nested declarations inside a body are not API and are never candidates, mirroring the indexing visitor.
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let body = node.body else { return .skipChildren }
        record(
            node,
            kind: .initializer,
            name: SymbolNaming.labeledName(base: "init", parameters: node.signature.parameterClause.parameters),
            headEnd: node.genericWhereClause?.endPosition ?? node.signature.endPosition,
            body: Syntax(body),
            typeSources: [Syntax(node.signature.parameterClause)]
        )
        return .skipChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let accessors = node.accessorBlock, Self.hasComparableBody(accessors) else { return .skipChildren }
        record(
            node,
            kind: .subscriptKind,
            name: SymbolNaming.subscriptName(parameters: node.parameterClause.parameters),
            headEnd: node.returnClause.endPosition,
            body: Syntax(accessors),
            typeSources: [Syntax(node.parameterClause), Syntax(node.returnClause)]
        )
        return .skipChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // A stored property has no body to compare; a computed one does. An observer alone (`willSet`/`didSet`)
        // does not: the storage stays stored, and the code the observer runs is not the shape `similar` compares.
        guard let first = node.bindings.first, let accessors = first.accessorBlock, Self.hasComparableBody(accessors) else { return .skipChildren }
        record(
            node,
            kind: .variable,
            name: SymbolNaming.unbackticked(first.pattern.trimmedDescription),
            headEnd: first.typeAnnotation?.endPosition ?? first.pattern.endPosition,
            body: Syntax(accessors),
            typeSources: [first.typeAnnotation.map(Syntax.init)]
        )
        return .skipChildren
    }
}

private extension FingerprintScanner {
    /// Whether the accessor block carries code worth comparing.
    ///
    /// A getter shorthand's code block always does; the full-accessor form does only if some accessor that is not an observer (`get`, `set`, or one of the rarer forms) has a non-nil body. A protocol requirement's `{ get }` has no body on any accessor, and a stored property's `willSet`/`didSet` are observers alone — neither is a declaration `similar` can compare.
    static func hasComparableBody(_ accessorBlock: AccessorBlockSyntax) -> Bool {
        switch accessorBlock.accessors {
        case .getter:
            true
        case let .accessors(list):
            list.contains { accessor in
                accessor.body != nil && !["willSet", "didSet"].contains(accessor.accessorSpecifier.text)
            }
        }
    }

    func enter(_ name: String, testCase: Bool = false) -> SyntaxVisitorContinueKind {
        nameStack.append(name)
        testCaseStack.append(testCase)
        return .visitChildren
    }

    func leave() {
        nameStack.removeLast()
        testCaseStack.removeLast()
    }

    /// Whether `node` is a test function: `@Test`-attributed, or an instance method named `test…` directly inside a class inheriting `XCTestCase`.
    func isTestFunction(_ node: FunctionDeclSyntax) -> Bool {
        let attributed = node.attributes.contains { element in
            guard case let .attribute(attribute) = element else { return false }
            return ["Test", "Testing.Test"].contains(attribute.attributeName.trimmedDescription)
        }
        if attributed {
            return true
        }
        let isStatic = node.modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
        return testCaseStack.last == true && !isStatic && SymbolNaming.name(of: node.name).hasPrefix("test")
    }

    /// One candidate's fingerprint.
    ///
    /// One scanner reads all three axes, walking the body once for its calls and control flow together and then the signature fragments for their type names; `BodyFacts` is not used here, because the names and shapes it also collects are never compared and cost more to gather than the axes that are.
    func record(
        _ node: some SyntaxProtocol,
        kind: SymbolKind,
        name: String,
        headEnd: AbsolutePosition,
        body: Syntax,
        typeSources: [Syntax?],
        isTest: Bool = false
    ) {
        let facts = AxisScanner(viewMode: .sourceAccurate)
        facts.read(body: body, typeSources: typeSources.compactMap(\.self))
        let start = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        let end = converter.location(for: node.endPosition)
        let declaration = StructuralMatch(
            path: path,
            line: start.line,
            endLine: end.line,
            kind: kind.rawValue,
            qualifiedName: (nameStack + [name]).joined(separator: "."),
            signature: SourceSlicer.collapsedSlice(of: sourceBytes, from: node.positionAfterSkippingLeadingTrivia, to: headEnd)
        )
        fingerprints.append(DeclarationFingerprint(
            declaration: declaration,
            callees: facts.callees,
            skeleton: facts.skeleton,
            typeNames: facts.typeNames,
            isTest: isTest
        ))
    }

    /// The collector of a candidate's three axes: callees and control flow from the body, type names from the signature fragments.
    ///
    /// The skeleton is cut at `SimilarityScore.skeletonCap`, because the comparison below it is a longest-common-subsequence over two of these, which is quadratic: an uncapped pair of thousand-token skeletons would cost a million cells to compare a shape that was already decided by its first dozen tokens. Pre-order is source order, so the tokens come back in the order they are written.
    final class AxisScanner: SyntaxVisitor {
        /// Base names of every call in the body, read as `BodyFacts` reads them.
        private(set) var callees: Set<String> = []
        private(set) var skeleton: [DeclarationFingerprint.ControlToken] = []
        /// Every type name written in the signature fragments — `[URL]` contributes `URL`, `some Encodable` contributes `Encodable`.
        private(set) var typeNames: Set<String> = []
        /// Whether the walk is inside the body, where calls and control flow count, rather than a signature fragment, where only type names do.
        private var inBody = false

        /// Walks the body once, then each signature fragment.
        func read(body: Syntax, typeSources: [Syntax]) {
            inBody = true
            walk(body)
            inBody = false
            for source in typeSources {
                walk(source)
            }
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if inBody, let name = CalleeName.base(of: node.calledExpression) {
                callees.insert(name)
            }
            return .visitChildren
        }

        override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
            if !inBody {
                typeNames.insert(node.name.text)
            }
            return .visitChildren
        }

        override func visit(_: IfExprSyntax) -> SyntaxVisitorContinueKind {
            append(.ifToken)
        }

        override func visit(_: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
            append(.guardToken)
        }

        override func visit(_: ForStmtSyntax) -> SyntaxVisitorContinueKind {
            append(.forToken)
        }

        override func visit(_: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
            append(.whileToken)
        }

        override func visit(_: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
            append(.repeatToken)
        }

        override func visit(_: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
            append(.switchToken)
        }

        override func visit(_: DoStmtSyntax) -> SyntaxVisitorContinueKind {
            append(.doToken)
        }

        override func visit(_: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
            append(.catchToken)
        }

        override func visit(_: DeferStmtSyntax) -> SyntaxVisitorContinueKind {
            append(.deferToken)
        }

        override func visit(_: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
            append(.returnToken)
        }

        override func visit(_: ThrowStmtSyntax) -> SyntaxVisitorContinueKind {
            append(.throwToken)
        }

        private func append(_ token: DeclarationFingerprint.ControlToken) -> SyntaxVisitorContinueKind {
            if inBody, skeleton.count < SimilarityScore.skeletonCap {
                skeleton.append(token)
            }
            return .visitChildren
        }
    }
}
