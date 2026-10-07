//
// Copyright © Agulhas Labs
//

import Foundation

/// The coverage section `run --coverage` adds after its answer: each changed declaration's lines that ran and did not, and one total.
public struct CoverageAnswer: Sendable {
    private init() {}
}

public extension CoverageAnswer {
    /// Why no coverage may be shown for a run, or `nil` where its profile describes the tree the caller has now.
    ///
    /// The profile must have been written after the run started, and the tree's content key must be the same before and after it: a profile from an earlier build, or a tree that moved while the tests ran, describes code the caller no longer has.
    static func refusal(treeBefore: TreeKey?, treeAfter: TreeKey?, profileWritten: Date?, runStarted: Date) -> String? {
        guard let treeBefore, let treeAfter else {
            return "the tree's content could not be keyed, so the profile cannot be tied to it"
        }
        guard treeBefore == treeAfter else {
            return "the tree changed while the tests ran (\(treeBefore.displayValue) → \(treeAfter.displayValue)), so the profile describes neither"
        }
        guard let profileWritten else {
            return "this run left no coverage profile"
        }
        guard profileWritten >= runStarted else {
            return "the coverage profile predates this run — it is an earlier build's, and SwiftPM writes one only when its tests ran"
        }
        return nil
    }

    /// Each file's executable lines and their counts, keyed by the path the export names, from `llvm-cov export` JSON.
    static func lineCounts(fromExport data: Data) throws -> [String: [Int: UInt64]] {
        let document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let units = document?["data"] as? [[String: Any]] ?? []
        var counts: [String: [Int: UInt64]] = [:]
        for file in units.flatMap({ $0["files"] as? [[String: Any]] ?? [] }) {
            guard let name = file["filename"] as? String, let segments = file["segments"] as? [[Any]] else { continue }
            let lines = CoverageSegment.lineCounts(of: segments.compactMap(CoverageSegment.init(exported:)))
            counts[name, default: [:]].merge(lines, uniquingKeysWith: max)
        }
        return counts
    }

    /// The section: a heading naming the change, each changed file with its declarations, and a total.
    ///
    /// - Parameter counts: Each measured file's executable lines and their counts, keyed by repository-relative path; a changed file absent from it was not compiled into any test bundle this run built.
    static func render(_ declarations: [ChangedDeclaration], counts: [String: [Int: UInt64]], change: String) -> [String] {
        guard !declarations.isEmpty else {
            return ["coverage: no changed declaration — \(change)"]
        }
        var lines = ["coverage: \(declarations.count) changed declaration\(declarations.count == 1 ? "" : "s") — \(change)"]
        var ran = 0
        var total = 0
        for (path, group) in Dictionary(grouping: declarations, by: \.path).sorted(by: { $0.key < $1.key }) {
            guard let fileCounts = counts[path] else {
                lines.append("  \(path) — not measured: no test bundle this run built compiles it")
                for declaration in group {
                    lines.append("    \(declaration.label) \(Self.span(declaration)) — not measured")
                }
                continue
            }
            lines.append("  \(path)")
            for declaration in group {
                let measured = declaration.lines.flatMap(\.self).compactMap { line in fileCounts[line].map { (line, $0) } }
                let span = Self.span(declaration)
                guard !measured.isEmpty else {
                    lines.append("    \(declaration.label) \(span) — no code to run")
                    continue
                }
                let notRun = measured.filter { $0.1 == 0 }.map(\.0)
                ran += measured.count - notRun.count
                total += measured.count
                if notRun.count == measured.count, measured.count > 1 {
                    lines.append("    \(declaration.label) \(span) — none of its \(measured.count) lines ran")
                    continue
                }
                let tail = notRun.isEmpty ? "" : "; not run \(Self.ranges(notRun))"
                lines.append("    \(declaration.label) \(span) — \(measured.count - notRun.count) of \(measured.count) lines ran\(tail)")
            }
        }
        let percent = total == 0 ? "" : " (\(ran * 100 / total)%)"
        lines.append("coverage total: \(ran) of \(total) lines ran in the changed declarations\(percent)")
        return lines
    }

    /// Whether a changed file that `llvm-cov` listed nothing for is still compiled into a measured bundle, because a file beside it in the same directory was measured.
    ///
    /// A file holding only protocols and type aliases has no code to count and is left out of an export, exactly as a file no bundle compiled is; the directory is the target's, so a measured neighbour says which of the two it is.
    static func isCompiledBeside(_ path: String, root: URL, measured: [String]) -> Bool {
        let directory = CanonicalPath.of(root.appendingPathComponent(path).deletingLastPathComponent().path)
        return measured.contains { CanonicalPath.of(URL(fileURLWithPath: $0).deletingLastPathComponent().path) == directory }
    }

    private static func span(_ declaration: ChangedDeclaration) -> String {
        declaration.lines.map { $0.count == 1 ? ":\($0.lowerBound)" : ":\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ", ")
    }

    /// The section for a run whose coverage is refused: the reason, and no number.
    static func refused(_ reason: String) -> [String] {
        ["coverage: refused — \(reason)"]
    }

    /// Ascending line numbers as `:a-b` ranges, consecutive lines joined.
    static func ranges(_ numbers: [Int]) -> String {
        var spans: [ClosedRange<Int>] = []
        for number in numbers.sorted() {
            if let last = spans.last, last.upperBound + 1 == number {
                spans[spans.count - 1] = last.lowerBound ... number
            } else {
                spans.append(number ... number)
            }
        }
        return spans.map { $0.count == 1 ? ":\($0.lowerBound)" : ":\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ", ")
    }
}
