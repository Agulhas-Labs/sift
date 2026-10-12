//
// Copyright © Agulhas Labs
//

import Foundation

/// Which indexed files no store holds a unit for lie outside every build of a store's project, so that no build would add them, whatever their dates.
///
/// A file in a module no store holds a single unit for is outside when it sits in another project of the tree (``ProjectBoundary``: a project no store built, and for SwiftPM's store any project but the root package and those an in-tree store holds a unit in) or, for SwiftPM's store, in a module the root manifest declares no target for. A manifest naming no target literally, or any target by a computed name, is read as declaring every module, so doubt lands inside the build.
struct BuildMembership {
    /// Every indexed file, which decides whether a module or a project has a unit anywhere.
    private let files: [FileRow]
    private let context: SemanticContext
    private let boundary: ProjectBoundary

    init(files: [FileRow], context: SemanticContext, projectDirectories: [String]) {
        self.files = files
        self.context = context
        boundary = ProjectBoundary(directories: projectDirectories)
    }

    /// The project the repo-relative `path` belongs to, the empty string for the root's: with the module, all that decides whether a unit-less file is outside.
    func project(of path: String) -> String {
        boundary.project(of: path)
    }

    /// The repo-relative paths of `withoutUnit`, files no store holds a unit for, that no build of a store's project compiles.
    func outsideTheBuild(_ withoutUnit: [FileRow]) -> Set<String> {
        let compiled = Set(withoutUnit.map(\.module)).filter { module in
            files.contains { $0.module == module && context.anyStoreHasUnit(forFile: $0.path) }
        }
        let candidates = withoutUnit.filter { !compiled.contains($0.module) }
        guard !candidates.isEmpty else { return [] }
        var builtProjects: Set = [""]
        var declared: Set<String>?
        if context.store.provenance == .swiftPMBuild {
            let manifest = SwiftPMManifest.parse(fileAt: context.repoRoot.appendingPathComponent("Package.swift"))
            declared = manifest.targets.isEmpty || manifest.computedTargetNames ? nil : Set(manifest.targets.map(\.name))
            // A nested project an in-tree store was built for is built too: that store's build adds a target the project gains since.
            builtProjects.formUnion(Set(candidates.map { boundary.project(of: $0.path) }).filter { project in
                files.contains { boundary.project(of: $0.path) == project && context.holdsUnit(in: context.inTreeStores, forFile: $0.path) }
            })
        } else {
            builtProjects = Set(candidates.map { boundary.project(of: $0.path) }).filter { project in
                files.contains { boundary.project(of: $0.path) == project && context.anyStoreHasUnit(forFile: $0.path) }
            }
        }
        return Set(candidates.filter { file in
            let project = boundary.project(of: file.path)
            // The root manifest declares the root package's targets only; another project's modules are not its to name.
            return !builtProjects.contains(project) || (project.isEmpty && (declared.map { !$0.contains(file.module) } ?? false))
        }.map(\.path))
    }
}
