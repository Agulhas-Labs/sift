//
// Copyright © Agulhas Labs
//

import Foundation

/// The answer to a `Type.member` that several declarations share, when they are small enough together to be served rather than listed.
///
/// Every declaration is served under the header a lone member's source carries, in the order given, so the caller is spared the second call the list would force.
struct SmallOverloadsServed {
    let renderer: DigestRenderer

    /// The line that opens a member's source: its qualified name, kind and location.
    func header(of row: SymbolRow) throws -> String {
        try "\(renderer.qualifiedTarget(of: row)) — \(row.kind.rawValue) — \(row.path)\(row.rangeDescription)"
    }

    /// The lines of the served answer, or `nil` where the list should stand instead.
    ///
    /// The list stands once the ranges add up to more than `SourcePassthrough.floorLineCeiling`, and where any one cannot be sliced, because then the list is the answer that says which.
    func answer(_ members: [SymbolRow], target: String) throws -> [String]? {
        let total = members.reduce(0) { $0 + $1.endLine - $1.line + 1 }
        guard total <= SourcePassthrough.floorLineCeiling else { return nil }
        var blocks: [String] = []
        for row in members {
            let source = renderer.sourceReader.text(of: row.path, under: renderer.repoRoot)
            guard case let .lines(body, _) = SourceSlicer.slice(of: row, in: source) else { return nil }
            try blocks.append(([header(of: row), ""] + body).joined(separator: "\n"))
        }
        // The banners name each file once however many of its declarations are served.
        var paths: [String] = []
        for row in members where !paths.contains(row.path) {
            paths.append(row.path)
        }
        // The repository-wide notice leads, as it leads the list, but leaves out the files served from: they carry the banner below, and this answer drew on them.
        let elsewhere = try ParseErrorNotice.acrossRepository(renderer.store).paths.filter { !paths.contains($0) }
        let countBanner = ParseErrorNotice(paths: elsewhere).servedCountBanner.map { [$0, ""] } ?? []
        let preamble = try countBanner + renderer.parseErrorBanner(touching: paths) + renderer.guessedModuleBanner(touching: paths)
        return preamble + ["\(target) names \(members.count) declarations, \(total) lines together; each follows", "", blocks.joined(separator: "\n\n")]
    }
}
