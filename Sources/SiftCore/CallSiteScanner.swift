//
// Copyright © Agulhas Labs
//

import Foundation
import SwiftParser
import SwiftSyntax

/// Finds call sites by written name across the working tree, for the names the semantic layer could not answer for.
///
/// The whole point is batching: `where` refuses *per symbol*, so a query can leave several names unanswered, and each one must not cost its own repo scan. One pass collects every requested name at once.
struct CallSiteScanner {
    let repoRoot: URL
    let enumerator: FileEnumerator

    /// Sites for each requested base name, in the shape asked for it, ordered by path then line.
    ///
    /// Names are base names — `refresh`, not `refresh(_:)` — because a call site's spelling carries argument labels that the declaration's own name may not.
    func callSites(named names: [String: SiteShape]) async -> [String: [SyntacticCallSite]] {
        guard !names.isEmpty else { return [:] }
        let scanned = await scan(named: names)
        var collected = scanned.sites
        // `@T` calls an initializer only where T is a property wrapper: the same attribute is a result builder, a macro
        // or another module's wrapper otherwise. Every file declaring T spells T, so each declaration was seen.
        for (type, sites) in scanned.attributeSites where scanned.propertyWrappers.contains(type) {
            collected[type, default: []].append(contentsOf: sites)
        }
        let projected = await projectedArguments(to: scanned.wrappedParameters.filter { scanned.propertyWrappers.contains($0.key) })
        for (type, sites) in projected {
            collected[type, default: []].append(contentsOf: sites)
        }
        return collected.mapValues { $0.sorted { ($0.path, $0.line) < ($1.path, $1.line) } }
    }

    /// The base name a call site would be spelled with — `refresh` from `refresh(_:)`, `init` from `init(from:)`, `..<` from `..<(lhs:rhs:)` or `Lib.Box...<`.
    ///
    /// An operator is cut out by its trailing run of operator characters, since splitting on `.` would take the dots of `..<` for member separators. The run is the operator itself only when it is the whole name or follows an identifier with a `.` (the member separator, which then is not part of it); `init?` is no operator.
    static func baseName(of symbol: String) -> String {
        let head = symbol.firstIndex(of: "(").map { String(symbol[symbol.startIndex ..< $0]) } ?? symbol
        var start = head.endIndex
        while start > head.startIndex, operatorCharacters.contains(head[head.index(before: start)]) {
            start = head.index(before: start)
        }
        if start < head.endIndex {
            if start == head.startIndex {
                return head
            }
            let before = head[head.index(before: start)]
            if head[start] == ".", before.isLetter || before.isNumber || before == "_" {
                return String(head[head.index(after: start)...])
            }
        }
        return head.split(separator: ".").last.map(String.init) ?? head
    }

    private static let operatorCharacters: Set<Character> = Set("/=-+!*%<>&|^~?.")

    /// What every file spelling one of `names` holds, merged.
    private func scan(named names: [String: SiteShape]) async -> ScannedCallSites {
        let paths = enumerator.swiftFiles()
        guard !paths.isEmpty else { return ScannedCallSites() }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let rootPath = repoRoot.path
        var merged = ScannedCallSites()
        await withTaskGroup(of: ScannedCallSites.self) { group in
            var iterator = paths.makeIterator()
            var inFlight = 0
            while inFlight < cores, let path = iterator.next() {
                group.addTask { Self.sites(at: path, rootPath: rootPath, names: names) }
                inFlight += 1
            }
            for await found in group {
                merged.sites.merge(found.sites) { $0 + $1 }
                merged.attributeSites.merge(found.attributeSites) { $0 + $1 }
                merged.propertyWrappers.formUnion(found.propertyWrappers)
                merged.wrappedParameters.merge(found.wrappedParameters) { $0 + $1 }
                if let path = iterator.next() {
                    group.addTask { Self.sites(at: path, rootPath: rootPath, names: names) }
                }
            }
        }
        return merged
    }

    /// The calls passing `$label:` to one of `parameters`, by the wrapper type the parameter is declared with: each a call of that type's `init(projectedValue:)`, made where the call is written rather than at the parameter's `@T`.
    ///
    /// Found by a second scan for the declarations' own names, since a file making the call need not spell the wrapper at all. A call is matched to the declarations its full labels reach, `$` read off, and one whose labels reach a same-named declaration's parameter declared with another wrapper is kept and flagged rather than dropped, since labels alone cannot tell which is called.
    private func projectedArguments(to parameters: [String: [WrappedParameter]]) async -> [String: [SyntacticCallSite]] {
        var shapes: [String: SiteShape] = [:]
        for parameter in parameters.values.joined() {
            shapes[parameter.callee] = (parameter.isInitializer ? SiteShape.initializer : .call).widened(by: shapes[parameter.callee])
        }
        guard !shapes.isEmpty else { return [:] }
        let scanned = await scan(named: shapes)
        // Every declaration of those names with a wrapped parameter, whichever wrapper, each parameter once.
        var declared: [String: [WrappedParameter]] = [:]
        var seen: Set<String> = []
        for parameter in Array(parameters.values.joined()) + scanned.wrappedParameters.values.joined() where shapes[parameter.callee] != nil && seen.insert(parameter.declaredAt + parameter.label).inserted {
            declared[parameter.callee, default: []].append(parameter)
        }
        // One entry per site and wrapper, however many names the site was found under: an `.init` call is found under each type it may make.
        var projected: [String: [String: (site: SyntacticCallSite, call: ProjectedCall)]] = [:]
        for (callee, sites) in scanned.sites {
            for site in sites {
                guard let arguments = site.arguments else { continue }
                let reached = (declared[callee] ?? []).filter { $0.receives(arguments) }
                for label in Set(reached.map(\.label)) {
                    let byLabel = reached.filter { $0.label == label }
                    let wrappers = Set(byLabel.map(\.wrapper))
                    for type in wrappers where parameters[type] != nil {
                        let key = "\(site.path):\(site.calleeAt ?? String(site.line))"
                        var entry = projected[type, default: [:]][key] ?? (site, ProjectedCall(parameters: [], otherWrappers: []))
                        entry.call.parameters += byLabel.filter { $0.wrapper == type && !entry.call.parameters.contains($0) }
                        entry.call.otherWrappers = wrappers.subtracting([type]).union(entry.call.otherWrappers).sorted()
                        projected[type, default: [:]][key] = entry
                    }
                }
            }
        }
        return projected.mapValues { entries in entries.values.map { $0.site.projecting($0.call) } }
    }

    private static func sites(at path: String, rootPath: String, names: [String: SiteShape]) -> ScannedCallSites {
        guard let data = FileManager.default.contents(atPath: rootPath + "/" + path),
              let source = String(data: data, encoding: .utf8) else { return ScannedCallSites() }
        // A file that never spells the name cannot contain a call to it, and the substring check is far cheaper than a parse — the difference between scanning a monorepo and scanning the few files that could possibly match.
        // An `.init call` whose type is only implied spells no type name, and it is counted beside an initializer's sites; nor does a `Self(x)` in an extension of a type declared in another file.
        let isInitializerSweep = names.values.contains(.initializer)
        let spelled = isInitializerSweep ? Array(names.keys) + ["init"] : Array(names.keys)
        guard spelled.contains(where: { source.contains($0) }) || isInitializerSweep && SelfCallSpelling.isWritten(in: source) else { return ScannedCallSites() }
        let tree = Parser.parse(source: source)
        return sites(in: tree, converter: SourceLocationConverter(fileName: path, tree: tree), path: path, names: names)
    }

    /// What one already parsed file holds for `names`, for a caller that reads the same tree for something else too.
    static func sites(in tree: SourceFileSyntax, converter: SourceLocationConverter, path: String, names: [String: SiteShape]) -> ScannedCallSites {
        let visitor = Visitor(names: names, path: path, converter: converter)
        visitor.walk(tree)
        // Read once per file, and only where a site was found: the converter splits the whole file on every read.
        let (sourceLines, values) = visitor.sites.isEmpty && visitor.attributeSites.isEmpty ? ([], []) : (converter.sourceLines, BoundValueNames.of(tree))
        let sites = BareNameOutsideTypes.unmarking(LocalTypeShadow.unmarking(visitor.sites.mapValues { $0.map { $0.untyped(namingAnyOf: visitor.localTypes, orValues: values).reading(sourceLines) } }, boundAsValues: values), in: tree, boundAsValues: values)
        let attributeSites = visitor.attributeSites.mapValues { $0.map { $0.reading(sourceLines) } }
        return ScannedCallSites(sites: sites, attributeSites: attributeSites, propertyWrappers: visitor.propertyWrappers, wrappedParameters: visitor.wrappedParameters)
    }
}

extension CallSiteScanner {
    /// What the scan counts as a site of a name.
    enum SiteShape: Sendable {
        /// A call whose callee is spelled with the name: how a function, an initializer or a type is reached.
        case call
        /// A call, or the name written as a value with no call — `T.f`, `T.f(x:)`, `#selector(f(_:))`: how a function is reached, since one handed on unapplied is used without ever being called.
        case callOrReference
        /// The name is a type's, and the sites are its initializers' — `T(x)`, `T<U>(x)`, `T.init call`, `Self(x)`, `Self.init call` and `self.init call` inside it or its extensions, `super.init call` in its subclass, `.init call` where a declared type names it, `T.init call` handed on unapplied, and `@T` on a stored property or a parameter where T is a property wrapper: how an initializer is reached, since it is called through its type rather than by its own name.
        case initializer
        /// Any expression spelling the name, a callee included: how a property is reached, since it is read and written rather than called, and a call alone would find nothing of a property used everywhere.
        case use
        /// Anywhere the name is written as a type is used: as an expression — `T(x)`, `T.m`, `T.self` — or in a type position — an annotation, a generic argument, a conformance, a cast, an attribute: how a type is reached, since one used only through its static members or in annotations is never called by its own name.
        case typeUse

        /// The shape a declaration of `kind` is scanned in, widened to cover `other`, the shape already asked of a name it shares.
        ///
        /// A property or an enum case is not reached by a call alone — a property is read and written, a case written `.fast` or matched in a pattern — so what stands for its callers is its uses, a function is reached by a call or by being named unapplied, an operator declaration by being applied or handed on bare (`reduce(0, +)`) as its functions are, and an initializer through its type, which is the name asked for it. A name shared with something reached more widely takes the wider reading, since a call is a reference and a reference is a use.
        static func of(_ kind: SymbolKind, sharing other: SiteShape?) -> SiteShape {
            let own: SiteShape = kind.isUsedRatherThanCalled ? .use : kind == .initializer ? .initializer : kind == .function || kind == .operatorKind ? .callOrReference : .call
            return own.widened(by: other)
        }

        /// This shape or `other`, whichever finds more: a use covers every spelling, and a type's initializer sites every call spelled with its name.
        func widened(by other: SiteShape?) -> SiteShape {
            guard let other else { return self }
            return [SiteShape.typeUse, .use, .initializer, .callOrReference].first { $0 == self || $0 == other } ?? .call
        }
    }
}

private extension CallSiteScanner {
    /// Walks one tree recording the sites of any of the requested names, each in the shape asked for it, tagged with the declaration they sit in.
    final class Visitor: SyntaxVisitor {
        private let names: [String: SiteShape]
        private let path: String
        private let converter: SourceLocationConverter
        private var enclosing: [String] = []
        /// The declared names of the types around the current node, outermost first.
        private var enclosingTypes: [String] = []
        /// The superclass each of those types names first in its inheritance clause, where it is a class that names one.
        private var superclasses: [String?] = []
        /// The capitalised names each of those types' where clauses write, where it is an extension, which constrain the `Self` its members run on.
        private var constraints: [[String]?] = []
        /// The type each of those types' where clauses pins `Self` to, where it is an extension whose clause does (``SelfPin``).
        private var pinnedSelves: [String?] = []
        /// The generic parameters each enclosing declaration introduces, one set per entry of `enclosing`.
        private var generics: [Set<String>] = []
        /// The capitalised names each enclosing function's, initializer's or subscript's own where clause writes, one list per entry of `enclosing`, which constrain the `Self` its body runs on.
        private var requirements: [[String]] = []
        /// The types whose initializers are asked for, which an `.init call` of a type the scan cannot tell may belong to.
        private let initializedTypes: [String]
        /// The names of the types and typealiases declared inside a function, closure or accessor body, which the index never records.
        private(set) var localTypes: Set<String> = []
        /// The structs, classes, enums and actors this file declares, at any depth, whose extensions' `Self` is that type.
        private var declaredTypes: Set<String> = []
        /// The `Self` calls written in extensions of types no asked one, held until the walk ends.
        private var selfCallsInExtensions: [HeldSelfCall] = []
        var sites: [String: [SyntacticCallSite]] = [:]
        /// The `@T` attributes that call T's initializer if T is a property wrapper, by T.
        var attributeSites: [String: [SyntacticCallSite]] = [:]
        /// The types asked for that are declared here with `@propertyWrapper`.
        var propertyWrappers: Set<String> = []
        /// The labelled parameters declared with `@T`, by T, where T is asked as an initializer's type or the declaration's name is asked.
        var wrappedParameters: [String: [WrappedParameter]] = [:]

        init(names: [String: SiteShape], path: String, converter: SourceLocationConverter) {
            self.names = names
            initializedTypes = names.filter { $0.value == .initializer }.keys.sorted()
            self.path = path
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if !initializedTypes.isEmpty, recordInitializer(node.calledExpression, at: node, arguments: WrittenArguments(of: node).appliedDirectly) {
                return .visitChildren
            }
            if let name = CalleeName.base(of: node.calledExpression), names[name] == .call || names[name] == .callOrReference {
                record(name, at: node, arguments: WrittenArguments(of: node), receiver: CallReceiver.of(node.calledExpression))
            }
            return .visitChildren
        }

        /// A name written as an expression: bare, as a member, or as a key-path component, all of them this one node, which a declaration's own name never is.
        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            let name = SymbolNaming.name(of: node.baseName)
            if name == "init", !initializedTypes.isEmpty, !Self.isCallee(node),
               let member = node.parent?.as(MemberAccessExprSyntax.self), member.declName.id == node.id
            {
                // `T.init` handed on unapplied can be nothing but an initializer; a compound one states its labels.
                let arguments = node.argumentNames.map { names in
                    WrittenArguments(labels: [], calleeLabels: names.arguments.map { WrittenArguments.label($0.name) })
                }
                _ = recordInitializer(ExprSyntax(member), at: node, arguments: arguments)
            } else if names[name] == .use {
                record(name, at: node, receiver: CallReceiver.ofUse(node))
            } else if names[name] == .typeUse {
                // Written as a member, `M.T` or `.T`, it is qualified: an implicit member's empty qualifier names its contextual type.
                let member = node.parent?.as(MemberAccessExprSyntax.self).flatMap { $0.declName.id == node.id ? $0 : nil }
                _ = recordTypeUse(of: node.baseName, at: node, qualifier: member.map { CallReceiver.writtenPath($0.base) ?? $0.base?.trimmedDescription ?? "" })
            } else if names[name] == .callOrReference, !Self.isCallee(node) {
                // A compound name states the labels of the declaration it means, so the fallback can narrow by them as
                // it does a call's; a bare one says nothing of them and is never dropped.
                let arguments = node.argumentNames.map { names in
                    WrittenArguments(labels: [], calleeLabels: names.arguments.map { WrittenArguments.label($0.name) })
                }
                if arguments != nil || Self.isInSelector(node) {
                    record(name, at: node, arguments: arguments)
                } else {
                    // A bare `T.f` handed to a call is the function's only on a type declaring it, which the scan does
                    // not know; the reader of the sites judges it by the type written (`SyntacticCallSite.isListed`).
                    // An operator handed on bare, `reduce(0, +)`, can be nothing but an operator, so it is listed, at the operator's own column, where the store records its reference, so one listed from the store is not listed twice.
                    let type = Self.typeHandingOn(node)
                    if SymbolNaming.isOperator(name) {
                        let location = converter.location(for: node.baseName.positionAfterSkippingLeadingTrivia)
                        sites[name, default: []].append(site(at: node, arguments: nil, unappliedOn: type, operatorAt: "\(location.line):\(location.column)"))
                    } else {
                        record(name, at: node, nameOnly: type == nil, unappliedOn: type)
                    }
                }
            }
            return .visitChildren
        }

        /// An operator applied where it is written — `a + b`, `-a`, `b^^` — which is how an operator function is called, since it spells no `name(`.
        override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            recordOperator(node.operator, at: node)
        }

        override func visit(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            recordOperator(node.operator, at: node)
        }

        override func visit(_ node: PostfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            recordOperator(node.operator, at: node)
        }

        /// A type's name written in a type position — an annotation, a generic argument, a conformance, a cast, an attribute, an `extension` header — where a type is asked for its uses.
        override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
            recordTypeUse(of: node.name, at: node, qualifier: nil)
        }

        /// The last component of a qualified type, `T` in `M.T`, where a type is asked for its uses.
        override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
            recordTypeUse(of: node.name, at: node, qualifier: DeclaredTypeName.path(of: node.baseType) ?? node.baseType.trimmedDescription)
        }

        /// Records `name` where it is asked as a type, with what it is qualified with, unless it is written bare where an enclosing generic parameter list binds it: `T` in `func f<T>(_ x: T)` is that parameter, never the type.
        private func recordTypeUse(of name: TokenSyntax, at node: some SyntaxProtocol, qualifier: String?) -> SyntaxVisitorContinueKind {
            let type = name.identifier?.name ?? name.text
            if names[type] == .typeUse, qualifier != nil || !generics.contains(where: { $0.contains(type) }) {
                let location = converter.location(for: name.positionAfterSkippingLeadingTrivia)
                sites[type, default: []].append(LocalTypealias.tagging(ProtocolBodyScope.marking(BareNameOutsideTypes.marking(LocalTypeShadow.marking(site(at: node, arguments: nil, qualifier: qualifier, nameAt: "\(location.line):\(location.column)"), writing: type, at: node), writing: type, at: node), writing: type, at: node), writing: type, at: node, converter: converter, inFunction: enclosing.count > enclosingTypes.count, atTopLevel: enclosingTypes.isEmpty))
            }
            return .visitChildren
        }

        /// A custom attribute on a stored property, `@Wrap var x = 1`, or on a parameter, which calls the wrapper type's initializer where it is a property wrapper.
        ///
        /// Kept apart until the scan knows which types are property wrappers. The arguments are the ones the compiler writes where they can be read: those in parentheses, led by `wrappedValue:` where the property is given an initial value or the attribute is on a parameter, whose argument supplies it. With neither, on a stored property, the labels are unknown, since a memberwise initializer passes the wrapped value. An attribute on a function or on a computed property is no site, and neither is a built-in one.
        override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
            let holder = node.parent?.parent
            noteWrappedParameter(holder?.as(FunctionParameterSyntax.self), attribute: node)
            guard !initializedTypes.isEmpty else { return .visitChildren }
            let written: [String?] = if case let .argumentList(list) = node.arguments {
                list.map { $0.label.flatMap(WrittenArguments.label) }
            } else {
                []
            }
            let arguments: WrittenArguments?
            if let variable = holder?.as(VariableDeclSyntax.self) {
                guard let binding = variable.bindings.first, !Self.isComputed(binding) else { return .visitChildren }
                if binding.initializer != nil {
                    arguments = WrittenArguments(labels: ["wrappedValue"] + written)
                } else {
                    arguments = written.isEmpty ? nil : WrittenArguments(labels: written)
                }
            } else if holder?.is(FunctionParameterSyntax.self) == true || holder?.is(ClosureParameterSyntax.self) == true {
                arguments = WrittenArguments(labels: ["wrappedValue"] + written, alternateFirstLabels: ["projectedValue", "initialValue"])
            } else {
                return .visitChildren
            }
            let type = DeclaredTypeName.of(node.attributeName)
            guard names[type] == .initializer, !Self.builtInAttributes.contains(type) else { return .visitChildren }
            let qualifier = node.attributeName.as(MemberTypeSyntax.self).map { DeclaredTypeName.path(of: $0.baseType) ?? $0.baseType.trimmedDescription }
            attributeSites[type, default: []].append(site(at: node, arguments: arguments, qualifier: qualifier, isAttribute: true, isParameterAttribute: holder?.is(FunctionParameterSyntax.self) == true))
            return .visitChildren
        }

        /// Notes the type a struct, class, enum or actor declares, and one asked for whose declaration carries `@propertyWrapper`, the only kind whose initializer an attribute calls.
        private func noteDeclaration(of name: TokenSyntax, attributes: AttributeListSyntax) {
            let type = name.identifier?.name ?? name.text
            declaredTypes.insert(type)
            let isWrapper = attributes.contains { $0.as(AttributeSyntax.self).map { DeclaredTypeName.of($0.attributeName) == "propertyWrapper" } ?? false }
            if isWrapper, names[type] == .initializer {
                propertyWrappers.insert(type)
            }
        }

        /// The capitalised attributes the language itself defines for a property, none of them a type whose initializer is called.
        private static let builtInAttributes: Set<String> = [
            "MainActor", "NSManaged", "NSCopying", "IBOutlet", "IBInspectable", "GKInspectable",
        ]

        /// Whether a property binding is computed — a getter, or accessors other than observers — which no property wrapper can sit on.
        private static func isComputed(_ binding: PatternBindingSyntax) -> Bool {
            switch binding.accessorBlock?.accessors {
            case .none:
                false
            case .getter:
                true
            case let .accessors(list):
                list.contains { !["willSet", "didSet"].contains($0.accessorSpecifier.text) }
            }
        }

        /// Records a call or a reference whose callee is `callee` where it reaches an initializer of a type asked for, returning whether the callee spells an initializer at all.
        ///
        /// An `.init call` whose type no declaration around it states is recorded as name-only for every type asked, since it may be any of them; one of another type is no site.
        private func recordInitializer(_ callee: ExprSyntax, at node: some SyntaxProtocol, arguments: WrittenArguments?) -> Bool {
            let callee = callee.as(GenericSpecializationExprSyntax.self)?.expression ?? callee
            let member = callee.as(MemberAccessExprSyntax.self)
            guard let reference = member?.declName ?? callee.as(DeclReferenceExprSyntax.self) else { return false }
            if member == nil, reference.baseName.tokenKind == .keyword(.Self) {
                recordOnSelf(at: node, arguments: arguments)
                return true
            }
            guard reference.baseName.text == "init" else {
                let type = reference.baseName.identifier?.name ?? reference.baseName.text
                guard names[type] == .initializer else { return false }
                record(type, at: node, arguments: arguments, qualifier: CallReceiver.writtenPath(member?.base))
                return true
            }
            guard let member else { return false }
            let type: String?
            let qualifier: String?
            if let base = member.base {
                if let keyword = base.as(DeclReferenceExprSyntax.self)?.baseName.tokenKind, keyword == .keyword(.self) || keyword == .keyword(.Self) {
                    recordOnSelf(at: node, arguments: arguments, untold: keyword == .keyword(.Self))
                    return true
                }
                type = initializedType(base)
                qualifier = base.as(MemberAccessExprSyntax.self).flatMap { CallReceiver.writtenPath($0.base) }
            } else {
                guard let implied = impliedType(of: Syntax(node)) else {
                    for type in initializedTypes {
                        record(type, at: node, arguments: arguments, nameOnly: true)
                    }
                    return true
                }
                (type, qualifier) = implied
            }
            if let type, names[type] == .initializer {
                record(type, at: node, arguments: arguments, qualifier: qualifier)
            }
            return true
        }

        /// The simple name of the type `base.init` initializes — its superclass's for `super` — or `nil` where the base spells none.
        private func initializedType(_ base: ExprSyntax) -> String? {
            if base.is(SuperExprSyntax.self) {
                return superclasses.last.flatMap(\.self)
            }
            return Self.writtenTypeName(base)
        }

        /// Counts each held `Self` call for every type asked but the one a pin rules out, unless the file declares the type `Self` is written as there.
        override func visitPost(_: SourceFileSyntax) {
            for held in selfCallsInExtensions where !declaredTypes.contains(held.selfType) {
                for type in initializedTypes where type != held.notFor {
                    sites[type, default: []].append(held.site)
                }
            }
        }

        /// Whether a name is written inside a `#selector`, which names only a method.
        private static func isInSelector(_ node: DeclReferenceExprSyntax) -> Bool {
            var ancestor = node.parent
            while let current = ancestor {
                if current.as(MacroExpansionExprSyntax.self)?.macroName.text == "selector" {
                    return true
                }
                ancestor = current.parent
            }
            return false
        }

        /// The simple name of the type a bare `T.f` is written on where it is handed to a call — `.map(T.f)` — or `nil` for any other spelling of the name.
        ///
        /// Anywhere else a bare name is spelled exactly as a same-named local, property or case is read — `f`, `x.f`, `.f`, and a static property's `T.f` in an interpolation.
        private static func typeHandingOn(_ node: DeclReferenceExprSyntax) -> String? {
            guard let member = node.parent?.as(MemberAccessExprSyntax.self), member.declName.id == node.id, let base = member.base,
                  member.parent?.as(LabeledExprSyntax.self)?.parent?.parent?.is(FunctionCallExprSyntax.self) == true
            else { return nil }
            guard let type = writtenTypeName(base) else { return nil }
            if let reference = base.as(DeclReferenceExprSyntax.self), LocalBindingShadow.hides(reference.baseName.text, before: reference) {
                // A local `let`/`var` spelled like the type makes the base a value, not the type: `let Clock = …;
                // take(Clock.tick)` is a value's member, never a credited site of `Clock.tick`.
                return nil
            }
            return type
        }

        /// The simple name an expression spells a type by — `Depot` for `Depot`, `App.Depot`, `Depot<Int>` or `Depot.self` — or `nil` where it spells none.
        private static func writtenTypeName(_ expression: ExprSyntax) -> String? {
            if let generic = expression.as(GenericSpecializationExprSyntax.self) {
                return writtenTypeName(generic.expression)
            }
            if let member = expression.as(MemberAccessExprSyntax.self) {
                if member.declName.baseName.tokenKind == .keyword(.self), let base = member.base {
                    return writtenTypeName(base)
                }
                return member.declName.baseName.identifier?.name ?? member.declName.baseName.text
            }
            guard let token = expression.as(DeclReferenceExprSyntax.self)?.baseName else { return nil }
            return token.identifier?.name ?? token.text
        }

        private func record(
            _ name: String,
            at node: some SyntaxProtocol,
            arguments: WrittenArguments? = nil,
            nameOnly: Bool = false,
            unappliedOn: String? = nil,
            qualifier: String? = nil,
            receiver: CallReceiver? = nil
        ) {
            sites[name, default: []].append(site(at: node, arguments: arguments, nameOnly: nameOnly, unappliedOn: unappliedOn, qualifier: qualifier, receiver: receiver))
        }

        private func site(
            at node: some SyntaxProtocol,
            arguments: WrittenArguments?,
            nameOnly: Bool = false,
            unappliedOn: String? = nil,
            qualifier: String? = nil,
            isAttribute: Bool = false,
            isParameterAttribute: Bool = false,
            receiver: CallReceiver? = nil,
            nameAt: String? = nil,
            callsUntoldSelf: Bool = false,
            operatorAt: String? = nil
        ) -> SyntacticCallSite {
            SyntacticCallSite(
                path: path,
                line: converter.location(for: node.positionAfterSkippingLeadingTrivia).line,
                enclosing: enclosing.isEmpty ? "(top level)" : enclosing.joined(separator: "."),
                // Swift reads a type's inheritance clause from outside the type, so its own members are not in scope there.
                enclosingTypes: InheritanceClauseScope.isInOwnClause(node) ? enclosingTypes.dropLast() : enclosingTypes,
                enclosingConstraints: constraints.flatMap { $0 ?? [] } + requirements.flatMap(\.self),
                arguments: arguments,
                nameOnly: nameOnly,
                unappliedOn: unappliedOn,
                qualifier: qualifier,
                qualifiedByGenericParameter: qualifier?.split(separator: ".").first.map { head in generics.contains { $0.contains(String(head)) } } ?? false,
                isAttribute: isAttribute,
                isParameterAttribute: isParameterAttribute,
                receiver: receiver?.scoped(generics: generics, inExtension: constraints.contains { $0 != nil }),
                isUnchainedImplicitMemberCall: Self.isUnchainedImplicitMemberCall(Syntax(node)),
                calleeAt: operatorAt ?? calleeAt(node.as(FunctionCallExprSyntax.self)) ?? calleeAt(node.as(AttributeSyntax.self)),
                nameAt: nameAt,
                callsUntoldSelf: callsUntoldSelf
            )
        }

        // MARK: Declaration context

        // Every declaration code can be written in, so a site is credited to the one it sits in: one left off this
        // list credits its body to the declaration around it — a call in a subscript's getter to the type that
        // declares the subscript. Accessors and observers stay with their property or subscript, a closure
        // assigned to a property with that property, and a local function or type with itself.

        override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
            push(
                SymbolNaming.subscriptName(parameters: node.parameterClause.parameters),
                generics: Self.names(node.genericParameterClause),
                requirements: Self.typeNames(in: node.genericWhereClause)
            )
        }

        override func visit(_: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
            push("deinit")
        }

        /// A case's associated-value default is code written in the case, not in the enum around it.
        override func visit(_ node: EnumCaseElementSyntax) -> SyntaxVisitorContinueKind {
            push(SymbolNaming.enumCaseName(of: node))
        }

        override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
            if enclosing.count > enclosingTypes.count {
                localTypes.insert(node.name.identifier?.name ?? node.name.text)
            }
            // A generic typealias's parameters are in scope on its right-hand side, as a macro's are in its signature.
            generics.append(Self.names(node.genericParameterClause))
            return .visitChildren
        }

        override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
            generics.append(Self.names(node.genericParameterClause))
            return .visitChildren
        }

        override func visitPost(_: TypeAliasDeclSyntax) {
            generics.removeLast()
        }

        override func visitPost(_: MacroDeclSyntax) {
            generics.removeLast()
        }

        override func visitPost(_: SubscriptDeclSyntax) {
            pop()
        }

        override func visitPost(_: DeinitializerDeclSyntax) {
            pop()
        }

        override func visitPost(_: EnumCaseElementSyntax) {
            pop()
        }

        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
            noteDeclaration(of: node.name, attributes: node.attributes)
            return push(SymbolNaming.name(of: node.name), type: node.name.identifier?.name ?? node.name.text, generics: Self.names(node.genericParameterClause))
        }

        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            noteDeclaration(of: node.name, attributes: node.attributes)
            let superclass = node.inheritanceClause?.inheritedTypes.first.map { DeclaredTypeName.of($0.type) }
            return push(SymbolNaming.name(of: node.name), type: node.name.identifier?.name ?? node.name.text, superclass: superclass, generics: Self.names(node.genericParameterClause))
        }

        override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
            noteDeclaration(of: node.name, attributes: node.attributes)
            return push(SymbolNaming.name(of: node.name), type: node.name.identifier?.name ?? node.name.text, generics: Self.names(node.genericParameterClause))
        }

        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
            noteDeclaration(of: node.name, attributes: node.attributes)
            return push(SymbolNaming.name(of: node.name), type: node.name.identifier?.name ?? node.name.text, generics: Self.names(node.genericParameterClause))
        }

        override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
            push(SymbolNaming.unbackticked(node.extendedType.trimmedDescription), type: DeclaredTypeName.of(node.extendedType), constraints: Self.typeNames(in: node.genericWhereClause), pinnedSelf: SelfPin.type(in: node.genericWhereClause))
        }

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            push(
                SymbolNaming.labeledName(base: SymbolNaming.name(of: node.name), parameters: node.signature.parameterClause.parameters),
                generics: Self.names(node.genericParameterClause),
                requirements: Self.typeNames(in: node.genericWhereClause)
            )
        }

        override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
            push(
                SymbolNaming.labeledName(base: "init", parameters: node.signature.parameterClause.parameters),
                generics: Self.names(node.genericParameterClause),
                requirements: Self.typeNames(in: node.genericWhereClause)
            )
        }

        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            push(node.bindings.first.map { SymbolNaming.unbackticked($0.pattern.trimmedDescription) } ?? "var")
        }

        override func visitPost(_: StructDeclSyntax) {
            pop(type: true)
        }

        override func visitPost(_: ClassDeclSyntax) {
            pop(type: true)
        }

        override func visitPost(_: ActorDeclSyntax) {
            pop(type: true)
        }

        override func visitPost(_: EnumDeclSyntax) {
            pop(type: true)
        }

        override func visitPost(_: ExtensionDeclSyntax) {
            pop(type: true)
        }

        override func visitPost(_: FunctionDeclSyntax) {
            pop()
        }

        override func visitPost(_: InitializerDeclSyntax) {
            pop()
        }

        override func visitPost(_: VariableDeclSyntax) {
            pop()
        }

        private func push(
            _ name: String,
            type: String? = nil,
            superclass: String? = nil,
            generics introduced: Set<String> = [],
            constraints written: [String]? = nil,
            requirements required: [String] = [],
            pinnedSelf: String? = nil
        ) -> SyntaxVisitorContinueKind {
            if let type, enclosing.count > enclosingTypes.count {
                localTypes.insert(type)
            }
            enclosing.append(name)
            generics.append(introduced)
            requirements.append(required)
            if let type {
                enclosingTypes.append(type)
                superclasses.append(superclass)
                constraints.append(written)
                pinnedSelves.append(pinnedSelf)
            }
            return .visitChildren
        }

        private func pop(type: Bool = false) {
            enclosing.removeLast()
            generics.removeLast()
            requirements.removeLast()
            if type {
                enclosingTypes.removeLast()
                superclasses.removeLast()
                constraints.removeLast()
                pinnedSelves.removeLast()
            }
        }
    }
}

private extension CallSiteScanner.Visitor {
    /// The names a generic parameter clause introduces.
    static func names(_ clause: GenericParameterClauseSyntax?) -> Set<String> {
        Set(clause?.parameters.map { $0.name.identifier?.name ?? $0.name.text } ?? [])
    }

    /// Every capitalised name a where clause writes, on either side of each requirement — `[]` for a declaration without one.
    static func typeNames(in clause: GenericWhereClauseSyntax?) -> [String] {
        clause?.tokens(viewMode: .sourceAccurate).compactMap { token in
            guard case .identifier = token.tokenKind else { return nil }
            let name = token.identifier?.name ?? token.text
            return name.first?.isUppercase == true ? name : nil
        } ?? []
    }

    private func recordOperator(_ token: TokenSyntax, at node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
        if let shape = names[token.text], shape != .typeUse, shape != .initializer {
            // At the operator's own column, where the store records its call, so a call listed from the store is not listed twice.
            let location = converter.location(for: token.positionAfterSkippingLeadingTrivia)
            sites[token.text, default: []].append(site(at: node, arguments: nil, operatorAt: "\(location.line):\(location.column)"))
        }
        return .visitChildren
    }

    /// Whether a name is what a call calls — `f` in `f(x)`, `x.f(y)` or `f<T>()` — which the call's own visit records.
    private static func isCallee(_ node: DeclReferenceExprSyntax) -> Bool {
        var callee = Syntax(node)
        if let member = node.parent?.as(MemberAccessExprSyntax.self), member.declName.id == node.id {
            callee = Syntax(member)
        }
        if let generic = callee.parent?.as(GenericSpecializationExprSyntax.self) {
            callee = Syntax(generic)
        }
        return callee.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id == callee.id
    }

    /// Records a call of the type `Self` names — `Self(x)`, `Self.init call`, `self.init call` — as one of the innermost type around it, an extension's being the extended type's.
    ///
    /// In an extension whose where clause pins `Self` to another type, `Self` is that type, so the call is its alone, never the extended type's: the index store records it as the pinned type's initializer, not the protocol's requirement.
    ///
    /// Otherwise, where `untold`, in an extension of a type this file does not declare as a struct, class, enum or actor, `Self` may be a protocol's conforming type, which the scan cannot tell: the call is held until the walk has seen every declaration in the file, then counted for every type asked, as an implicit `.init call` is. A pin to a type no asked one is held the same way, for every type asked but the extended one, and dropped only where this file declares that type as a struct, class, enum or actor: the name may be a typealias of an asked type, or one declared in another file. A `self.init call` is not held: an initializer delegating in an extension of a type declared in another file is common, and counted for every type it would bury the list.
    func recordOnSelf(at node: some SyntaxProtocol, arguments: WrittenArguments?, untold: Bool = true) {
        guard let type = enclosingTypes.last else { return }
        let pinned = pinnedSelves.last.flatMap(\.self).flatMap { $0 == type ? nil : $0 }
        let selfType = pinned ?? type
        if names[selfType] == .initializer {
            record(selfType, at: node, arguments: arguments)
        } else if untold, let innermost = constraints.last, innermost != nil {
            selfCallsInExtensions.append(CallSiteScanner.HeldSelfCall(selfType: selfType, notFor: pinned.map { _ in type }, site: site(at: node, arguments: arguments, nameOnly: true, callsUntoldSelf: true)))
        }
    }

    /// The simple name of the type a declaration states an implicit `.init call` makes, with the path it is written under — `Outer` for `let b: Outer.Box = .init call`, or one returned from a function, a computed property or a subscript declared as one — or `nil` where none states it.
    ///
    /// The call may sit under `try`, `await`, a force unwrap or parentheses, and be an element of an array literal whose declared type is an array of the type.
    private func impliedType(of call: Syntax) -> (name: String, qualifier: String?)? {
        var node = call
        var elementDepth = 0
        while let parent = node.parent {
            if parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self) || parent.is(ForceUnwrapExprSyntax.self) {
                node = parent
            } else if let element = parent.as(LabeledExprSyntax.self), element.label == nil,
                      let tuple = element.parent?.parent?.as(TupleExprSyntax.self), tuple.elements.count == 1
            {
                node = Syntax(tuple)
            } else if parent.is(ArrayElementSyntax.self), let array = parent.parent?.parent?.as(ArrayExprSyntax.self) {
                node = Syntax(array)
                elementDepth += 1
            } else {
                break
            }
        }
        guard let type = declaredType(around: node).flatMap({ unwrapped($0, elementDepth: elementDepth) }) else { return nil }
        let name = DeclaredTypeName.of(type)
        guard name != "Self" else { return enclosingTypes.last.map { ($0, nil) } }
        return (name, type.as(MemberTypeSyntax.self).flatMap { DeclaredTypeName.path(of: $0.baseType) })
    }

    /// The type the binding `node` initializes is annotated with, or that the function, computed property or subscript returning `node` declares.
    private func declaredType(around node: Syntax) -> TypeSyntax? {
        if let binding = node.parent?.as(InitializerClauseSyntax.self)?.parent?.as(PatternBindingSyntax.self) {
            return binding.typeAnnotation?.type
        }
        let isReturned = node.parent?.is(ReturnStmtSyntax.self) == true
            || (node.parent?.is(CodeBlockItemSyntax.self) == true && node.parent?.parent?.as(CodeBlockItemListSyntax.self)?.count == 1)
        guard isReturned else { return nil }
        var ancestor = node.parent
        while let current = ancestor {
            if let function = current.as(FunctionDeclSyntax.self) {
                return function.signature.returnClause?.type
            }
            if let subscriptDecl = current.as(SubscriptDeclSyntax.self) {
                return subscriptDecl.returnClause.type
            }
            if let binding = current.as(PatternBindingSyntax.self) {
                return binding.typeAnnotation?.type
            }
            if current.is(ClosureExprSyntax.self) || (current.is(DeclSyntax.self) && !current.is(AccessorDeclSyntax.self)) {
                return nil
            }
            ancestor = current.parent
        }
        return nil
    }

    /// The declared type an implicit member is looked up in — an optional's wrapped type — taken `elementDepth` array elements in, or `nil` where it is no array that deep.
    private func unwrapped(_ type: TypeSyntax, elementDepth: Int) -> TypeSyntax? {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return unwrapped(optional.wrappedType, elementDepth: elementDepth)
        }
        if elementDepth > 0 {
            return type.as(ArrayTypeSyntax.self).flatMap { unwrapped($0.element, elementDepth: elementDepth - 1) }
        }
        return type
    }

    /// Whether `node` is a leading-dot call `.m(x)`, or the name such a call calls, with nothing applied after it: no member, call, subscript, `?` or `!`.
    ///
    /// Implicit member lookup finds `.m` on the contextual type, and the expression must end in that type. An instance method found that way is the unapplied `T.m`, so `.m(t)` is only given its instance and yields a function — `.m(t)(1)` is a real call of it, and parentheses end an implicit member chain, so only the call's own parent can continue it.
    static func isUnchainedImplicitMemberCall(_ node: Syntax) -> Bool {
        var call = node.as(FunctionCallExprSyntax.self)
        if let reference = node.as(DeclReferenceExprSyntax.self),
           let member = reference.parent?.as(MemberAccessExprSyntax.self), member.declName.id == reference.id
        {
            let callee = member.parent?.as(GenericSpecializationExprSyntax.self).map(Syntax.init) ?? Syntax(member)
            call = callee.parent?.as(FunctionCallExprSyntax.self).flatMap { $0.calledExpression.id == callee.id ? $0 : nil }
        }
        guard let call else { return false }
        let called = call.calledExpression.as(GenericSpecializationExprSyntax.self)?.expression ?? call.calledExpression
        guard let member = called.as(MemberAccessExprSyntax.self), member.base == nil, !continuesAboveIfConfig(call) else { return false }
        guard let parent = call.parent else { return true }
        if let next = parent.as(FunctionCallExprSyntax.self) {
            return next.calledExpression.id != call.id
        }
        if let next = parent.as(SubscriptCallExprSyntax.self) {
            return next.calledExpression.id != call.id
        }
        if let next = parent.as(MemberAccessExprSyntax.self) {
            return next.base?.id != call.id
        }
        return !parent.is(OptionalChainingExprSyntax.self) && !parent.is(ForceUnwrapExprSyntax.self) && !parent.is(PostfixOperatorExprSyntax.self)
    }

    /// Whether `call` sits in a postfix `#if` clause, where a leading dot continues the expression written above the `#if` rather than naming an implicit member.
    static func continuesAboveIfConfig(_ call: FunctionCallExprSyntax) -> Bool {
        var node = call.parent
        while let current = node, !current.is(CodeBlockItemSyntax.self) {
            if let clause = current.as(IfConfigClauseSyntax.self), case .postfixExpression = clause.elements {
                return true
            }
            node = current.parent
        }
        return false
    }

    /// The `line:column` of the name `call` is made through, where the index store records it, or `nil` for no call or a callee that is no name.
    func calleeAt(_ call: FunctionCallExprSyntax?) -> String? {
        guard let call else { return nil }
        let called = call.calledExpression.as(GenericSpecializationExprSyntax.self)?.expression ?? call.calledExpression
        guard let name = called.as(MemberAccessExprSyntax.self)?.declName.baseName ?? called.as(DeclReferenceExprSyntax.self)?.baseName else { return nil }
        let location = converter.location(for: name.positionAfterSkippingLeadingTrivia)
        return "\(location.line):\(location.column)"
    }

    /// The `line:column` of the type name a wrapper's `@T` attribute is written with, where the index store records the initializer call the attribute makes, or `nil` for no attribute.
    ///
    /// The name is the last component of a qualified attribute, `T` in `@M.T`, which is the one the store records.
    func calleeAt(_ attribute: AttributeSyntax?) -> String? {
        guard let type = attribute?.attributeName,
              let name = type.as(MemberTypeSyntax.self)?.name ?? type.as(IdentifierTypeSyntax.self)?.name else { return nil }
        let location = converter.location(for: name.positionAfterSkippingLeadingTrivia)
        return "\(location.line):\(location.column)"
    }

    /// Notes a labelled parameter declared with `@T` where T is asked as an initializer's type or the declaration's own name is asked, so a `$label:` call can be told apart from one of a same-named declaration's parameter declared with another wrapper.
    func noteWrappedParameter(_ parameter: FunctionParameterSyntax?, attribute node: AttributeSyntax) {
        let type = DeclaredTypeName.of(node.attributeName)
        guard let parameter, !Self.builtInAttributes.contains(type) else { return }
        let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        guard let wrapped = WrappedParameter(parameter, wrapper: type, in: enclosingTypes.last, path: path, line: line),
              names[type] == .initializer || names[wrapped.callee] != nil else { return }
        wrappedParameters[type, default: []].append(wrapped)
    }
}

/// Whether a base identifier spelled like a type is shadowed by a local `let`/`var`, an `if`/`guard`/`while let`, or a closure or function parameter of the same name, making it a value rather than the type it is spelled like.
private extension CallSiteScanner {
    /// A `Self` call written in an extension of a type no asked one, held until the walk has seen every declaration in its file.
    struct HeldSelfCall {
        /// The type `Self` is written as there: the type the where clause pins `Self` to, or else the type extended.
        let selfType: String
        /// Where pinned, the type extended, whose call it is not.
        let notFor: String?
        let site: SyntacticCallSite
    }

    struct LocalBindingShadow {
        /// Whether `name` is bound in a scope enclosing `node`, written before it — a plain binding, an optional one, or a parameter.
        static func hides(_ name: String, before node: some SyntaxProtocol) -> Bool {
            let position = node.positionAfterSkippingLeadingTrivia
            var current = Syntax(node)
            while let ancestor = current.parent {
                if parameterNames(of: ancestor).contains(name) {
                    return true
                }
                if let items = ancestor.as(CodeBlockItemListSyntax.self), binds(name, before: position, in: items) {
                    return true
                }
                current = ancestor
            }
            return false
        }

        /// The names a function, initializer or closure declares as parameters, its own body a scope where they shadow a type of the same spelling.
        private static func parameterNames(of node: Syntax) -> Set<String> {
            let parameters: [FunctionParameterSyntax] = if let function = node.as(FunctionDeclSyntax.self) {
                Array(function.signature.parameterClause.parameters)
            } else if let initializer = node.as(InitializerDeclSyntax.self) {
                Array(initializer.signature.parameterClause.parameters)
            } else {
                []
            }
            var names = Set(parameters.compactMap { parameterName(firstName: $0.firstName, secondName: $0.secondName) })
            if let closure = node.as(ClosureExprSyntax.self), case let .parameterClause(clause) = closure.signature?.parameterClause {
                names.formUnion(clause.parameters.compactMap { parameterName(firstName: $0.firstName, secondName: $0.secondName) })
            }
            return names
        }

        private static func parameterName(firstName: TokenSyntax, secondName: TokenSyntax?) -> String? {
            let token = secondName ?? firstName
            guard token.tokenKind != .wildcard else { return nil }
            return token.identifier?.name ?? token.text
        }

        /// Whether an item earlier in the same block binds `name` — a plain `let`/`var` or a `guard` for the rest of the block, an `if`/`while` only for the item it heads, which holds its body.
        private static func binds(_ name: String, before position: AbsolutePosition, in items: CodeBlockItemListSyntax) -> Bool {
            for item in items where item.positionAfterSkippingLeadingTrivia < position {
                let encloses = item.endPositionBeforeTrailingTrivia > position
                if let variable = item.item.as(VariableDeclSyntax.self),
                   variable.bindings.contains(where: { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name })
                {
                    return true
                }
                if let guardStmt = item.item.as(GuardStmtSyntax.self), optionalBindingConditions(guardStmt.conditions).contains(name) {
                    return true
                }
                if encloses, let ifExpr = item.item.as(ExpressionStmtSyntax.self)?.expression.as(IfExprSyntax.self) ?? item.item.as(IfExprSyntax.self), optionalBindingConditions(ifExpr.conditions).contains(name) {
                    return true
                }
                if encloses, let whileStmt = item.item.as(WhileStmtSyntax.self), optionalBindingConditions(whileStmt.conditions).contains(name) {
                    return true
                }
            }
            return false
        }

        private static func optionalBindingConditions(_ conditions: ConditionElementListSyntax) -> Set<String> {
            Set(conditions.compactMap {
                guard case let .optionalBinding(binding) = $0.condition else { return nil }
                return binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            })
        }
    }
}
