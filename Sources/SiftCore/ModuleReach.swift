//
// Copyright © Agulhas Labs
//

/// Which tree modules each module can load, read from the imports its files write, so a written-name match no import makes possible can be set aside.
///
/// A module loads itself and every tree module an import in any of its files names, followed transitively. The union is module-wide rather than per file because a member declared in an extension can leak between one module's files. Every rule that could wrongly set a match aside answers "can load" instead: a module guessed from a path, a declaring module no import in the tree names (a build may rename it), and a module importing something the tree does not declare, which may be a tree module under another name.
struct ModuleReach {
    private let loads: [String: Set<String>]
    private let guessed: Set<String>
    private let renamable: Set<String>
    private let selfSufficient: Set<String>

    init(files: some Collection<FileRow>) {
        var imports: [String: Set<String>] = [:]
        var guessed: Set<String> = []
        var testModules: Set<String> = []
        for file in files {
            imports[file.module, default: []].formUnion(file.imports)
            if file.moduleGuessed {
                guessed.insert(file.module)
            }
            if !TestSymbolReader.styles(importedBy: file).isEmpty {
                testModules.insert(file.module)
            }
        }
        let modules = Set(imports.keys)
        let named = imports.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        // A module no import names may be built under another name, so nothing it declares is set aside, and an import of a name the tree does not declare may be that module; a test target is never imported.
        let renamable = modules.subtracting(named).subtracting(testModules)
        var edges: [String: Set<String>] = [:]
        var selfSufficient: Set<String> = []
        for (module, written) in imports {
            var direct = written.intersection(modules)
            // A test target that compiles a file shared with another target needs no import for it, and the index records that file under one target only.
            if direct.isEmpty, testModules.contains(module) {
                selfSufficient.insert(module)
            }
            if !written.subtracting(modules).isEmpty {
                direct.formUnion(renamable)
            }
            edges[module] = direct
        }
        var loads: [String: Set<String>] = [:]
        for module in modules {
            var reached: Set<String> = [module]
            var pending = [module]
            while let next = pending.popLast() {
                for target in edges[next] ?? [] where reached.insert(target).inserted {
                    pending.append(target)
                }
            }
            loads[module] = reached
        }
        self.loads = loads
        self.guessed = guessed
        self.renamable = renamable
        self.selfSufficient = selfSufficient
    }

    /// Whether code in the first module could name a declaration from the second; true wherever either is not known well enough to say no.
    func canLoad(_ declaring: String, from site: String) -> Bool {
        guard let reached = loads[site], loads[declaring] != nil else { return true }
        if guessed.contains(site) || guessed.contains(declaring) || renamable.contains(declaring) || selfSufficient.contains(site) {
            return true
        }
        return reached.contains(declaring)
    }
}
