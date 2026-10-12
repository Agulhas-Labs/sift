//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// Which type of the tree an extension written through a type's final name extends, as far as the code can tell: the asked type, another type of the name, or one it cannot place.
///
/// The header's path, generic arguments set aside, is read the way Swift reads it at file scope. A leading name that is a module of the tree and no type it writes is that module, so the rest of the path is that module's type; one that is neither, nor a module of the tree as the compiler spells it, but a module the extension's file imports, is that module, so the path is a type outside the tree, but only where a build file named every file's module, since a name guessed from a directory may not be the compiler's. Otherwise the path is the extension's own module's type where that module declares one, which its lookup finds before any import's; a leading name that module declares at the top level as a typealias or another type is read through that declaration and never through an import; else the path is the one type at it among the modules of the tree the extension's file imports. A path naming no type of the tree, or several through the file's imports, is not placed: it may extend a type of a module outside the tree.
struct ExtensionPlacement {
    /// The asked type's module and its path through its containers.
    let module: String
    let path: String
    private let store: IndexStore
    /// `Module.Path` of every type of the tree declared with the asked type's name.
    private let declared: Set<String>
    private let modules: Set<String>
    /// Each module of the tree as named, and as the compiler spells a name it cannot carry (`Foo-iOS` builds `Foo_iOS`).
    private let moduleSpellings: Set<String>
    /// Whether a build file declared every indexed file's module, so no module of the tree goes by a name guessed from its directory.
    private let isEveryModuleDeclared: Bool

    init(of row: SymbolRow, in store: IndexStore) throws {
        self.store = store
        module = row.module
        path = try (store.parentChain(of: row) + [row]).map(\.name).joined(separator: ".")
        var declared: Set<String> = []
        for type in try store.typeDeclarations(named: row.name) {
            try declared.insert(([type.module] + store.parentChain(of: type).map(\.name) + [type.name]).joined(separator: "."))
        }
        self.declared = declared
        modules = try Set(store.moduleNames())
        moduleSpellings = modules.union(modules.map(TestIdentifier.moduleName(ofTarget:)))
        isEveryModuleDeclared = try store.filesWithGuessedModule().isEmpty
    }

    /// Where `written` sits against the asked type.
    ///
    /// One the code cannot place is still another type's where its path is a shorter tail of the asked type's and no typealias of the tree is named as its leading name: a file-scope `extension Box` never names `Outer.Box`. Nor does a dotted path no longer than the asked type's, led by a name the tree writes as no type or typealias: `extension URLSession.Configuration` never names `Loader.Configuration`.
    func place(_ written: ExtensionPaths.Written) throws -> Place {
        switch try extendedType(of: written.path, in: written.row.module, from: written.row.path, hops: 0) {
        case let .type(extended):
            return extended == "\(module).\(path)" ? .asked : .another
        case .elsewhere:
            return .another
        case .unknown:
            let components = QualifiedPath.components(of: written.path)
            let asked = QualifiedPath.components(of: path)
            guard let leading = components.first else { return .unplaced }
            guard components.count < asked.count, Array(asked.suffix(components.count)) == components else {
                return try isOutsideNesting(components, of: asked) ? .another : .unplaced
            }
            return try store.symbols(named: leading).contains { $0.kind == .typealiasKind } ? .unplaced : .another
        }
    }

    /// Whether `components`, a dotted path of two or more names that is no longer than the asked type's `asked`, is led by a name nothing in the tree declares, aliases or extends as a type: `URLSession` in `URLSession.Configuration` beside `Loader.Configuration`.
    ///
    /// A leading module of the tree, or a later name the tree declares as a typealias, may still reach the asked type, so such a path stays unplaced; otherwise the leading name is no type of the tree nor an alias of one, and the path names a type of a framework, never the asked one.
    private func isOutsideNesting(_ components: [String], of asked: [String]) throws -> Bool {
        guard components.count > 1, components.count <= asked.count, let leading = components.first else { return false }
        guard isEveryModuleDeclared else { return false }
        guard !moduleSpellings.contains(leading) else { return false }
        for name in components.dropFirst().dropLast() where try store.symbols(named: name).contains(where: { $0.kind == .typealiasKind }) {
            return false
        }
        guard try !ExtensionPaths.writesType(named: leading, in: store) else { return false }
        return try !store.symbols(named: leading).contains { $0.kind.isTypeDeclaration || $0.kind == .typealiasKind }
    }

    /// The type of the tree `path`, written in `module` in the file at `file`, extends, read as Swift reads it at file scope.
    ///
    /// A leading name the module itself declares at the top level is that declaration, never an import's: a typealias of it is followed, up to ``hopCap`` aliases deep, and a type of it whose path declares no type of the asked name makes the path another type.
    private func extendedType(of path: String, in module: String, from file: String, hops: Int) throws -> Extended {
        let components = QualifiedPath.components(of: path)
        guard let leading = components.first else { return .unknown }
        // A path followed through a typealias ending in another name is another type, unless a typealias of that name may lead back to this one.
        if let last = components.last, last != DeclaredTypeName.last(ofPath: self.path) {
            return try store.symbols(named: last).contains { $0.kind == .typealiasKind } ? .unknown : .elsewhere
        }
        if components.count > 1, modules.contains(leading), try !ExtensionPaths.writesType(named: leading, in: store) {
            return declared.contains(path) ? .type(path) : .unknown
        }
        // A leading name no module of the tree is spelt as and the tree writes as no type, but the extension's file imports, is that imported module, so the path is a type outside the tree; only where every file's module came from a build file, since a guessed one may not be the name the compiler gives it.
        if components.count > 1, isEveryModuleDeclared, !moduleSpellings.contains(leading), try !ExtensionPaths.writesType(named: leading, in: store),
           try store.fileRow(path: file)?.imports.contains(leading) == true
        {
            return .elsewhere
        }
        let own = "\(module).\(path)"
        if declared.contains(own) {
            return .type(own)
        }
        // A `private` or `fileprivate` declaration names nothing outside its own file, so only the extension's file sees one.
        let local = try store.symbols(named: leading).filter {
            $0.module == module && $0.parentID == nil && ($0.kind.isTypeDeclaration || $0.kind == .typealiasKind)
                && ($0.path == file || $0.accessLevel > .fileprivateLevel)
        }
        if !local.isEmpty {
            guard local.allSatisfy({ $0.kind == .typealiasKind }) else {
                return local.contains { $0.kind == .typealiasKind } ? .unknown : .elsewhere
            }
            guard local.count == 1, let alias = local.first, hops < Self.hopCap, let equals = alias.signature.firstIndex(of: "=") else { return .unknown }
            // The right-hand side's dotted path, `.some(nil)` where it is no plain path, `nil` where it does not parse.
            let written: String?? = NestingGate.parseTypeOrMissing(String(alias.signature[alias.signature.index(after: equals)...])) { type in
                type.hasError ? nil : .some(DeclaredTypeName.path(of: type))
            }
            guard let written else { return .unknown }
            // A right-hand side that is no plain path (`[Int]`, `Int?`) is a type of the standard library's sugar or shape, never the asked type.
            guard let target = written else { return .elsewhere }
            return try extendedType(of: ([target] + components.dropFirst()).joined(separator: "."), in: module, from: alias.path, hops: hops + 1)
        }
        let imported = try Set((store.fileRow(path: file)?.imports ?? []).map { "\($0).\(path)" }).intersection(declared)
        guard imported.count == 1, let only = imported.first else { return .unknown }
        return .type(only)
    }

    /// How many typealiases deep a path is followed before it is left unplaced.
    private static let hopCap = 8
}

extension ExtensionPlacement {
    /// Where an extension sits against the asked type.
    enum Place {
        case asked
        case another
        case unplaced
    }

    /// What an extension's path names: a type of the tree of the asked name, by `Module.Path`; something the code shows is another type; or nothing the code can tell.
    private enum Extended {
        case type(String)
        case elsewhere
        case unknown
    }
}
