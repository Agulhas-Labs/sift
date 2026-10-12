//
// Copyright © Agulhas Labs
//

import Foundation

/// A byte saving stated in the unit the reader already thinks in.
///
/// What the tool measures is bytes: the source a digest stood in for, less the bytes it served. What a developer reading `usage` or the report page wants to know is how much source the index's answers stood in for, and an agent's context is counted in tokens, not kilobytes, so that is the unit the headline figure is stated in: a kilobyte has to be converted in the head before it means anything, and a token count beside a context limit does not.
///
/// **It is an estimate, and it says so.** The tool never tokenizes anything; it counts bytes and divides. Every rendering carries the tilde, and the faces with room for it (`usage`, the report page, `diff`'s size line) print the measured bytes and the ratio beside the estimate so the arithmetic can be checked. The status line states no saving at all: it has room for the tilde and not for the baseline, and a figure without its baseline reads as a measurement.
///
/// In Core rather than beside the MCP faces that first used it, because `diff` is a CLI answer built in Core and prices itself in the same unit — one rendering, so no two surfaces can state the same saving differently.
///
/// **The ratio is a fixed estimate, not a tokenizer count.** Claude's tokenizer lands between three and four bytes a token on source code — Swift is dense with punctuation and short identifiers, which tokenize *worse* than prose, not better — so four bytes a token is the low end of what those bytes would cost. That makes the *conversion* conservative, and nothing more: the bytes it converts are a counterfactual, priced only where it was observed (``baseline``).
public struct TokenEstimate {
    /// Bytes per token: the low end of what Swift source costs — a fixed estimate, never the model's tokenizer.
    public static let bytesPerToken = 4

    /// The tokens `bytes` of source amount to, at the ratio above.
    public static func tokens(forBytes bytes: Int) -> Int {
        bytes / bytesPerToken
    }

    /// `bytes` of source as an approximate token count: `~800 tokens`, `~4.5k tokens`, `~54k tokens`, `~2.2M tokens`.
    ///
    /// The same three-significant-figure ladder as ``ByteSize/short(_:)``, with the tilde the estimate owes its reader.
    public static func short(bytes: Int) -> String {
        let count = tokens(forBytes: bytes)
        // A saving too small to reach a whole token is still a saving, and every caller has already
        // decided it is one before asking — both gate on it being positive. `~0 tokens` is then the one
        // answer certainly wrong, and it lands where it does most damage: this is the figure the status
        // line leads with. The same floor `shareText` protects with `<1%`.
        if count == 0, bytes > 0 {
            return "<1 token"
        }
        if count < 1000 {
            return "~\(count) tokens"
        }
        if count < 10000 {
            return String(format: "~%.1fk tokens", Double(count) / 1000)
        }
        if count < 1_000_000 {
            return "~\(count / 1000)k tokens"
        }
        return String(format: "~%.1fM tokens", Double(count) / 1_000_000)
    }

    /// What every face that states the index's saving says beside it — `~2.1k tokens saved` — the tilde marking the conversion as an estimate.
    ///
    /// The bytes are measured, and so is the counterfactual: a saving is priced only where the advice hook intercepted a read and the command named what it would have printed (``baseline``). Nothing read afterwards is subtracted: the figure is gross, and the whole reads after a digest are counted beside it (``readAnyway(_:)``), never priced. One wording, defined here, so `usage`, the report page and `audit` cannot drift apart on it.
    public static var savedLabel: String {
        "saved"
    }

    /// What every saving is priced against, printed beside the saving by each face that states it, always and once: `usage`'s headline, the report page's caption, `audit`'s baseline line.
    ///
    /// Only an observed counterfactual is priced: the file or window an intercepted read asked for, less the answer the hook served in its place. A call made by choice and a grep the hook answered stand in for something nobody ran and nobody can size, and pricing them against a whole file was a number that leaned high; they are counted, never priced.
    public static var baseline: String {
        "file or window asked for − answer served"
    }

    /// The one sentence the report page, `sift report --help` and `sift audit --help` carry beside the estimate, so it is never read as a measured token saving: the end-to-end measurement is a separate artifact, and it found no detectable difference overall.
    public static var notMeasured: String {
        "This is an estimate of source not read, not a measured token saving; the end-to-end measurement is in Benchmarks/RESULTS-ios-app-10.md."
    }

    /// `bytes` of saving as every face states it: `~2.1k tokens saved`.
    public static func saved(bytes: Int) -> String {
        "\(short(bytes: bytes)) \(savedLabel)"
    }

    /// How the estimate was made, for the faces with room to say: `8.7 MB gross at 4 bytes a token` — the bytes saved, so dividing them by the ratio gives the figure.
    public static func basis(bytes: Int) -> String {
        "\(ByteSize.short(bytes)) gross at \(bytesPerToken) bytes a token"
    }

    /// The one line every face with a transcript scan prints beside its saving: how many whole reads followed a digest of the same file — the share's own `read whole` count — or `nil` where none did.
    ///
    /// Counted, never priced. Pricing it meant joining each digest a transcript holds to the usage-log line that claimed its saving, and three review rounds found that join overclaiming or underclaiming each time; a number that cannot be shown right is not shown. So the saving stays gross and this says by how many reads.
    public static func readAnyway(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        let one = count == 1
        return "\(count) digest\(one ? " was" : "s were") followed by a whole read of \(one ? "its" : "their") file; "
            + "a saving priced on \(one ? "it" : "any of them") is not subtracted"
    }
}
