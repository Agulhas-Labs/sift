//
// Copyright © Agulhas Labs
//

import Foundation

/// What `audit --scan-diff` prints: every window two builds' scans class differently over one snapshot, grouped as its class → this one's, and one line totalling the windows and each scan's guided and cold counts.
public struct ScanDiff {
    /// How many windows a group lists by default, so a class that moved on more is cut with a line saying so and a request to list all lifts the cut.
    public static let listedPerClass = 100

    /// The section's lines for the other build's windows, `theirs`, and this build's, `ours`, joined on session, call and part, with file names pseudonymised by `redactor` where there is one.
    ///
    /// A window one scan scored and the other did not is classed `absent` on the side that lacks it. Each group lists its first ``listedPerClass`` windows or every one where all are asked for, and where it cuts a group says how many it listed of how many. Given a second run of each build, `again`, a window either build classed differently between its two runs is listed apart as unstable, with each run's class, and left out of the differing count.
    public static func lines(theirs: [ScoredWindow], ours: [ScoredWindow], again: (theirs: [ScoredWindow], ours: [ScoredWindow])? = nil, listsAll: Bool = false, redactor: Redactor? = nil) -> [String] {
        let firstRuns = (theirs: index(theirs), ours: index(ours))
        let secondRuns = again.map { (theirs: index($0.theirs), ours: index($0.ours)) }
        var keys = Set(firstRuns.theirs.keys).union(firstRuns.ours.keys)
        if let secondRuns {
            keys.formUnion(secondRuns.theirs.keys)
            keys.formUnion(secondRuns.ours.keys)
        }
        var groups: [String: [(old: ScoredWindow?, new: ScoredWindow?)]] = [:]
        var unstable: [String] = []
        for key in keys.sorted() {
            let (was, now) = (firstRuns.theirs[key], firstRuns.ours[key])
            if let secondRuns {
                let (wasAgain, nowAgain) = (secondRuns.theirs[key], secondRuns.ours[key])
                if classOf(was) != classOf(wasAgain) || classOf(now) != classOf(nowAgain) {
                    let history = "classed \(classOf(was)) / \(classOf(wasAgain)) → \(classOf(now)) / \(classOf(nowAgain))"
                    unstable.append(line(old: was, new: now, redactor: redactor) + "  " + history)
                    continue
                }
            }
            let (from, into) = (classOf(was), classOf(now))
            guard from != into else { continue }
            groups["\(from) → \(into)", default: []].append((old: was, new: now))
        }
        let cap = listsAll ? Int.max : listedPerClass
        var lines = [
            "",
            "scan against another binary — every window in the snapshot scored by both builds' scans; the windows they class differently, as its class → this one's:",
        ]
        for (change, windows) in groups.sorted(by: { ($0.value.count, $1.key) > ($1.value.count, $0.key) }) {
            lines.append("      \(TranscriptAudit.pad(windows.count))  \(change)")
            lines += windows.prefix(cap).map { line(old: $0.old, new: $0.new, redactor: redactor) }
            if windows.count > cap {
                lines.append(cutLine(listed: cap, of: windows.count))
            }
        }
        if !unstable.isEmpty {
            lines.append("  unstable: classed differently between runs of the same build, likely live index state — \(unstable.count) windows, left out of the differing count (each build's first / second run, its → this one's):")
            lines += unstable.prefix(cap)
            if unstable.count > cap {
                lines.append(cutLine(listed: cap, of: unstable.count))
            }
        }
        let differing = groups.values.reduce(0) { $0 + $1.count }
        let guided = (theirs.count { $0.classification == "guided" }, ours.count { $0.classification == "guided" })
        let cold = (theirs.count { $0.classification == "cold" }, ours.count { $0.classification == "cold" })
        lines.append("  scan differs on \(differing) of \(keys.count) windows — guided \(guided.0) → \(guided.1), cold \(cold.0) → \(cold.1) (its → this one's)")
        return lines
    }

    /// The line that ends a group the cap cut.
    private static func cutLine(listed: Int, of total: Int) -> String {
        "          … listed \(listed) of \(total) — --all-windows for the rest"
    }

    /// Whether the two builds' scans class any window differently, so a second run of each is worth making.
    public static func differs(theirs: [ScoredWindow], ours: [ScoredWindow]) -> Bool {
        let (old, new) = (index(theirs), index(ours))
        return Set(old.keys).union(new.keys).contains { classOf(old[$0]) != classOf(new[$0]) }
    }

    /// The windows of one run by join key, the first of a repeated key winning.
    private static func index(_ windows: [ScoredWindow]) -> [String: ScoredWindow] {
        Dictionary(windows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// A window's class, `absent` where the run has none.
    private static func classOf(_ window: ScoredWindow?) -> String {
        window?.classification ?? "absent"
    }

    /// One window's line: its file, session and call, and the call that located its file under each build, `none` where no call had.
    private static func line(old: ScoredWindow?, new: ScoredWindow?, redactor: Redactor?) -> String {
        let window = new ?? old
        let file = (window?.file).map { path in
            redactor.map { $0.file(URL(fileURLWithPath: path).lastPathComponent) } ?? Redactor.tilded(path)
        } ?? "(no file)"
        let located = [old, new].map { side in (side?.locator).map { "\($0.tool) \($0.call)" } ?? "none" }
        let part = window?.part == ScoredWindow.indexPart ? " (index)" : ""
        return "          \(file)  session \(window?.session ?? "")  call \(window?.call ?? "")\(part)  located by \(located[0]) → \(located[1])"
    }
}
