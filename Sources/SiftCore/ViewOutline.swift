//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// The nesting of a `some View` body, as an indented outline.
///
/// This exists because a declaration surface is the wrong *kind* of compression for view code. Digesting a `View` yields `var body: some View` and a member list, which answers nothing about the screen — and views are the largest files in an app repo, so the files above 150 lines that get opened whole rather than digested are overwhelmingly views. Without this the tool is weakest exactly where the files are biggest.
///
/// The rule is structural rather than nominal: **every statement in a view-builder block is a view**, by construction, so each one earns a line whatever it is called. That matters in a codebase which decomposes screens into `some View` methods — `YardView.body` is `NavigationStack { ScrollView { VStack { hero(catalogue); sections(catalogue) } } }`, and a rule that only recognised capitalised constructions would drop `hero` and `sections`, which are the whole point. Modifier chains are collapsed into their root (`Text("x").padding()` is a `Text`), since they are the bulk of view source and almost never why someone opens the file.
struct ViewOutline {
    /// Outline lines are capped so a digest stays a digest — a view with hundreds of leaves truncates rather than turning the answer into the file.
    static let entryLimit = 40

    /// Nesting past this is structure the reader can get from the source once they know where to look.
    static let depthLimit = 6

    /// The walk stops here whatever is left, so a pathological view cannot cost unbounded time.
    ///
    /// Reaching it is reported as `N+ more` rather than a precise count, since past this point the total is genuinely unknown.
    static let walkCeiling = 500

    /// The outline for a `some View` property's body, or `nil` when it is not one.
    static func of(binding: PatternBindingSyntax, converter: SourceLocationConverter) -> String? {
        guard isViewType(binding.typeAnnotation?.type), let body = body(of: binding.accessorBlock) else {
            return nil
        }
        return render(body, converter: converter)
    }

    /// The outline for a `some View` function's body, or `nil` when it is not one.
    ///
    /// Functions matter as much as `body` here: a screen built as a dozen `private func card(…) -> some View` puts almost none of its structure in `body`.
    static func of(function: FunctionDeclSyntax, converter: SourceLocationConverter) -> String? {
        guard isViewType(function.signature.returnClause?.type), let body = function.body else { return nil }
        return render(body.statements, converter: converter)
    }

    /// The whole tree is walked before truncating, so the count in the `… N more` line is the number actually dropped.
    ///
    /// Stopping the walk at the display limit instead would make that number a lie: children of an over-limit node would never be appended, so a body of three thirty-leaf subtrees would report "… 1 more" while fifty leaves went missing. A truncation marker is the answer's honesty contract for a bounded reply, and a wrong one is worse than none. `walkCeiling` bounds the work for a pathological file without touching the common case.
    private static func render(_ statements: CodeBlockItemListSyntax, converter: SourceLocationConverter) -> String? {
        var entries: [Entry] = []
        collect(statements, depth: 0, into: &entries, converter: converter, bound: [])
        guard !entries.isEmpty else { return nil }

        let shown = entries.prefix(entryLimit).map { entry in
            String(repeating: "  ", count: entry.depth) + "\(entry.name) :\(entry.line)"
        }
        guard entries.count > entryLimit else { return shown.joined(separator: "\n") }
        let overflow = entries.count - entryLimit
        let more = entries.count >= walkCeiling ? "… \(overflow)+ more" : "… \(overflow) more"
        return (shown + ["  " + more]).joined(separator: "\n")
    }

    /// Whether a written type is an opaque `View` — annotation only, never inference.
    private static func isViewType(_ type: TypeSyntax?) -> Bool {
        guard let opaque = type?.as(SomeOrAnyTypeSyntax.self) else { return false }
        return opaque.constraint.trimmedDescription.hasSuffix("View")
    }

    /// A computed property's statements: an explicit `get`, or the implicit getter of `var body: some View { … }`.
    private static func body(of accessorBlock: AccessorBlockSyntax?) -> CodeBlockItemListSyntax? {
        switch accessorBlock?.accessors {
        case let .getter(items):
            items
        case let .accessors(list):
            list.first { $0.accessorSpecifier.tokenKind == .keyword(.get) }?.body?.statements
        case nil:
            nil
        }
    }

    /// `bound` is every name introduced in scope — closure parameters and local bindings — and a statement rooted at one of them is not a view.
    ///
    /// This is what separates `Path { path in path.move(to: p) }` from `ForEach(items) { item in Row(item) }`. Both are closures taking a parameter; only the second builds views. The first roots its statements at the parameter itself, and that one shape is the commonest source of spurious entries — `path`, `context`, `ctx`, `line`, and locally-bound `linePath`/`gridPath`/`thresholdPath`.
    private static func collect(
        _ statements: CodeBlockItemListSyntax,
        depth: Int,
        into entries: inout [Entry],
        converter: SourceLocationConverter,
        bound: Set<String>
    ) {
        guard depth <= depthLimit, entries.count < walkCeiling else { return }

        var bound = bound
        for item in statements {
            switch item.item {
            case let .expr(expression):
                append(expression, depth: depth, into: &entries, converter: converter, bound: bound)
            case let .stmt(statement):
                // An `if` or `switch` in statement position arrives wrapped rather than as `.expr`, and missing
                // that drops the branches of every conditional view entirely.
                if let wrapped = statement.as(ExpressionStmtSyntax.self) {
                    append(wrapped.expression, depth: depth, into: &entries, converter: converter, bound: bound)
                    continue
                }
                // `return VStack { … }` — the shape of every view method that computes something first, and
                // an unhandled statement kind drops the whole outline rather than one line of it.
                if let returned = statement.as(ReturnStmtSyntax.self)?.expression {
                    append(returned, depth: depth, into: &entries, converter: converter, bound: bound)
                    continue
                }
                // `for … in` inside a builder: the loop is the repetition, its body the repeated view.
                guard let loop = statement.as(ForStmtSyntax.self) else { continue }
                entries.append(Entry(name: "for", line: line(of: Syntax(loop), converter), depth: depth))
                collect(
                    loop.body.statements,
                    depth: depth + 1,
                    into: &entries,
                    converter: converter,
                    bound: bound.union(names(in: loop.pattern))
                )
            case let .decl(declaration):
                // A `let` inside a builder is a binding, not a view — and every statement after it that is
                // rooted at that name is a mutation of it, not a view either.
                guard let variable = declaration.as(VariableDeclSyntax.self) else { continue }
                for binding in variable.bindings {
                    bound.formUnion(names(in: binding.pattern))
                }
            }
        }
    }

    private static func append(
        _ expression: ExprSyntax,
        depth: Int,
        into entries: inout [Entry],
        converter: SourceLocationConverter,
        bound: Set<String>
    ) {
        // Alternatives are labelled, not merged. Collecting both arms of an `if` as plain children reads as
        // "this contains a ProgressView *and* a List" — the opposite of mutually exclusive — and a five-case
        // switch becomes five siblings with nothing saying which case produced which. For a feature whose job
        // is conveying the shape of a screen, that misleads rather than under-informs.
        if let conditional = expression.as(IfExprSyntax.self) {
            entries.append(Entry(name: "if", line: line(of: Syntax(conditional), converter), depth: depth))
            collect(conditional.body.statements, depth: depth + 1, into: &entries, converter: converter, bound: bound)
            switch conditional.elseBody {
            case let .codeBlock(block):
                entries.append(Entry(name: "else", line: line(of: Syntax(block), converter), depth: depth))
                collect(block.statements, depth: depth + 1, into: &entries, converter: converter, bound: bound)
            case let .ifExpr(nested):
                // `else if` chains stay at one depth rather than staircasing, which is how they read.
                append(ExprSyntax(nested), depth: depth, into: &entries, converter: converter, bound: bound)
            case nil:
                break
            }
            return
        }
        if let switchExpression = expression.as(SwitchExprSyntax.self) {
            entries.append(Entry(name: "switch", line: line(of: Syntax(switchExpression), converter), depth: depth))
            for caseItem in switchExpression.cases {
                guard let block = caseItem.as(SwitchCaseSyntax.self) else { continue }
                entries.append(Entry(
                    name: caseLabel(block),
                    line: line(of: Syntax(block), converter),
                    depth: depth + 1
                ))
                collect(block.statements, depth: depth + 2, into: &entries, converter: converter, bound: bound)
            }
            return
        }

        guard let name = rootName(expression),
              !nonViewConstructions.contains(name),
              // A statement rooted at a name bound in scope is a use of that value, not a view.
              !bound.contains(name)
        else {
            return
        }
        entries.append(Entry(name: name, line: line(of: Syntax(expression), converter), depth: depth))
        for block in builderBlocks(in: expression) {
            collect(
                block.statements,
                depth: depth + 1,
                into: &entries,
                converter: converter,
                bound: bound.union(block.parameters)
            )
        }
    }

    /// A switch case's label as written, collapsed to one line — `case .loading` or `default`.
    private static func caseLabel(_ block: SwitchCaseSyntax) -> String {
        let written = block.label.trimmedDescription
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return written.hasSuffix(":") ? String(written.dropLast()) : written
    }

    /// The name at the root of a call or modifier chain: `Text("x").padding()` is a `Text`, `hero(catalogue)` a `hero`.
    private static func rootName(_ expression: ExprSyntax) -> String? {
        if let call = expression.as(FunctionCallExprSyntax.self) {
            return rootName(call.calledExpression)
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            // A leading-dot expression (`.tint(x)`) has no base and names nothing on its own.
            guard let base = member.base else { return member.declName.baseName.text }
            return rootName(base)
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if let awaited = expression.as(AwaitExprSyntax.self) {
            return rootName(awaited.expression)
        }
        if let tried = expression.as(TryExprSyntax.self) {
            return rootName(tried.expression)
        }
        return nil
    }

    /// Every view-builder block hanging off a call chain: trailing closures and closure arguments alike.
    ///
    /// Both forms carry children — `VStack { … }` is a trailing closure, `ForEach(items) { item in … }` is trailing too, and `.sheet(isPresented:) { … }` hangs off a modifier partway down the chain — so the whole chain is walked rather than only its root.
    ///
    /// Action closures are excluded, and the exclusion is a name list because nothing in the syntax distinguishes them: `.task { await store.refresh() }` and `.overlay { Badge() }` are the same shape, and walking the first puts `store` into the outline as though it were a view.
    private static func builderBlocks(in expression: ExprSyntax) -> [BuilderBlock] {
        // Grouped per call and only the *groups* reversed: the chain is walked outermost-first, so the base's
        // blocks belong before the modifier's — but a single call's own closures are already in source order
        // and reversing those puts an alert's `message:` above its content.
        var groups: [[BuilderBlock]] = []
        var current: ExprSyntax? = expression
        while let node = current {
            if let call = node.as(FunctionCallExprSyntax.self) {
                var blocks: [BuilderBlock] = []
                if !callsAction(call) {
                    let actionRoot = rootName(call.calledExpression).map(actionFirstConstructions.contains) ?? false
                    for argument in call.arguments {
                        guard let closure = argument.expression.as(ClosureExprSyntax.self) else { continue }
                        // `Button(action: { save() }) { Text("Save") }` — the labelled closure is the work.
                        guard !(actionRoot && argument.label?.text == "action") else { continue }
                        blocks.append(BuilderBlock(closure))
                    }
                    // For most calls the plain trailing closure is the content — `VStack { … }`,
                    // `.alert(…) { Button("OK") { } } message: { … }`. For `Button`, it is always the action:
                    // `Button("Save") { save() }` and `Button { save() } label: { … }` both put work there,
                    // and walking it emits `save` as a subview.
                    if let trailing = call.trailingClosure, !actionRoot {
                        blocks.append(BuilderBlock(trailing))
                    }
                    for additional in call.additionalTrailingClosures {
                        blocks.append(BuilderBlock(additional.closure))
                    }
                }
                groups.append(blocks)
                current = call.calledExpression
                continue
            }
            if let member = node.as(MemberAccessExprSyntax.self) {
                current = member.base
                continue
            }
            current = nil
        }
        return groups.reversed().flatMap(\.self)
    }

    /// Whether a call's closures run behaviour rather than build content.
    private static func callsAction(_ call: FunctionCallExprSyntax) -> Bool {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return false }
        return actionModifiers.contains(member.declName.baseName.text)
    }

    /// Constructions that take a closure but are not views, so neither they nor their contents belong in an outline.
    ///
    /// These reach the walk through closure *arguments* — `PlaceholderView(retry: { Task { … } })` — which are followed rather than skipped, because a labelled closure is as often content (`label:`, `destination:`) as it is an action, and losing real structure is the worse error of the two.
    private static let nonViewConstructions: Set<String> = [
        "Task", "withAnimation", "withTransaction", "DispatchQueue", "MainActor", "Timer",
    ]

    /// Views whose *first* closure is behaviour and whose content sits behind a label.
    ///
    /// Only `Button` really needs this, but the shape is shared.
    private static let actionFirstConstructions: Set<String> = ["Button"]

    /// Modifiers whose closure is work, not content.
    ///
    /// Missing one costs a stray line in an outline, so this is kept to the common cases rather than chased exhaustively.
    ///
    /// Member names only — `action:` and `perform:` are argument labels and never appear here, so listing them would do nothing.
    private static let actionModifiers: Set<String> = [
        "task", "onAppear", "onDisappear", "onChange", "onReceive", "onSubmit", "onHover", "onDrag",
        "onDrop", "onOpenURL", "onTapGesture", "onLongPressGesture", "refreshable", "onDelete", "onMove",
        "onKeyPress", "onContinuousHover",
    ]

    /// The names a closure binds: `{ path in … }`, `{ context, size in … }`, `{ (proxy: GeometryProxy) in … }`.
    static func parameterNames(of closure: ClosureExprSyntax) -> Set<String> {
        switch closure.signature?.parameterClause {
        case let .simpleInput(list):
            Set(list.map(\.name.text))
        case let .parameterClause(clause):
            Set(clause.parameters.map { ($0.secondName ?? $0.firstName).text })
        case nil:
            []
        }
    }

    /// Every name a pattern binds, for `let`/`var` declarations and `for` loop variables.
    private static func names(in pattern: PatternSyntax) -> Set<String> {
        if let identifier = pattern.as(IdentifierPatternSyntax.self) {
            return [identifier.identifier.text]
        }
        if let tuple = pattern.as(TuplePatternSyntax.self) {
            return tuple.elements.reduce(into: Set<String>()) { $0.formUnion(names(in: $1.pattern)) }
        }
        if let valueBinding = pattern.as(ValueBindingPatternSyntax.self) {
            return names(in: valueBinding.pattern)
        }
        return []
    }

    private static func line(of node: Syntax, _ converter: SourceLocationConverter) -> Int {
        converter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }
}

private extension ViewOutline {
    /// A closure that may build views, with the names it binds.
    struct BuilderBlock {
        let statements: CodeBlockItemListSyntax
        let parameters: Set<String>

        init(_ closure: ClosureExprSyntax) {
            statements = closure.statements
            parameters = ViewOutline.parameterNames(of: closure)
        }
    }

    struct Entry {
        let name: String
        let line: Int
        let depth: Int
    }
}
