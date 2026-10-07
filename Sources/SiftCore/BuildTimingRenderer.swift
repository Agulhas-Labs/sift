//
// Copyright © Agulhas Labs
//

import Foundation

/// Turns a ``BuildTimingAnalysis`` into the answer `sift build --analyse` serves instead of the build's log.
///
/// Body time and expression time are stated side by side and never added, because a body's time already includes its expressions'. Every share names what it is a share of, and the receipt names the raw log the rows were read from.
public struct BuildTimingRenderer: Sendable {
    private let paths: RunAnswerPaths

    /// A renderer stating the raw log's path relative to `root`, the directory the build ran in.
    public init(root: URL) {
        paths = RunAnswerPaths.read(in: root)
    }

    /// The whole answer: the header, the slowest bodies and expressions, the files, the totals and the receipt.
    ///
    /// - Parameter seconds: How long the clean build took, wall clock.
    /// - Parameter logLines: How many lines the build printed, the receipt's lines in.
    /// - Parameter top: How many rows every list carries, bodies, expressions and files alike.
    ///
    /// Where the build left out test targets the package declares, which is what `swift build` does unless asked, the answer says the ranking covers the compiled targets only; a package with no test target is told nothing of the kind.
    public func render(_ analysis: BuildTimingAnalysis, seconds: Double, logLines: Int, logURL: URL?, top: Int, builtWithTests: Bool = false, packageHasTestTargets: Bool = true) -> String {
        let timed = analysis.bodyLines + analysis.expressionLines
        var lines = ["✔ sift build --analyse — clean build, \(Self.seconds(seconds)), \(Self.grouped(timed)) timing \(timed == 1 ? "line" : "lines") over \(Self.grouped(analysis.files.count)) \(analysis.files.count == 1 ? "file" : "files")"]
        lines += section("slowest bodies", rows: analysis.bodies, sites: analysis.bodyRows)
        lines += section("slowest expressions", rows: analysis.expressions, sites: analysis.expressionSites)
        lines += files(analysis.files, top: top)
        lines.append(totals(analysis))
        if !builtWithTests, packageHasTestTargets {
            lines.append("test targets are not built, so the ranking covers the compiled targets only and slow test code is not in it — add --build-tests to include them")
        }
        if analysis.outsideLines > 0 {
            lines.append("outside the package's own sources (dependencies, .build/): \(Self.grouped(analysis.outsideLines)) timing \(analysis.outsideLines == 1 ? "line" : "lines"), \(Self.milliseconds(analysis.outsideBodyMilliseconds)) of function bodies, \(Self.milliseconds(analysis.outsideExpressionMilliseconds)) of expressions outside any body (those inside a body are in its time), counted here only")
        }
        if analysis.macroLines > 0 {
            lines.append("macro expansions: \(Self.grouped(analysis.macroLines)) timing \(analysis.macroLines == 1 ? "line names" : "lines name") a generated @__swiftmacro_… buffer rather than a source file, \(Self.milliseconds(analysis.macroBodyMilliseconds)) of function bodies, \(Self.milliseconds(analysis.macroExpressionMilliseconds)) of expressions (which may be inside a body's or the expanding line's time), not ranked")
        }
        lines.append("")
        // The receipt counts itself: `lines` already holds the blank line, and the receipt is the last one.
        let arithmetic = "sift build: \(Self.grouped(logLines)) lines in, \(lines.count + 1) out"
        if let logURL {
            lines.append(arithmetic + " — raw output at \(paths.shown(logURL.path))")
        } else {
            lines.append(arithmetic + " — the raw log could not be written, so what is above is all there is")
        }
        return lines.joined(separator: "\n")
    }
}

private extension BuildTimingRenderer {
    /// One ranked listing under its heading, or nothing when no site of the kind was timed.
    func section(_ heading: String, rows: [BuildTimingRow], sites: Int) -> [String] {
        guard !rows.isEmpty else {
            return []
        }
        return ["\(heading) — \(rows.count) of \(sites) \(sites == 1 ? "site" : "sites"):"] + rows.map { "  \(row($0))" }
    }

    /// One row: where, how long, inside what, and how many timing lines were folded into it.
    func row(_ row: BuildTimingRow) -> String {
        var parts = ["\(row.path):\(row.line)", Self.milliseconds(row.milliseconds), row.declaration?.name ?? "no enclosing declaration"]
        if row.count > 1 {
            parts[2] += " (×\(row.count))"
        }
        if let shape = row.shape {
            parts.append(shape)
        }
        return parts.joined(separator: " · ")
    }

    /// The files holding the most body time, as many as either ranking listed, and how many more there were.
    func files(_ files: [BuildTimingFileTotal], top: Int) -> [String] {
        guard !files.isEmpty else {
            return []
        }
        let shown = files.prefix(max(top, 1))
        var lines = ["by file, most body time first — \(shown.count) of \(files.count):"]
        lines += shown.map { file in
            "  \(file.path) · bodies \(Self.milliseconds(file.bodyMilliseconds)) · expressions \(Self.milliseconds(file.expressionMilliseconds))"
        }
        return lines
    }

    /// The two totals, each with the share the listed rows hold of it, never added together.
    func totals(_ analysis: BuildTimingAnalysis) -> String {
        let bodies = "bodies \(Self.milliseconds(analysis.bodyMilliseconds)) of which the \(analysis.bodies.count) listed are \(Self.share(analysis.listedBodyMilliseconds, of: analysis.bodyMilliseconds))"
        let expressions = "expressions \(Self.milliseconds(analysis.expressionMilliseconds)), listed \(Self.share(analysis.listedExpressionMilliseconds, of: analysis.expressionMilliseconds))"
        return "\(bodies) · \(expressions) — a body's time includes its expressions', so the two are not added"
    }

    /// `part` as a whole percentage of `whole`, or a dash where nothing was timed.
    static func share(_ part: Double, of whole: Double) -> String {
        guard whole > 0 else {
            return "—"
        }
        return "\(Int((part / whole * 100).rounded()))%"
    }

    /// A duration in the unit a reader thinks in: two decimals of milliseconds under a hundred, whole milliseconds under a second, seconds above.
    static func milliseconds(_ value: Double) -> String {
        if value >= 1000 {
            return seconds(value / 1000)
        }
        if value >= 100 {
            return "\(Int(value.rounded())) ms"
        }
        return String(format: "%.2f ms", value)
    }

    /// Seconds to one decimal.
    static func seconds(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        return "\(grouped(tenths / 10)).\(tenths % 10)s"
    }

    /// `value` with a comma between each group of three digits, whatever the locale.
    static func grouped(_ value: Int) -> String {
        let digits = String(value)
        var result = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 {
                result.append(",")
            }
            result.append(digit)
        }
        return result
    }
}
