//
// Copyright © Agulhas Labs
//

import Foundation
import SwiftParser
import SwiftSyntax

/// Whether a nested type's name written bare where no type is around it can be no use of the type.
///
/// Swift finds a type nested in another, `Net.URL`, by its bare name only inside that type, its extensions, the types nested in them and its subtypes, so `URL` written where no type, extension or protocol is around it means another declaration of the name, Foundation's say. Such a line is set apart only where nothing else can make the name mean the nested type there: every type asked for is nested in another, no body around the line declares the name or holds a freestanding macro or a custom attribute that may, the file binds no value of the name and imports no declaration or module of it, the index holds no top-level typealias, function, variable or macro of the name and declares no macro that may introduce it, and no file holds a freestanding macro or a declaration carrying a custom attribute at file scope, other than an SDK macro, attached or `#Preview`, its imports bring in that declares no such name, whose expansion, an attached peer macro's from another package say, the index never reads.
struct BareNameOutsideTypes {
    /// `site`, a type use writing `name` at `node`, marked as written bare outside every type where no body around it declares the name or may.
    static func marking(_ site: SyntacticCallSite, writing name: String, at node: some SyntaxProtocol) -> SyntacticCallSite {
        var marked = site
        marked.writtenOutsideTypes = site.qualifier == nil && isOutsideTypes(name, at: node)
        return marked
    }

    /// One file's `sites` by name, unmarked under each name the file binds as a value, which an expression writing it may mean, or imports a declaration or module of.
    static func unmarking(_ sites: [String: [SyntacticCallSite]], in tree: SourceFileSyntax, boundAsValues values: Set<String>) -> [String: [SyntacticCallSite]] {
        let imported = Set(fileScopeItems(of: tree).compactMap { $0.as(ImportDeclSyntax.self)?.path.last.map { $0.name.identifier?.name ?? $0.name.text } })
        var unmarked = sites
        for name in values.union(imported) where unmarked[name] != nil {
            unmarked[name] = unmarked[name]?.map { site in
                var kept = site
                kept.writtenOutsideTypes = false
                return kept
            }
        }
        return unmarked
    }

    /// Whether a line writing `name` bare outside every type is no use of any of `asked`, by what the index holds: each is a struct, class, enum, actor or protocol nested in another declaration, and nothing at the top level or any macro may make the name another name for one of them.
    static func setsApart(_ name: String, asked: [SymbolRow], store: IndexStore) throws -> Bool {
        guard !asked.isEmpty, asked.allSatisfy({ $0.kind.isTypeDeclaration && $0.parentID != nil }) else { return false }
        let topLevelKinds: Set<SymbolKind> = [.typealiasKind, .function, .variable, .macro]
        guard try !store.symbols(named: name).contains(where: { $0.parentID == nil && topLevelKinds.contains($0.kind) }) else { return false }
        // A macro introducing a name at file scope must name it in its declaration.
        return try !store.everyMacro().contains { mayIntroduce(name, signature: $0.signature) }
    }

    /// Whether any of `paths` under `root` holds, at file scope, a freestanding macro or a declaration carrying an attribute the language does not define and no SDK module the file imports brings in as a macro declaring no such name, whose expansion may declare any name the macro's declaration names, which the index cannot see when the macro is another package's.
    ///
    /// An SDK macro is told by its spelling under a whole-module import outside every `#if` or in the macro's own `#if` clause or one enclosing it; `@Observable` and `@Model` only without an argument list, and `@Test`, `@Suite` and `#Preview` only while no file declares a macro of their name. A same-name macro in a third-party package the file also imports, which the index never reads, is not told apart: an accepted gap.
    ///
    /// The files are read `width` at a time, and no more are started once one holds such a macro; the answer is the same in whatever order they finish, and a scan cancelled before it has read every file answers that one may.
    static func expandsAtFileScope(paths: [String], under root: URL, width: Int = ProcessInfo.processInfo.activeProcessorCount) async -> Bool {
        let rootPath = root.path
        var declared = Set<String>()
        var written = Set<String>()
        var expands = false
        await withTaskGroup(of: FileScopeReading.self) { group in
            var iterator = paths.makeIterator()
            var inFlight = 0
            while inFlight < max(1, width), let path = iterator.next() {
                group.addTask { reading(at: path, rootPath: rootPath) }
                inFlight += 1
            }
            for await found in group {
                if found.expands {
                    expands = true
                    group.cancelAll()
                    return
                }
                declared.formUnion(found.declared)
                written.formUnion(found.written)
                if let path = iterator.next() {
                    group.addTask { reading(at: path, rootPath: rootPath) }
                }
            }
        }
        return expands || !written.intersection(AttributeScanner.macrosTakingArguments).isDisjoint(with: declared)
    }
}

private extension BareNameOutsideTypes {
    static let directives: Set<Substring> = ["if", "elseif", "else", "endif", "sourceLocation"]

    /// What one file holds at file scope for the scan of every file: whether a macro there may declare any name, and the macros it declares and writes.
    struct FileScopeReading {
        var expands = false
        var declared = Set<String>()
        var written = Set<String>()
    }

    /// The file at `path` under `rootPath`, read and parsed on its own, its tree gone before it returns; a file that cannot be read holds nothing, and one read after the scan was cancelled is taken to expand.
    static func reading(at path: String, rootPath: String) -> FileScopeReading {
        guard !Task.isCancelled else { return FileScopeReading(expands: true) }
        // A macro's declaration always writes its definition, `= #externalMacro(…)` say, so the cheap test never skips a file declaring one.
        guard let data = FileManager.default.contents(atPath: rootPath + "/" + path), let source = String(data: data, encoding: .utf8),
              mayExpandOrAttach(source, builtins: AttributeScanner.nonIntroducingAttributes(importing: [])) else { return FileScopeReading() }
        let tree = Parser.parse(source: source)
        let scoped = scopedItems(tree.statements.map { Syntax($0.item) }, inherited: [])
        let argumentless = AttributeScanner.argumentlessMacros
        let expands = scoped.contains { item, modules in
            if let name = freestandingName(item), !AttributeScanner.nonIntroducingFreestandingMacros(importing: modules).contains(name) {
                return true
            }
            let known = AttributeScanner.nonIntroducingAttributes(importing: modules)
            return LocalTypeShadow.carriesCustomAttribute(item, known: known, argumentless: argumentless)
        }
        guard !expands else { return FileScopeReading(expands: true) }
        let items = scoped.map(\.item)
        return FileScopeReading(
            declared: Set(items.compactMap { $0.as(MacroDeclSyntax.self).map { $0.name.identifier?.name ?? $0.name.text } }),
            written: Set(items.flatMap(macroNames))
        )
    }

    /// Whether `name`, written bare at `node`, has no type, extension, protocol or attribute around it, and no body around it declares the name or holds anything that may.
    static func isOutsideTypes(_ name: String, at node: some SyntaxProtocol) -> Bool {
        for ancestor in sequence(first: Syntax(node), next: \.parent).dropFirst() {
            if ancestor.isProtocol(DeclGroupSyntax.self) || ancestor.is(AttributeSyntax.self) {
                return false
            }
            if ancestor.is(SourceFileSyntax.self) {
                return true
            }
            guard let list = ancestor.as(CodeBlockItemListSyntax.self), list.parent?.is(SourceFileSyntax.self) != true else { continue }
            let conditional = list.parent?.is(IfConfigClauseSyntax.self) == true
            guard LocalTypeShadow.reading(of: name, in: list.map { Syntax($0.item) }, conditional: conditional) == .silent else { return false }
        }
        return false
    }

    /// The name of the freestanding macro `item` expands, written as a declaration or, at file scope, as an expression, or `nil` when it is neither.
    static func freestandingName(_ item: Syntax) -> String? {
        item.as(MacroExpansionDeclSyntax.self)?.macroName.text ?? item.as(MacroExpansionExprSyntax.self)?.macroName.text
    }

    /// The names of the freestanding macro `item` expands and of the attributes written on it.
    static func macroNames(_ item: Syntax) -> [String] {
        let attributes = item.asProtocol(WithAttributesSyntax.self)?.attributes.compactMap { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription } ?? []
        return attributes + [freestandingName(item)].compactMap(\.self)
    }

    /// The file's top-level items, those inside its `#if` clauses included, each with the modules whose import counts for it.
    ///
    /// An import counts for an item in its own list, before or after it, and in every clause nested inside that list, never for a sibling clause of the `#if` it sits in nor for an item outside that `#if`. An import naming a kind, `import struct SwiftUI.Text`, brings in that one declaration, and counts for nothing; a module is named by the first component of its path.
    static func scopedItems(_ items: [Syntax], inherited: Set<String>) -> [(item: Syntax, modules: Set<String>)] {
        let modules = inherited.union(items.compactMap { item -> String? in
            guard let decl = item.as(ImportDeclSyntax.self), decl.importKindSpecifier == nil, let first = decl.path.first else { return nil }
            return first.name.identifier?.name ?? first.name.text
        })
        return items.flatMap { item -> [(item: Syntax, modules: Set<String>)] in
            guard let config = item.as(IfConfigDeclSyntax.self) else { return [(item, modules)] }
            return config.clauses.flatMap { clause -> [(item: Syntax, modules: Set<String>)] in
                switch clause.elements {
                case let .statements(list): scopedItems(list.map { Syntax($0.item) }, inherited: modules)
                case let .decls(list): scopedItems(list.map { Syntax($0.decl) }, inherited: modules)
                default: []
                }
            }
        }
    }

    /// The file's top-level items, those inside its top-level `#if` clauses included.
    static func fileScopeItems(of tree: SourceFileSyntax) -> [Syntax] {
        flattened(tree.statements.map { Syntax($0.item) })
    }

    static func flattened(_ items: [Syntax]) -> [Syntax] {
        items.flatMap { item -> [Syntax] in
            guard let config = item.as(IfConfigDeclSyntax.self) else { return [item] }
            return config.clauses.flatMap { clause -> [Syntax] in
                switch clause.elements {
                case let .statements(list): flattened(list.map { Syntax($0.item) })
                case let .decls(list): flattened(list.map { Syntax($0.decl) })
                default: []
                }
            }
        }
    }

    /// Whether `source` writes a `#` followed by a name other than a compiler directive's, or an `@` followed by anything but the name of one of `builtins`, the language's own attributes: the cheap test before a parse.
    static func mayExpandOrAttach(_ source: String, builtins: Set<String>) -> Bool {
        words(after: "#", in: source).contains { $0.first.map { $0.isLetter || $0 == "_" } == true && !directives.contains($0) }
            || words(after: "@", in: source).contains { !builtins.contains(String($0)) }
    }

    /// The word, maybe empty, written right after each `marker` in `source`.
    static func words(after marker: Character, in source: String) -> some Sequence<Substring> {
        source.split(separator: marker, omittingEmptySubsequences: false).dropFirst().lazy.map { $0.prefix { $0.isLetter || $0.isNumber || $0 == "_" } }
    }

    /// Whether a macro declared as `signature` may introduce `name`: its names name it, however spaced, commented or escaped, or say names it cannot spell ahead.
    static func mayIntroduce(_ name: String, signature: String) -> Bool {
        let tokens = Array(Parser.parse(source: signature).tokens(viewMode: .sourceAccurate))
        return tokens.indices.contains { index in
            let word = tokens[index].text
            if ["arbitrary", "overloaded", "prefixed", "suffixed"].contains(word) {
                return true
            }
            guard word == "named", index + 2 < tokens.count, tokens[index + 1].tokenKind == .leftParen else { return false }
            let named = tokens[index + 2]
            return (named.identifier?.name ?? named.text) == name
        }
    }
}
