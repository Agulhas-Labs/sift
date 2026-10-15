//
// Copyright © Agulhas Labs
//

import Foundation

/// The non-test targets no store holds a unit for whose files write a name the answer asks about, and how many of their lines do: the targets a `where` answer names as not built.
///
/// A target is a module a build file declared (``FileRow/moduleGuessed`` false). One holding a test file is the test machinery's (``SemanticContext/testFilesWithoutUnit(in:projectDirectories:)``); one outside every build of the store's project (``BuildMembership``) is outside any built target, not unbuilt; and a `.plugin` or `.macro` target is compiled for the host without an index store, so no build ever records a unit for it. A target some of whose files have a unit is staleness, judged per file.
///
/// A subscript, an operator function, `callAsFunction` and a `subscript(dynamicMember:)` are used without spelling their name, so no scan of a file finds their uses: where one is asked about, every such target is named, with no relevance scan, and the clause says its uses of it cannot be found by name.
///
/// A target none of whose files writes an asked name, by the scan the answer's own by-name listings use (``ScannedNames``), hides nothing from this answer and is left out: a clause on every answer that tells the reader nothing teaches them to check every answer by hand. A module stops being probed at its first file with a unit, and only the unbuilt targets' files are read, so a built tree costs one probe per module.
public struct TargetsNotBuilt: Sendable, Equatable {
    /// No target left out, the value for a tree whose every target was built or writes none of the names.
    public static let empty = TargetsNotBuilt(names: [], lines: 0, written: [], unfindable: [])

    /// The targets, sorted.
    let names: [String]
    /// How many lines of their files write one of the asked names in code.
    let lines: Int
    /// The asked names those lines write, sorted.
    let written: [String]
    /// The asked declarations that are used without their name spelled, `A.subscript`, which the targets are named for whether or not they write anything, sorted.
    let unfindable: [String]

    var isEmpty: Bool {
        names.isEmpty
    }

    init(names: [String], lines: Int, written: [String], unfindable: [String] = []) {
        self.names = names
        self.lines = lines
        self.written = written
        self.unfindable = unfindable
    }

    /// The targets of `index`'s files no store `context` reads holds a unit for that write the name of one of `declarations` in code, its own declaration's name aside.
    init(writing declarations: [SymbolRow], in index: IndexStore, context: SemanticContext, projectDirectories: [String]) throws {
        let declarations = declarations.filter { $0.kind != .extensionKind && $0.kind != .operatorKind }
        let hidden = declarations.filter(Self.isUsedWithoutItsName)
        let unfindable = try Set(hidden.map { row in try (index.parentChain(of: row).map(\.name) + [row.baseName]).joined(separator: ".") }).sorted()
        var names = try ScannedNames(rows: declarations.filter { row in !hidden.contains { $0.id == row.id } }, in: index)
        names.countsMemberOfAnyReceiver = true
        guard !names.isEmpty || !unfindable.isEmpty else {
            self = .empty
            return
        }
        let files = try Array(index.fileInventory().values)
        var byModule: [String: [FileRow]] = [:]
        var testModules: Set<String> = []
        var declaredModules: Set<String> = []
        for file in files {
            byModule[file.module, default: []].append(file)
            if TestFileRecognition.isTestFile(imports: file.imports) {
                testModules.insert(file.module)
            }
            if !file.moduleGuessed {
                declaredModules.insert(file.module)
            }
        }
        let withoutUnit = byModule.filter { module, rows in
            declaredModules.contains(module) && !testModules.contains(module) && !rows.contains { context.anyStoreHasUnit(forFile: $0.path) }
        }.values.flatMap(\.self).sorted { $0.path < $1.path }
        guard !withoutUnit.isEmpty else {
            self = .empty
            return
        }
        let membership = BuildMembership(files: files, context: context, projectDirectories: projectDirectories)
        let outside = membership.outsideTheBuild(withoutUnit)
        var hostBuilt: [String: Set<String>] = [:]
        var targets: Set<String> = []
        var written: Set<String> = []
        var lines = 0
        for file in withoutUnit where !outside.contains(file.path) {
            let project = membership.project(of: file.path)
            let host = hostBuilt[project] ?? Self.hostBuiltModules(ofProject: project, under: context.repoRoot)
            hostBuilt[project] = host
            guard !host.contains(file.module) else { continue }
            if !unfindable.isEmpty {
                targets.insert(file.module)
            }
            guard !names.isEmpty,
                  let data = FileManager.default.contents(atPath: context.repoRoot.path + "/" + file.path),
                  names.writes(in: data) else { continue }
            let own = declarations.filter { $0.path == file.path }
            var fileLines: Set<Int> = []
            data.withUnsafeBytes { source in
                for name in names.names {
                    var code = names.hits(of: name, in: source).filter { $0.place == .code }.map(\.line)
                    // A declaration's own name is the first hit of it at or after the line the declaration starts on, and is no reference to it.
                    for row in own where row.baseName == name {
                        if let first = code.firstIndex(where: { $0 >= row.line }) {
                            code.remove(at: first)
                        }
                    }
                    if !code.isEmpty {
                        written.insert(name)
                        fileLines.formUnion(code)
                    }
                }
            }
            guard !fileLines.isEmpty else { continue }
            targets.insert(file.module)
            lines += fileLines.count
        }
        self.init(names: targets.sorted(), lines: lines, written: written.sorted(), unfindable: unfindable)
    }

    /// Whether `row` is used without its name spelled: a subscript, an operator function, `callAsFunction`.
    private static func isUsedWithoutItsName(_ row: SymbolRow) -> Bool {
        if row.kind == .subscriptKind {
            return true
        }
        guard row.kind == .function else { return false }
        let name = row.baseName
        guard let first = name.unicodeScalars.first else { return false }
        return name == "callAsFunction" || !(first == "_" || first == "`" || first.properties.isAlphabetic)
    }

    /// The modules of the `.plugin` and `.macro` targets the manifest of `project`, a repo-relative directory, declares.
    private static func hostBuiltModules(ofProject project: String, under root: URL) -> Set<String> {
        let directory = project.isEmpty ? root : root.appendingPathComponent(project, isDirectory: true)
        return Set(SwiftPMManifest.parse(fileAt: directory.appendingPathComponent("Package.swift")).hostBuiltTargets.map(C99ExtendedIdentifier.spelling(of:)))
    }
}
