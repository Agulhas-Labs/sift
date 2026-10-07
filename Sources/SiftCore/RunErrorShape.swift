//
// Copyright © Agulhas Labs
//

import Foundation

/// What a build's errors look like taken together — and, while they are still few enough to read, the errors themselves.
///
/// **The section that can run to hundreds is the one that needs a bound.** Warnings beside it are capped at 20, while an unbounded errors listing prints all 200; on the capture this was built from, every one of those 200 is the same sentence. One helper's argument label changed, forty files called it, and listing them is 206 lines and 22.7 KB of `incorrect argument label in call (have '_:width:', expected '_:columns:')`, two hundred times over. Measured, that is one signature across forty files, and the answer is two lines.
///
/// **A sibling of ``RunFailureShape`` rather than the same type, because the identity differs.** A test failure is identified by its name, so its example leads with the name and hangs the message underneath; a compile error is identified by its location, so its example stays in the compiler's own `File.swift:2:15: error: …` form — one line, and one the reader can hand straight to a `Read`. Only the counting is common, and that is ``RunFailureCensus``, which both of them hold rather than reimplement.
///
/// **There is no `↳ top:` line here, and that is not an oversight.** ``RunFailureSignature`` elides string literals, numbers and addresses — the things a test failure's message is *about* — so collapsing `(labels → "Duration").contains(…)` and its thirty-nine other spellings into one is a real reduction worth a line of its own. A compile error's message is about types and names, which the compiler quotes with `'…'` and this normalisation leaves alone: its signature is its own sentence, so the line would print the example directly beneath it a second time.
///
/// **`in changed files` is a sharper signal over a build than over a test run.** A compile error in a file you have just edited is almost certainly yours; one in a file you never touched usually means something moved underneath you — a dependency's API, a generated interface, a branch merged in — and that is a different next step, not a smaller one. The match is by filename rather than by path, as everywhere this number appears, and the line says so.
public struct RunErrorShape: Sendable {
    /// The errors this shape measured, in the order and the spelling the run reported them in.
    ///
    /// **As the run spelled them, and not as the reader will see them.** Making a path relative to the directory the answer is being read in is a display decision, and taken before the errors reach here it would put the reader's working directory inside the measurement that decides whether they are shown every error or one of each kind. ``paths`` does it at the moment a line is composed instead.
    public let errors: [RunDiagnostic]
    /// How this answer states those paths, and what stating them that way saved.
    public let paths: RunAnswerPaths
    /// What they measure to.
    public let census: RunFailureCensus
    /// The noun this shape counts in — `"error"` for a build's errors, `"warning"` for a linter's.
    ///
    /// A linter's warnings need the same grouping: one line per violation in the compiler's own diagnostic shape is the same thing an error listing already reduces well.
    let noun: String
}

public extension RunErrorShape {
    /// Measures `errors` against what the working tree has changed, and states their paths as `paths` says to.
    static func of(_ errors: [RunDiagnostic], changedFiles: RunChangedFiles, paths: RunAnswerPaths = .asPrinted, noun: String = "error") -> RunErrorShape {
        RunErrorShape(
            errors: errors,
            paths: paths,
            census: .of(errors, message: \.message, path: \.sourcePath, changedFiles: changedFiles),
            noun: noun
        )
    }
}

// MARK: - Rendering

public extension RunErrorShape {
    /// The errors section: the measurements, then every error while a listing of them is still worth serving — and one example per kind once it is not.
    ///
    /// **The listing is preferred and the sample is the fallback, decided on the rendered answer rather than on a count.** A count is a proxy for it and fails exactly where the sample is worth least: eight distinct compile errors in eight files reduce to eight signatures, so a cap of five withholds three that every one of them has to be fixed, sending the reader to the raw log the command exists to replace. It is not even the cheaper answer — the sample comes to 740 bytes against the full listing's 651, because the `+N more signatures` line costs more than the errors it stands in for. What refuses a listing is ``RunFailureCensus/listing(of:within:entries:)``: its size, the lines the log it stands for has left for it, and whether it is chiefly one sentence repeated. The arithmetic behind each is there.
    ///
    /// **The measurement line stands over both forms.** `2 errors · 2 signatures · 1 file` over two lines can look redundant, and that reading is wrong about which of the fields carries the answer: `9 errors · 1 signature` and `9 errors · 9 signatures` are the same nine lines and completely different next steps, and the reader who has to work that out by eye is doing the counting this line exists to do. Only where it says the block is a *sample* is it also a disclosure, and that part is ``RunFailureCensus/withheld(beyond:of:)``'s.
    ///
    /// **Nothing is clipped in an errors listing, and this is the one rule the two sections do not share.** A compile error's entry is a single line whose words are the compiler's own sentence, so a listing claiming to be complete prints it complete, and it needs no cap of its own: a run whose messages are wide enough to matter overruns the budget and is served as the sample, which does clip. ``RunFailureShape`` clips in both of its forms instead, and is right to — a test failure's message, note and arguments are arbitrary *program* output, and one dumped view tree is 1.5 KB on its own. Same form rule, different clipping rule, because the two sections print different things. The one exception is ``RunReportRenderer/lineCap``, which the renderer applies to every line of every answer: a line past it is one a log carried, never a sentence a reader acts on.
    ///
    /// **An `Undefined symbols` block survives both forms whole.** Its header means nothing without the symbol list indented beneath it, so `detail` is printed in full either way — the clip bounds a diagnostic's own sentence and never the lines the linker hung under it. A block whose signature ranks past the cap is withheld like any other, and the receipt below the answer names the raw log that still holds it. Short of ``RunReportRenderer/lineCap``, which bounds every line of the answer, detail included.
    ///
    /// **Which makes the sample the one part of this answer bounded by neither `allowance` nor ``RunFailureCensus/listingBudget``, and that is deliberate.** A listing is refused the moment it outgrows either, but what it falls back to prints five examples with their detail in full, so a linker dumping several hundred undefined symbols renders a block longer than the log it stands for. Truncating it would leave a header naming symbols the answer does not carry, which is worse than a long answer; the receipt states the real arithmetic instead, and `N lines in, M out` with `M > N` is the tool being honest about a case where it did not compress. What it must not do is let that overrun turn into a negative line count for the section beneath — see ``RunReportRenderer/allowance(of:beside:)``.
    ///
    /// - Parameter budget: What the whole answer has left of ``RunFailureCensus/listingBudget``, reduced by whatever this block lists. An answer's other section can list too, and a budget read rather than spent bounds a section instead of the answer it is documented to bound.
    func rendered(within allowance: Int, spending budget: inout Int) -> [String] {
        guard !errors.isEmpty else {
            return []
        }
        return listed(within: allowance, spending: &budget) ?? measured()
    }

    /// The same block standing on its own: the whole of ``RunFailureCensus/listingBudget`` to spend, and no log bounding how long it may be.
    func rendered() -> [String] {
        var budget = RunFailureCensus.listingBudget
        return rendered(within: .max, spending: &budget)
    }
}

private extension RunErrorShape {
    /// Every error, in the compiler's own form — or `nil` once that listing is no longer the answer worth serving.
    func listed(within allowance: Int, spending budget: inout Int) -> [String]? {
        census.listing(of: noun, within: allowance, spending: &budget, entries: errors.lazy.map { error in
            RunFailureCensus.Entry(
                ["  \(paths.shown(error).described)"] + error.detail.map { "  \($0)" },
                shortenedBy: paths.shortening(of: error)
            )
        })
    }

    /// The measurement, then one example per signature with the rest counted.
    func measured() -> [String] {
        var lines = census.heading(of: noun)
        let listed = census.signatures.prefix(RunFailureCensus.signatureCap)
        for example in listed {
            let error = paths.shown(errors[example.representative])
            // The multiplier is what says this line stands for more than itself, so a reader never reads one example as one error.
            let shared = example.count > 1 ? "  ×\(example.count)" : ""
            // The clip bounds the compiler's sentence and never the expansion site after it, which is the one location a reader can open.
            lines.append("  \(RunFailureCensus.clipped(error.compilerLine))\(error.expansionNote)\(shared)")
            lines.append(contentsOf: error.detail.map { "  \($0)" })
        }
        if let withheld = census.withheld(beyond: listed.count, of: noun) {
            lines.append(withheld)
        }
        return lines
    }
}
