//
// Copyright © Agulhas Labs
//

extension WhereRenderer {
    /// What the semantic pass produced: the axis for the header, the declarations it could not answer for, which the syntactic fallback then picks up, and whether it resolved anything the reference boundaries bound.
    struct SemanticOutcome {
        let axis: SemanticAxis
        let refused: [SymbolRow]
        /// Whether any row was actually asked for its references or its usage — an empty answer included, since "no references to X" is itself a claim about references and carries the same two caveats.
        ///
        /// False where every row was refused for staleness or carries no USR, and on an extension row, which the pass skips: there the boundaries would describe a section the answer does not have.
        let boundsReferences: Bool
        /// The in-tree stores that owned at least one declaration, by name, in the order they first answered.
        var answeredBy: [String] = []
        /// The declarations no store resolved, for the line naming the project that builds their files.
        var uncovered: [SymbolRow] = []
        /// The name-matched sites already listed beside the store's answers, which the syntactic fallback lists no second time.
        var listedSites: [SyntacticCallSite] = []
        /// The repo-relative `path:line:column` of every call the store's answers listed on a line of its own, where the store records a call, never one only counted in a fold or past the cap.
        var recordedCalls: Set<String> = []
        /// The repo-relative `path:line:column` of every type use a type's or typealias's answer listed on a line of its own, in a file unchanged since the build, at the column its name is written.
        var listedTypeUses: Set<String> = []
        /// Each protocol's one conformers block, by name, which replaces the block the scan by written name would print for it.
        var conformerBlocks: [String: ConformersOnce] = [:]
        /// Each type's store check on the rows its block by written name walks to, by name, for a type that block is printed for.
        var writtenNameChecks: [String: WrittenNameCheck] = [:]

        /// Whether a type use of a refused declaration's name is one the store resolved, and listed above, as another declaration's.
        func listsTypeUse(_ site: SyntacticCallSite) -> Bool {
            site.nameAt.map { listedTypeUses.contains("\(site.path):\($0)") } ?? false
        }

        /// Whether `site` is already listed above the syntactic fallback: as a name-matched site beside a store's answer, or as a call the store recorded at the name it is made through, which for a wrapper's attribute is the type's name.
        ///
        /// A recorded position is trusted only while its file is unchanged since the build, because after an edit the same line and column can hold a different call.
        func listsAlready(_ site: SyntacticCallSite, modifiedSinceBuild: (String) -> Bool) -> Bool {
            if listedSites.contains(where: { $0.isSamePlace(as: site) }) {
                return true
            }
            guard let calleeAt = site.calleeAt, !modifiedSinceBuild(site.path) else { return false }
            return recordedCalls.contains("\(site.path):\(calleeAt)")
        }
    }
}
