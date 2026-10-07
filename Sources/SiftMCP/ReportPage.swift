//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Renders ``ReportData`` as one self-contained HTML file — the local answer to "is this working", for a tool with no network and no daemon to host one.
///
/// Everything is inline: the stylesheet, the bars, the type stack. A page that fetches anything is a page that renders differently offline or on a machine that has never opened it before, and this one has to be openable straight off disk with nothing running.
///
/// A pure function of the data it is given, so the page can be asserted on without a home directory, a log, or an indexed repository anywhere near it.
public struct ReportPage {
    /// The whole file, `<!doctype html>` to `</html>`.
    public static func render(_ data: ReportData) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>sift report</title>
        <style>
        \(stylesheet)
        </style>
        </head>
        <body>
        <main>
        \(header(data))
        \(conditions(data))
        \(shareSection(data))
        \(savingsSection(data))
        \(failuresSection(data))
        \(rootsSection(data))
        \(targetsSection(data))
        \(footer(data))
        </main>
        </body>
        </html>
        """
    }

    // MARK: Sections

    private static func header(_ data: ReportData) -> String {
        var scope = ["window \(escaped(data.window))"]
        if let day = data.firstLogDay {
            scope.append("calls since \(escaped(day)) UTC")
        }
        if let day = data.firstTranscriptDay {
            scope.append("lookups since \(escaped(day)) local")
        }
        switch data.rootScope {
        case let .resolved(root):
            scope.append("scoped to \(escaped(root))")
        case let .unresolved(argument):
            // Stated here or nowhere: every figure below is machine-wide, and a header that simply omits
            // the scope it was asked for is how one repository's page comes to be read as another's.
            scope.append("--root \(escaped(argument)) named no one directory — nothing below is scoped")
        case nil:
            break
        }
        let scratch = data.scratchNote.map { "<p class=\"caption\">\(escaped($0))</p>" } ?? ""
        return """
        <header>
        <h1>sift report</h1>
        <p class="meta">generated \(escaped(stamp(data.generatedAt))) · \(scope.joined(separator: " · "))</p>
        \(scratch)
        </header>
        """
    }

    /// The conditions block, or nothing at all.
    ///
    /// Nothing, not an empty heading: this section is a short list of conditions awaiting a human, and nothing at all when the list is empty (Docs/Design.md §3). A standing "All clear" panel is a counter by another name — it trains the eye to skip the place the real thing will appear.
    private static func conditions(_ data: ReportData) -> String {
        guard !data.conditions.isEmpty else { return "" }
        let items = data.conditions.map { condition in
            """
            <li>
            <p class="condition-root">\(escaped(condition.name))</p>
            <p class="condition-headline">\(escaped(condition.headline))</p>
            <p class="condition-fact">\(inlineCode(condition.fact))</p>
            <p class="condition-action">\(inlineCode(condition.action))</p>
            <pre class="command">\(escaped(condition.command))</pre>
            <p class="condition-path">\(escaped(condition.root))</p>
            </li>
            """
        }
        return """
        <section class="conditions">
        <h2>Awaiting you</h2>
        <ul>
        \(items.joined(separator: "\n"))
        </ul>
        </section>
        """
    }

    private static func shareSection(_ data: ReportData) -> String {
        guard let share = data.share else {
            return section(title: "Index share", body: "<p class=\"empty\">No Swift lookups recorded in this window.</p>")
        }
        let value = share.tally.shareText ?? "n/a"
        let caption = [
            "\(share.tally.indexed) served by the index, \(share.tally.cold) went around it, "
                + "\(share.tally.readWholeAfterDigest) read whole after its digest — across \(share.sessions) session\(share.sessions == 1 ? "" : "s").",
            "Not a measurement of everything: this machine's transcripts only, in this window, "
                + "and a Grep that merely mentions Swift counts against it. A lookup the CLI served counts "
                + "for the index, as the same lookup through the MCP tools does.",
        ]
        let captionHTML = caption.map { "<p class=\"caption\">\(escaped($0))</p>" }.joined(separator: "\n")
        return section(title: "Index share", body: """
        <p class="figure">\(escaped(value))</p>
        \(trend(share.byDay))
        \(captionHTML)
        """)
    }

    /// A bar per day, drawn by hand in SVG because a chart library is a network request.
    ///
    /// Every share here is printed through `DayShare.shareText`, the same floor the headline above it uses. A page rendering `<1%` in one place and a bare `0` over a drawn bar in another is contradicting itself about the same measurement, and the label carrying its `%` is what stops the bar's value being read as a count.
    private static func trend(_ days: [ReportData.DayShare]) -> String {
        guard days.count > 1 else { return "" }
        let width = 34
        let gap = 8
        let height = 90
        let bars = days.enumerated().map { index, day -> String in
            let barHeight = max(1, height * day.share / 100)
            let x = index * (width + gap)
            let title = "\(day.day): \(day.shareText) — \(day.indexed) of \(day.total)"
            return """
            <g><title>\(escaped(title))</title>\
            <rect x="\(x)" y="\(height - barHeight)" width="\(width)" height="\(barHeight)" rx="3" class="bar"></rect>\
            <text x="\(x + width / 2)" y="\(height + 14)" class="bar-day">\(escaped(String(day.day.suffix(5))))</text>\
            <text x="\(x + width / 2)" y="\(height - barHeight - 5)" class="bar-value">\(escaped(day.shareText))</text></g>
            """
        }
        let total = days.count * (width + gap) - gap
        return """
        <svg class="trend" viewBox="0 0 \(total) \(height + 20)" width="\(total)" height="\(height + 20)" role="img" aria-label="index share by day">
        \(bars.joined(separator: "\n"))
        </svg>
        """
    }

    private static func savingsSection(_ data: ReportData) -> String {
        guard let savings = data.savings else {
            return section(title: "Estimated savings", body: """
            <p class="empty">No call in this window measured itself against the source it replaced.</p>
            \(runsRow(data))
            """)
        }
        // The absolute leads and the ratio explains it. A percentage is a shape; the question a reader
        // brings to a savings figure is how much, and a bare percentage cannot answer it without a second
        // document.
        let rows = (savings.split + [savings.total]).map { row in
            """
            <tr><td class="count">\(row.calls)</td><td>\(escaped(row.label))</td>\
            <td class="days">\(escaped(ByteSize.short(row.source))) → \(escaped(ByteSize.short(row.served)))</td>\
            <td>\(escaped(row.outcome))</td></tr>
            """
        }
        // Gross, and said so: the whole reads after a digest are counted from the share's transcripts and
        // never priced, since no join of a call to its log line could be shown right (Docs/Design.md).
        let notes = [
            savings.savedText.flatMap { _ in TokenEstimate.readAnyway(data.share?.tally.readWholeAfterDigest ?? 0) },
            savings.unrecorded.map { "\($0.calls) \($0.note)" },
            savings.unpriced.map { "\($0.calls) \($0.note)" },
            savings.floorNote,
            // Plural on the count of *agents*, not of calls: the note it runs into names them ("is work 2
            // subagents did"), and a singular opening against a plural close reads as a rendering bug in a
            // page whose whole job is to be believed about its numbers. The article goes with the plural,
            // since "a subagents" would be a worse repair than the mismatch it fixes.
            savings.subagents.map {
                "\($0.row.calls) of those calls came from \($0.agents == 1 ? "a subagent" : "subagents"): \($0.note)"
            },
        ]
        .compactMap(\.self)
        .map { "<p class=\"caption\">\(escaped($0))</p>" }
        return section(title: "Estimated savings", body: """
        \(savings.savedText.map { "<p class=\"figure\">\(escaped($0))</p>" } ?? "")
        <p class="caption">\(escaped(savings.savedBasis.map { basis in "\(basis) — \(savings.sentence)" } ?? savings.sentence)); \(escaped(TokenEstimate.baseline))</p>
        <table>
        <thead><tr><th>calls</th><th>answers</th><th>source → served</th><th>outcome</th></tr></thead>
        <tbody>
        \(rows.joined(separator: "\n"))
        </tbody>
        </table>
        <p class="caption">Summed on both sides, never averaged over per-call ratios, which would let the smallest answers dominate.</p>
        <p class="caption">\(escaped(TokenEstimate.notMeasured))</p>
        \(notes.joined(separator: "\n"))
        \(runsRow(data))
        """)
    }

    /// One line for the wrapped toolchain runs, or nothing when the window holds none.
    ///
    /// A row rather than a section, and it names its own subject in its first two words. The saving above it is index answers standing in for source; this is `sift run` dropping build output — a different original, measured the same way — and a reader must not be able to take one figure for the other or add them together. Nothing at all when there are no runs: a standing zero here would report a feature as failing on a machine that simply has not used it.
    private static func runsRow(_ data: ReportData) -> String {
        guard let runs = data.runs else { return "" }
        var parts = ["\(runs.runs) run\(runs.runs == 1 ? "" : "s") wrapped in \(inlineCode("`sift run`"))"]
        if let sentence = runs.sentence {
            parts.append(escaped(sentence))
        }
        parts.append("\(runs.nonzeroExits) exited nonzero")
        return "<p class=\"caption\">Build output, window \(escaped(data.window)): \(parts.joined(separator: " · ")).</p>"
    }

    private static func failuresSection(_ data: ReportData) -> String {
        guard !data.failures.isEmpty else {
            return section(title: "Failures", body: "<p class=\"empty\">No failed calls in this window.</p>")
        }
        let rows = data.failures.prefix(rowCap).map { group in
            """
            <tr><td class="count">\(group.count)</td><td>\(escaped(group.reason))</td><td class="days">\(escaped(dates(group.days)))</td></tr>
            """
        }
        return section(title: "Failures", body: """
        <table>
        <thead><tr><th>calls</th><th>reason</th><th>days</th></tr></thead>
        <tbody>
        \(rows.joined(separator: "\n"))
        </tbody>
        </table>
        \(overflow(data.failures.count))
        <p class="caption">Days are the log's own, which files a call under the UTC date of its timestamp.</p>
        """)
    }

    private static func rootsSection(_ data: ReportData) -> String {
        guard !data.roots.isEmpty else {
            return section(title: "By root", body: "<p class=\"empty\">\(escaped(data.logNote ?? "No calls in this window."))</p>")
        }
        // Capped like every other list on the page. A machine that runs per-agent worktrees files each of
        // them as its own root, so an uncapped table is mostly rows for repositories that no longer exist.
        let rows = data.roots.prefix(rowCap).map { use in
            """
            <tr><td class="count">\(use.calls)</td><td>\(escaped(use.name))\
            <span class="path">\(escaped(use.root))</span></td>\
            <td class="share"><span class="meter"><span class="fill" style="width:\(use.percent)%"></span></span>\(use.percent)%</td></tr>
            """
        }
        return section(title: "By root", body: """
        <table>
        <thead><tr><th>calls</th><th>root</th><th>share of \(data.calls)</th></tr></thead>
        <tbody>
        \(rows.joined(separator: "\n"))
        </tbody>
        </table>
        \(overflow(data.roots.count))
        """)
    }

    private static func targetsSection(_ data: ReportData) -> String {
        guard !data.targets.isEmpty else {
            return section(title: "Top targets", body: "<p class=\"empty\">No targeted calls in this window.</p>")
        }
        let rows = data.targets.prefix(rowCap).map { target in
            """
            <tr><td class="count">\(target.count)</td><td>\(escaped(target.label))</td><td class="days">\(escaped(dates(target.days)))</td></tr>
            """
        }
        return section(title: "Top targets", body: """
        <table>
        <thead><tr><th>calls</th><th>target</th><th>days</th></tr></thead>
        <tbody>
        \(rows.joined(separator: "\n"))
        </tbody>
        </table>
        \(overflow(data.targets.count))
        <p class="caption">One row per <code>tool target</code> pair — what this window kept coming back to.</p>
        """)
    }

    private static func footer(_ data: ReportData) -> String {
        var lines = [
            "calls: \(data.logPath)",
            "lookups: \(data.transcriptDirectory)",
        ]
        if let note = data.logNote {
            lines.insert(note, at: 0)
        }
        return """
        <footer>
        \(lines.map { "<p>\(escaped($0))</p>" }.joined(separator: "\n"))
        </footer>
        """
    }

    // MARK: Pieces

    /// Rows any one table shows before the rest are counted instead — a page glanced at is a page that fits.
    private static var rowCap: Int {
        12
    }

    /// The line naming what a cap left out, or nothing when it left out nothing.
    private static func overflow(_ total: Int) -> String {
        guard total > rowCap else { return "" }
        let rest = total - rowCap
        return "<p class=\"caption\">… and \(rest) more, in <code>sift usage</code>.</p>"
    }

    private static func section(title: String, body: String) -> String {
        """
        <section>
        <h2>\(escaped(title))</h2>
        \(body)
        </section>
        """
    }

    /// The day annotation for a counted row: one day, or the span it falls across.
    private static func dates(_ days: [String]) -> String {
        guard let first = days.first, let last = days.last else { return "—" }
        return first == last ? first : "\(first) – \(last)"
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// Escapes `text`, then promotes its backticked runs to `<code>` — the shared warning wordings are written with them, and stripping the marks would flatten a command into prose.
    private static func inlineCode(_ text: String) -> String {
        text.components(separatedBy: "`").enumerated().map { index, part in
            index.isMultiple(of: 2) ? escaped(part) : "<code>\(escaped(part))</code>"
        }.joined()
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static var stylesheet: String {
        """
        :root {
          color-scheme: light dark;
          --ink: #1b1d1f; --dim: #61666c; --line: #e2e5e9; --page: #fbfbfc;
          --card: #ffffff; --accent: #1f6f5c; --warn-bg: #fff5ec; --warn-line: #e8a04c;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --ink: #e8eaec; --dim: #9aa0a6; --line: #2c3034; --page: #16181a;
            --card: #1d2023; --accent: #57b39a; --warn-bg: #2a2116; --warn-line: #c07f2e;
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0; padding: 2.5rem 1.25rem 4rem; background: var(--page); color: var(--ink);
          font: 15px/1.55 ui-sans-serif, -apple-system, "SF Pro Text", Helvetica, Arial, sans-serif;
        }
        main { max-width: 46rem; margin: 0 auto; }
        h1 { font-size: 1.4rem; margin: 0; letter-spacing: -0.01em; }
        h2 { font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.09em; color: var(--dim);
             margin: 0 0 0.75rem; font-weight: 600; }
        header { margin-bottom: 2rem; }
        .meta { margin: 0.35rem 0 0; color: var(--dim); font-size: 0.85rem; }
        section { background: var(--card); border: 1px solid var(--line); border-radius: 10px;
                  padding: 1.25rem 1.35rem; margin-bottom: 1rem; }
        section.conditions { background: var(--warn-bg); border-color: var(--warn-line); }
        section.conditions ul { list-style: none; margin: 0; padding: 0; }
        section.conditions li + li { margin-top: 1.5rem; border-top: 1px solid var(--warn-line); padding-top: 1.25rem; }
        .condition-root { margin: 0; font-weight: 600; }
        .condition-headline { margin: 0.2rem 0 0.6rem; font-size: 1.05rem; }
        .condition-fact, .condition-action { margin: 0 0 0.6rem; color: var(--dim); }
        .condition-path { margin: 0.5rem 0 0; color: var(--dim); font-size: 0.78rem; }
        .figure { font-size: 2.6rem; font-weight: 600; margin: 0 0 0.5rem; letter-spacing: -0.02em; }
        .caption { margin: 0.4rem 0 0; color: var(--dim); font-size: 0.85rem; }
        .empty { margin: 0; color: var(--dim); }
        code, pre, .path, .days, .count { font-family: ui-monospace, "SF Mono", Menlo, monospace; }
        code { font-size: 0.87em; background: color-mix(in srgb, var(--ink) 8%, transparent);
               padding: 0.05em 0.32em; border-radius: 4px; }
        pre.command { margin: 0.5rem 0 0; padding: 0.6rem 0.75rem; overflow-x: auto;
                      background: color-mix(in srgb, var(--ink) 8%, transparent); border-radius: 6px; font-size: 0.85rem; }
        table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
        th { text-align: left; font-weight: 600; font-size: 0.72rem; text-transform: uppercase;
             letter-spacing: 0.06em; color: var(--dim); padding-bottom: 0.4rem; }
        td { padding: 0.4rem 0.5rem 0.4rem 0; border-top: 1px solid var(--line); vertical-align: top;
             overflow-wrap: anywhere; }
        td.count { width: 3.5rem; text-align: right; padding-right: 1rem; }
        td.days, th:last-child { white-space: nowrap; color: var(--dim); font-size: 0.8rem; }
        .path { display: block; color: var(--dim); font-size: 0.75rem; }
        td.share { width: 9rem; white-space: nowrap; color: var(--dim); }
        .meter { display: inline-block; width: 5rem; height: 6px; border-radius: 3px; margin-right: 0.5rem;
                 background: color-mix(in srgb, var(--ink) 12%, transparent); vertical-align: middle; }
        .meter .fill { display: block; height: 100%; border-radius: 3px; background: var(--accent); }
        .trend { max-width: 100%; height: auto; margin: 0.25rem 0 0.75rem; display: block; }
        .trend .bar { fill: var(--accent); }
        .trend text { fill: var(--dim); font-size: 10px; text-anchor: middle;
                      font-family: ui-monospace, "SF Mono", Menlo, monospace; }
        footer { color: var(--dim); font-size: 0.78rem; margin-top: 1.5rem; }
        footer p { margin: 0.2rem 0; overflow-wrap: anywhere; font-family: ui-monospace, "SF Mono", Menlo, monospace; }
        """
    }
}
