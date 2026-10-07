//
// Copyright © Agulhas Labs
//

/// Renders a `ConfigPlan` as the report `sift init` prints.
struct ConfigPlanRenderer {
    /// Unresolved groups listed before the remainder is counted instead.
    static var groupCap: Int {
        20
    }

    static func render(plan: ConfigPlan, wrote: String?) -> String {
        let manifestSuffix = plan.manifestsScanned > 0 ? " (+\(plan.manifestsScanned) build manifest(s))" : ""
        var lines = ["scanned \(plan.filesScanned) Swift source file(s)\(manifestSuffix)"]

        if plan.swiftDirectories.isEmpty {
            lines.append("no Swift files found — nothing to configure")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        lines.append("modules resolved from build files: \(plan.resolvedModules.count) covering \(plan.resolvedFileCount) file(s)")
        if !plan.resolvedModules.isEmpty {
            let named = plan.resolvedModules
                .sorted { ($1.value, $0.key) < ($0.value, $1.key) }
                .prefix(groupCap)
                .map { "\($0.key) (\($0.value))" }
            lines.append("  " + named.joined(separator: "  "))
        }
        for manifest in plan.unmappedManifests.prefix(groupCap) {
            lines.append("⚠ \(manifest) exists but no target could be mapped from it — target names or paths")
            lines.append("  may be computed rather than literal. Its files fall through to guessing below.")
        }

        lines.append("")
        if plan.unresolvedGroups.isEmpty {
            lines.append("every file's module comes from a build file — no moduleMap needed")
        } else {
            lines.append("⚠ \(plan.unresolvedFileCount) file(s) in \(plan.unresolvedGroups.count) group(s) have NO declaring build file.")
            lines.append("  Until mapped, answers guess their module from the path's first component, so")
            lines.append("  `digest <Module>` and `where Module.Type` are wrong for them — every such answer")
            lines.append("  opens with a `⚠ module guessed` banner naming the files.")
            lines.append("  Proposed moduleMap entries — each value is guessed from its group's directory name,")
            lines.append("  which is not the first component an answer guesses today; replace any that is not")
            lines.append("  the real target name:")
            for group in plan.unresolvedGroups.prefix(groupCap) {
                lines.append("    \"\(group.prefix)\": \"\(group.proposedModule)\"   — \(group.fileCount) file(s)")
            }
            if plan.unresolvedGroups.count > groupCap {
                lines.append("    … \(plan.unresolvedGroups.count - groupCap) more group(s)")
            }
        }

        lines.append("")
        if plan.skippableDirectories.isEmpty {
            lines.append("roots: every top-level directory holds Swift — left empty (index the whole repo)")
        } else {
            lines.append("roots: \(plan.swiftDirectories.joined(separator: " ")) — skips \(plan.skippableDirectories.count) directory(ies) with no Swift: \(plan.skippableDirectories.prefix(groupCap).joined(separator: " "))")
        }

        lines.append("")
        if let wrote {
            lines.append("wrote \(wrote)")
            lines.append("It is not committed by default — in a shared repository, add it to .git/info/exclude and it stays yours alone.")
        } else {
            lines.append("nothing written — pass --write to create .sift.json, or --force to update an existing one")
        }
        return lines.joined(separator: "\n")
    }
}
