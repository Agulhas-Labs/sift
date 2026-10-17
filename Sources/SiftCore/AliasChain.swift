//
// Copyright © Agulhas Labs
//

import SwiftParser
import SwiftSyntax

/// The typealiases that are another name for the asked types, followed through aliases of aliases, as the store's fold follows them.
///
/// An alias whose right-hand side is a plain name or member path is another name for the type, so its line is counted apart. One that builds a type from the name — through generic arguments, a tuple, an optional or a function type, or as a generic alias — is followed by every whole path it writes, generic arguments included, never a member path's base alone and never one led by its own generic parameter: its uses break with the type, so they are the type's, but its line stays a use, since it is no other name for the type.
struct AliasChain {
    private(set) var aliases: [Alias] = []
    private(set) var reachedCap = false
    /// The paths the aliases were folded against: the asked types', the extensions followed beside them, and every alias's.
    private var paths: [WrittenPath] = []

    init() {}

    /// How a function-local typealias writing `target` names the asked types, through any path the chain followed, a proven reading first, or `nil` where it names none of them.
    func fold(ofLocal target: String, atTopLevel: Bool) -> WrittenPath.Fold? {
        let folds = paths.compactMap { $0.fold(of: target, atTopLevel: atTopLevel) }
        return folds.first { $0 == .proven } ?? folds.first
    }

    /// The aliases naming `rows`, where one declared at the top level names a type only by writing its whole path, with or without its module.
    ///
    /// Unqualified lookup at the top level never sees a type nested in another, so a shorter path there names some other type. An alias declared in a type or an extension may name a type nested beside it by any trailing part of its path. One writing the whole path behind a leading name that may be the type's module is kept, unproven, and so is every alias of it.
    ///
    /// `source` reads a repo-relative file as it stands, which tells which copy of a type declared once per `#if` clause a nested alias is written in; without it every copy's declarations are read as the alias's own.
    init(of rows: [SymbolRow], among typealiases: [SymbolRow], store: IndexStore, guessedModules: [String: GuessedModuleNotice.Reason], source: ((String) -> String?)? = nil) throws {
        let written = typealiases.compactMap { alias -> Written? in
            if let target = Self.aliasedPath(of: alias) {
                return Written(row: alias, targets: [target], built: false)
            }
            let paths = Self.builtPaths(of: alias)
            return paths.isEmpty ? nil : Written(row: alias, targets: paths, built: true)
        }
        var seen = Set(rows.map(\.id))
        var frontier = try rows.map { row in try WrittenPath(of: row, store: store, guessedModules: guessedModules, reachedThrough: nil) }
        var folded = 0
        // An extension of a declared type's bare name that may extend some other type of the name is a path of its own, though the answer counts it as that type's.
        // So is a dotted one (`extension Foundation.JSONDecoder`) beside a type or typealias of the name the bare query found: the one asked may be private, conditional, nested or another name for some other type, and the extension another's.
        // An alias the declaration's own path proves is folded in through that path whatever an extension of it reads as.
        for row in rows where row.kind.isTypeDeclaration || row.kind == .typealiasKind {
            for written in try ExtensionPaths.written(endingIn: row.name, in: store) where !seen.contains(written.row.id) {
                seen.insert(written.row.id)
                let path = try WrittenPath(of: written.row, store: store, guessedModules: guessedModules, reachedThrough: nil, mayExtendAnother: written.path != row.name)
                if path.unknownModule == .extendedOnly || path.mayExtendAnother {
                    frontier.append(path)
                }
            }
        }
        while !frontier.isEmpty {
            paths += frontier
            var next: [WrittenPath] = []
            // A round's scopes take every declaration the chain has followed so far as the name's own, so one an alias reached this round shadows nothing it names.
            var scopes: [String: AliasNameScope] = [:]
            for alias in written where !seen.contains(alias.row.id) {
                let folds = try scopedFolds(of: alias, against: frontier, store: store, source: source, scopes: &scopes)
                guard let first = folds.first else { continue }
                let proven = folds.first { $0.fold == .proven }
                let unproven = proven == nil ? first.fold.unproven : nil
                // Only a folded alias counts against the cap, so a kept one never crowds a proven one out; a kept one is followed whatever the count, since its uses are listed rather than counted apart, and no use may leave the answer.
                if unproven == nil {
                    guard folded < WhereRenderer.typealiasFoldCap else {
                        reachedCap = true
                        continue
                    }
                    folded += 1
                }
                seen.insert(alias.row.id)
                aliases.append(Alias(row: alias.row, target: (proven ?? first).target, unproven: unproven, ofKept: unproven != nil && folds.allSatisfy(\.fold.throughKept), built: alias.built))
                try next.append(WrittenPath(of: alias.row, store: store, guessedModules: guessedModules, reachedThrough: unproven))
            }
            frontier = next
        }
    }

    /// How `alias` names each path of `frontier`, where one declared in a type writing a bare name that a type or typealias of the path declares reads it from its own scope.
    ///
    /// Swift looks the name up from the alias's position, so a nearer declaration of it hides the chain's: the fold stands where the lookup reaches only the chain's declarations of the name, is dropped where a nearer one certainly shadows them, and is kept where the scope cannot tell. An extension's path is followed as it is.
    private func scopedFolds(of alias: Written, against frontier: [WrittenPath], store: IndexStore, source: ((String) -> String?)?, scopes: inout [String: AliasNameScope]) throws -> [(fold: WrittenPath.Fold, target: String)] {
        var folds: [(fold: WrittenPath.Fold, target: String)] = []
        var parents: [String]?
        for path in frontier {
            for target in alias.targets {
                guard var fold = path.fold(of: target, atTopLevel: alias.row.parentID == nil) else { continue }
                if alias.row.parentID != nil, !target.contains("."), Self.declares(target, path.row) {
                    if scopes[target] == nil {
                        scopes[target] = try AliasNameScope(store: store, name: target, aliases: paths.map(\.row).filter { Self.declares(target, $0) }, reachedCap: false, source: source)
                    }
                    let enclosing = try parents ?? QualifiedPath.flattened(chain: store.parentChain(of: alias.row).map(\.name))
                    parents = enclosing
                    // A fold through a declaration of the name the lookup does not reach is dropped, so a farther proven one never stands in for a nearer kept one.
                    switch try scopes[target]?.reach(writtenIn: enclosing, from: (alias.row.module, alias.row.path), at: source == nil ? nil : (alias.row.path, alias.row.line)) {
                    case let .aliases(reached) where !reached.contains(path.row.id): continue
                    case .another: continue
                    case .undecided where fold == .proven: fold = .kept(.sharesNameWithAnother, throughKept: false)
                    default: break
                    }
                }
                folds.append((fold, target))
            }
        }
        return folds
    }

    /// Whether `row` is a type or typealias declared by the name `name`.
    private static func declares(_ name: String, _ row: SymbolRow) -> Bool {
        row.name == name && (row.kind.isTypeDeclaration || row.kind == .typealiasKind)
    }

    /// The dotted path `alias` is another name for, or `nil` where it is generic or its right-hand side is anything but a plain name or member path.
    private static func aliasedPath(of alias: SymbolRow) -> String? {
        guard !alias.signature.contains("<") else { return nil }
        return SameNamedTypes.Resolver.target(of: alias)
    }

    /// Every whole dotted path the right-hand side of `alias` writes, generic arguments followed in, leaving out any led by the alias's own generic parameters, or none where it does not parse as a typealias.
    private static func builtPaths(of alias: SymbolRow) -> [String] {
        NestingGate.parseOrEmpty(alias.signature) { tree in
            guard let declaration = tree.statements.first.flatMap({ Syntax($0.item).as(TypeAliasDeclSyntax.self) }), !declaration.hasError else { return [] }
            let parameters = Set(declaration.genericParameterClause?.parameters.map(\.name.text) ?? [])
            return writtenPaths(in: Syntax(declaration.initializer.value)).filter { !parameters.contains(String($0.prefix { $0 != "." })) }
        }
    }

    /// The dotted path of the type a call through `alias` builds, generic arguments set aside — `Gizmo` for `typealias Box<T> = Gizmo` or `typealias Crate = Gizmo<Int>` — or `nil` where its right-hand side is sugar such as `[Gizmo]` or `Gizmo?`, or anything but a name or member path.
    static func calledPath(of alias: SymbolRow) -> String? {
        NestingGate.parseOrEmpty(alias.signature) { tree in
            guard let declaration = tree.statements.first.flatMap({ Syntax($0.item).as(TypeAliasDeclSyntax.self) }), !declaration.hasError else { return nil }
            return DeclaredTypeName.path(of: declaration.initializer.value)
        }
    }

    /// The whole dotted paths written in `node`: a member path as one, never its base alone, and the generic arguments at every level of it.
    private static func writtenPaths(in node: Syntax) -> [String] {
        guard let type = node.as(TypeSyntax.self), let path = DeclaredTypeName.path(of: type) else {
            return node.children(viewMode: .sourceAccurate).flatMap(writtenPaths)
        }
        var arguments: [Syntax] = []
        var level: TypeSyntax? = type
        while let current = level {
            let member = current.as(MemberTypeSyntax.self)
            let clause = member?.genericArgumentClause ?? current.as(IdentifierTypeSyntax.self)?.genericArgumentClause
            arguments += clause.map { [Syntax($0)] } ?? []
            level = member?.baseType
        }
        return [path] + arguments.flatMap(writtenPaths)
    }
}

extension AliasChain {
    /// Why a typealias is kept as another name for a type rather than folded in as one: the leading name its right-hand side writes before the type's whole path may be the type's module, and nothing in the tree says whether it is.
    enum Unproven: Hashable {
        case guessedModule
        /// The type's module is the target's name, kept as a guess because the build renames it through a setting this tool cannot read.
        case renamedModule
        /// The path starts at an extension by a bare name that no type its module visibly declares is proven to be, so which module's type it extends goes unsaid.
        case extendedOnly
        /// The path starts at a dotted extension whose leading name the tree declares no type of, and the alias writes the path without it: that name may be a type of another module (`extension UIView.ContentMode`) rather than the module the alias would have to be reading it past.
        case leadingNameMayBeAType
        /// The path starts at a dotted extension beside the type asked, which may extend another type of the name than that one.
        case extendsAnotherOfTheName
        /// The alias's name is written where another declaration of the name may be what it means, which the scope around the use leaves unsaid.
        case sharesNameWithAnother

        /// Said after "as" in the verdict's clause.
        var reason: String {
            switch self {
            case .guessedModule: "this type's module is guessed from the path"
            case .renamedModule: "this type's module is renamed by a setting this tool cannot read"
            case .extendedOnly: "its path starts at an extension of a type its module does not visibly declare, whose module is unknown"
            case .extendsAnotherOfTheName: "its path starts at a dotted extension that may extend another type of the name than the one asked"
            case .leadingNameMayBeAType: "it writes the path of a dotted extension without its leading name, which may be a type rather than a module"
            case .sharesNameWithAnother: "the name may mean that other declaration where it is written"
            }
        }
    }

    /// A typealias of the asked types, the dotted path it writes, and why it is only kept, or `nil` where it provably names them.
    struct Alias {
        let row: SymbolRow
        let target: String
        let unproven: Unproven?
        /// Whether it is kept only because what it writes is an alias kept itself, rather than the type's path behind a leading name.
        let ofKept: Bool
        /// Whether its right-hand side builds a type from the name rather than naming it, so `target` is only the path in it that folded.
        let built: Bool
    }

    /// A typealias and the paths its right-hand side writes: the one path it names, or every whole path in the type it builds.
    private struct Written {
        let row: SymbolRow
        let targets: [String]
        let built: Bool
    }

    /// How the uses written through typealiases of one name are counted: folded in under the aliases' qualified names, or kept, naming every alias of the name, where one of them is not proven to name the type.
    enum Spelling {
        case folded(String)
        case kept(Set<KeptSpelling>, because: Unproven)
    }

    /// How the uses of the name the aliases in `named` share are counted: a scan by name cannot tell which alias of the name a use writes, so one kept alias of it keeps every use of the name, named with each alias of it; otherwise they fold in.
    static func spelling(of named: [Alias], qualifiedName: (SymbolRow) throws -> String) throws -> Spelling {
        if let unproven = named.compactMap(\.unproven).first {
            return try .kept(Set(named.map { try KeptSpelling(of: $0, qualifiedName: qualifiedName($0.row)) }), because: unproven)
        }
        return try .folded(named.map { try qualifiedName($0.row) }.sorted().joined(separator: " or "))
    }

    /// `spelling` for a use where the name may mean another declaration than the aliases in `named`: a folded one kept, naming each of them, since nothing proves the use means them; a kept one as it is.
    static func sharedWithAnother(_ spelling: Spelling, of named: [Alias], qualifiedName: (SymbolRow) throws -> String) throws -> Spelling {
        guard case .folded = spelling else { return spelling }
        return try .kept(Set(named.map { try KeptSpelling(text: qualifiedName($0.row), kind: .sharingNameWithAnother) }), because: .sharesNameWithAnother)
    }

    /// A typealias named in the clause of kept uses, with what it is.
    struct KeptSpelling: Hashable {
        let text: String
        let kind: Kind

        /// `alias` as the clause names it: a kept one with the path it writes, a proven one by its name alone.
        init(of alias: Alias, qualifiedName: String) {
            guard alias.unproven != nil else {
                text = qualifiedName
                kind = .sharingNameWithKept
                return
            }
            text = "\(qualifiedName) (\(alias.target))"
            if alias.ofKept {
                kind = .aliasOfKept
            } else {
                kind = alias.unproven == .sharesNameWithAnother ? .writingSharedName : .behindLeadingName
            }
        }

        /// An alias the index holds no row of, named as `text`.
        init(text: String, kind: Kind) {
            self.text = text
            self.kind = kind
        }
    }

    /// A declaration's path as written, and the whole paths a top-level alias may name it by without its module, or `nil` where a qualifier in the path cannot be accounted for.
    struct WrittenPath {
        let row: SymbolRow
        let path: String
        let module: String
        let wholePaths: [String]?
        /// Why a whole path behind a leading name other than `module` may still name this declaration, or `nil` where the module is known.
        let unknownModule: Unproven?
        /// Why this declaration, an alias, is itself only kept, so that every alias of it is too.
        let reachedThrough: Unproven?
        /// The path of a dotted extension as written and with its leading name dropped, where the tree declares no top-level type of that name: a target that is a trailing part of the second and not of the first reads the leading name as a module, which nothing proves.
        let droppedLeading: (written: String, rest: String)?
        /// Whether this is a dotted extension found beside a type of its final name, which may extend another type than that one, so no alias is proven to name the type asked through it.
        let mayExtendAnother: Bool

        /// The path of `row` through its containers, where an extension's name is the path its declaration wrote.
        ///
        /// The outermost name may be an extension's, whose leading component may be a module (`extension Lib.Net`, `extension Foundation.JSONDecoder`): it is dropped as one unless the tree declares a top-level type of that name. A dotted name further in is no declaration Swift allows, so the path is taken as unaccounted for.
        init(of row: SymbolRow, store: IndexStore, guessedModules: [String: GuessedModuleNotice.Reason], reachedThrough: Unproven?, mayExtendAnother: Bool = false) throws {
            self.row = row
            self.mayExtendAnother = mayExtendAnother
            let chain = try store.parentChain(of: row) + [row]
            // An extension's generic arguments are no part of the path it extends, so `extension Shelf.Box<Int>` is read as `Shelf.Box`.
            let names = chain.map { Self.extendedPath(of: $0) }
            module = row.module
            path = ([module] + names).joined(separator: ".")
            unknownModule = try Self.extendsUnseenType(chain[0], in: store) ? .extendedOnly : guessedModules[row.path].map { $0 == .unreadableRename ? .renamedModule : .guessedModule }
            self.reachedThrough = reachedThrough
            let inner = names.dropFirst()
            guard let outermost = names.first, !inner.contains(where: { $0.contains(".") }) else {
                wholePaths = nil
                droppedLeading = nil
                return
            }
            let written = ([outermost] + inner).joined(separator: ".")
            var paths = [written]
            var dropped: (written: String, rest: String)?
            if let dot = outermost.firstIndex(of: "."), try !Self.declaresTopLevelType(named: String(outermost[..<dot]), in: store) {
                let rest = ([String(outermost[outermost.index(after: dot)...])] + inner).joined(separator: ".")
                paths.append(rest)
                dropped = (written, rest)
            }
            wholePaths = paths
            droppedLeading = dropped
        }

        /// How `alias`, writing `target`, names this declaration, or `nil` where it does not: proven where it is declared at the top level and writes a whole path, with or without the module, or is declared elsewhere and writes any trailing part of the path where a qualifier in it is unaccounted for; kept where it writes a whole path behind one leading name that may be the module, or where this declaration is an alias only kept itself.
        func fold(of target: String, atTopLevel: Bool) -> Fold? {
            if mayExtendAnother, relyOnDroppedLeading(target) || isNamed(by: target, atTopLevel: atTopLevel) {
                return .kept(.extendsAnotherOfTheName, throughKept: false)
            }
            if relyOnDroppedLeading(target) {
                return .kept(reachedThrough ?? .leadingNameMayBeAType, throughKept: reachedThrough != nil)
            }
            if isNamed(by: target, atTopLevel: atTopLevel) {
                return reachedThrough.map { .kept($0, throughKept: true) } ?? .proven
            }
            // Any leading name is kept, a type the tree declares included: that type may be invisible where the alias is written.
            guard let unknownModule, let wholePaths, let dot = target.firstIndex(of: "."),
                  wholePaths.contains(String(target[target.index(after: dot)...]))
            else { return nil }
            return .kept(reachedThrough ?? unknownModule, throughKept: reachedThrough != nil)
        }

        /// Whether an alias writing `target` names this declaration only by reading a dotted extension's leading name as a module: its target is a trailing part of the path without that name, so it never writes the name.
        private func relyOnDroppedLeading(_ target: String) -> Bool {
            guard let droppedLeading else { return false }
            return ("." + droppedLeading.rest).hasSuffix("." + target)
        }

        /// Whether an alias writing `target` provably names this declaration: one where no type is around it only by a whole path, with or without the module, or by any trailing part of the path where a qualifier in it is unaccounted for.
        private func isNamed(by target: String, atTopLevel: Bool) -> Bool {
            guard ("." + path).hasSuffix("." + target) else { return false }
            // Behind an extension of a type the tree does not declare, the module this file is in is not the extended type's, so writing it before the path proves nothing.
            guard unknownModule != .extendedOnly || target != path else { return false }
            guard atTopLevel, let wholePaths else { return true }
            return wholePaths.contains { target == $0 || target == module + "." + $0 }
        }

        /// A row's name, an extension's with its generic arguments set aside.
        private static func extendedPath(of row: SymbolRow) -> String {
            row.kind == .extensionKind && row.name.contains("<") ? DeclaredTypeName.path(ofSpelling: row.name) : row.name
        }

        private static func declaresTopLevelType(named name: String, in store: IndexStore) throws -> Bool {
            try store.symbols(named: name).contains { $0.parentID == nil && ($0.kind.isTypeDeclaration || $0.kind == .typealiasKind) }
        }

        /// Whether `outermost` is an extension written by a bare name that no type this tree declares is provably the one it extends: a top-level type of the name in the extension's module, visible beyond its file, under no `#if`.
        ///
        /// A typealias of the name is no such proof, since it names some other type.
        private static func extendsUnseenType(_ outermost: SymbolRow, in store: IndexStore) throws -> Bool {
            let name = extendedPath(of: outermost)
            guard outermost.kind == .extensionKind, !name.contains(".") else { return false }
            return try !store.symbols(named: name).contains { declared in
                declared.parentID == nil && declared.kind.isTypeDeclaration && declared.module == outermost.module
                    && declared.accessLevel >= .internalLevel && declared.ifConfigCondition == nil
            }
        }
    }
}

extension AliasChain.WrittenPath {
    /// How an alias names a declaration: by a path that proves it, or by one that is only kept.
    enum Fold: Equatable {
        case proven
        /// Kept, and why; `throughKept` where the declaration it names is itself an alias only kept.
        case kept(AliasChain.Unproven, throughKept: Bool)

        var unproven: AliasChain.Unproven? {
            guard case let .kept(unproven, _) = self else { return nil }
            return unproven
        }

        var throughKept: Bool {
            guard case let .kept(_, throughKept) = self else { return false }
            return throughKept
        }
    }
}

extension AliasChain.KeptSpelling {
    /// What a kept alias is, in the order the clause names them.
    enum Kind: CaseIterable {
        /// It writes the type's whole path behind a leading name that may be its module.
        case behindLeadingName
        /// It writes a kept alias, or a path through one, rather than the type's.
        case aliasOfKept
        /// It is proven to name the type, but a kept alias shares its name, so a use of the name may be either.
        case sharingNameWithKept
        /// It is proven to name the type, but another declaration shares its name, and the scope where a use writes it leaves which one it means unsaid.
        case sharingNameWithAnother
        /// It is declared in a type and writes a bare name another declaration shares, and the scope around it leaves which one it means unsaid.
        case writingSharedName

        /// Said after the aliases of this kind in the clause.
        func described(plural: Bool) -> String {
            switch self {
            case .behindLeadingName: "\(plural ? "typealiases" : "a typealias") of its path behind a leading name that may be its module"
            case .aliasOfKept: plural ? "aliases of kept typealiases" : "an alias of a kept typealias"
            case .sharingNameWithKept: plural ? "typealiases naming it whose names kept ones share" : "a typealias naming it whose name a kept one shares"
            case .sharingNameWithAnother: plural ? "typealiases naming it whose names other declarations share" : "a typealias naming it whose name another declaration shares"
            case .writingSharedName: plural ? "typealiases writing names other declarations share" : "a typealias writing a name another declaration shares"
            }
        }
    }
}
