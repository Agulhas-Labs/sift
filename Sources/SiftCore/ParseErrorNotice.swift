//
// Copyright © Agulhas Labs
//

/// The one generator for every parse-error warning the tool emits — the `status` listing, the digest banner, and the `where` banner.
///
/// A file SwiftSyntax could not fully parse still yields *some* symbols rather than none, so the failure mode is silent omission: a digest missing a member reads exactly like a type that never declared one. That is the single error a reader cannot detect from the answer itself, which is why Docs/Design.md §2 requires an answer sourced from such a file to say so *inline* — a count in the freshness header names nothing, and a reader who cannot tell whether their own file is among the four has been told only that the risk exists.
///
/// Wording lives here alone: a second phrasing elsewhere would be a latent divergence even while the two agree.
public struct ParseErrorNotice: Sendable {
    /// Paths named in an answer's banner before the remainder is counted instead.
    static var bannerPathCap: Int {
        8
    }

    /// Files named in the `status` listing before the remainder is counted instead.
    static var statusListCap: Int {
        20
    }

    /// The consequence, worded once — every surface states the same risk in the same words.
    static var consequence: String {
        "declarations may be missing"
    }

    /// The affected paths, deduplicated and ordered.
    public let paths: [String]

    public init(paths: [String]) {
        self.paths = Set(paths).sorted()
    }

    public var isEmpty: Bool {
        paths.isEmpty
    }

    /// The line an answer carries when its *own* files are among the affected — the version that changes a reader's behaviour, because it lands where the decision is made rather than in a command nobody runs.
    public var banner: String? {
        line(prefix: "⚠ parse errors — \(Self.consequence) from:")
    }

    /// The line an answer carries when its claim is an *absence* — that a declaration is not somewhere — and the files listed are therefore ones it never drew on.
    ///
    /// A second phrasing, kept here beside the first rather than at the call site, because the two must stay distinguishable on sight and a divergence between them would be invisible. The difference is load-bearing: the answer-scoped banner tells a reader to open these files *because the answer came from them*, and an absence claim inverts that — the file that would disprove it is one the answer never touched, so the list is the whole repository's and the instruction is different. Read as the first, a truncated list of repo-wide paths invites exactly the wrong conclusion: none of the named files mentions my symbol, so the warning is not about my question.
    ///
    /// Truncation is why the recovery is named — see ``recoveryTail``; on a repo-wide list the path that decides the reader's question is exactly the one that can sit inside the `(+N more)`.
    public var absenceBanner: String? {
        line(
            prefix: "⚠ parse errors elsewhere in this repo — \(Self.consequence), and this answer claims a declaration is absent, which a truncated file can fabricate. Not files this answer drew on:",
            tail: recoveryTail
        )
    }

    /// The line an answer carries when what it publishes is a *total* — declarations, files, modules — which a truncated parse leaves low rather than missing.
    ///
    /// The third phrasing, and the third shape of answer, kept here beside the other two for the same reason they are: a divergence between them would be invisible. What separates it is what a reader can do about it. The scoped banner says *open these files, the answer came from them*; the absence banner says *this claim is one a truncated file can fabricate*; both hand back a listing and a file to check it against. A number has no line missing from it. Whatever the parser lost, the count reads as a plain fact and looks identical at every value, so the notice has to say what the number is rather than what the files are — a floor, in the word Docs/AnswerContract.md §4 already uses for a figure that is understated by construction.
    ///
    /// **The files listed are ones the count was drawn from**, which is what confines this to the two answers whose scope is what they count: a repository overview counts the repository, so the list is repo-wide (``acrossRepository(_:)``), and a module digest counts one module, so it names that module's broken files and no others. Where the listed files are instead ones the answer never read, the instruction inverts and ``absenceCountBanner`` is the wording — the same split, and for the same reason, as ``banner`` and ``absenceBanner``.
    public var countBanner: String? {
        line(
            prefix: "⚠ parse errors — \(Self.consequence), so the counts here are a floor: what a truncated file omits shows as a smaller number and nothing else. Counted from these, which did not fully parse:",
            tail: recoveryTail
        )
    }

    /// The line an answer carries when it publishes a count whose *missing* rows would have come from the files listed — which it therefore never read.
    ///
    /// ``countBanner`` inverted, on exactly the inversion ``absenceBanner`` is written for. There the listed files are ones the count was drawn from and a reader may open them to see what the number covers. Here the number is low *because* of them: the declaration that would have raised it is in a file nothing in this answer touched. Read as the first, a list of repo-wide paths beside a list of candidates invites the reader to take it for the files the candidates came from — which is the misreading that sends an agent to read every file it can see.
    ///
    /// So the opening and the label are ``absenceBanner``'s, deliberately: a reader who has learned that *elsewhere in this repo* and *not files this answer drew on* mean "these are not yours" reads this one correctly on sight, without learning a fourth thing.
    public var absenceCountBanner: String? {
        line(
            prefix: "⚠ parse errors elsewhere in this repo — \(Self.consequence), so this count is a floor: a declaration lost with a truncated file is missing from the number and from the list below alike. Not files this answer drew on:",
            tail: recoveryTail
        )
    }

    /// ``absenceCountBanner`` for an answer that served its declarations' source and lists nothing, which names only the files it did not serve from.
    ///
    /// The count is the one in the answer's opening line, and there is no list under it, so the wording says what the number is rather than where it sits. The caller leaves out the files the answer drew on: those carry the scoped banner, and naming one here as a file the answer did not draw on would be false.
    public var servedCountBanner: String? {
        line(
            prefix: "⚠ parse errors elsewhere in this repo — \(Self.consequence), so the count of declarations named here is a floor: one lost with a truncated file is not in it. Not files this answer drew on:",
            tail: recoveryTail
        )
    }

    /// The note an answer carries for a count whose evidence is the *whole repository* while the answer's own scope is narrower — a figure no banner can be scoped to, because the file that would have raised it contributed nothing to cite.
    ///
    /// The fourth phrasing, and the only one that counts the affected files instead of naming them. **That is the difference it turns on, and the rule for choosing between it and ``countBanner`` is one sentence: list the files where the notice stands alone, count them where a scoped banner is already present and a list would nest inside it.** The three banners list paths because a reader can act on them; printed beside the scoped banner a wider list restates that banner's own paths inside a longer one, which is exactly the shape that gets a truncated list read as *none of these mentions my symbol, so this is not about my question*. So where that would happen, this counts them and points at the command that names them.
    ///
    /// **It fires whenever the repository holds a parse error at all, and not only when the count is non-zero.** A type with no extensions, or a query resolving one declaration where two exist, publishes the low number by omission — and that is the worst case rather than the exempt one, because nothing on screen names the figure for a reader to distrust. The scoped banner beside it answers a different question, whether the files this answer *did* read are sound, so the two stand together without either restating the other.
    func floorNote(about count: UnscopedCount) -> String? {
        guard !isEmpty else { return nil }
        let files = "\(paths.count) file\(paths.count == 1 ? "" : "s") in this repo did not fully parse"
        return "⚠ \(count.claim), and \(files), so one lost to a parse error is not counted here. `sift status` names them"
    }

    /// The pointer to the full list, carried only when the cap actually hid part of it.
    ///
    /// Truncation is why the recovery is named at all. The cap holds at eight paths and the one that matters can sit inside the `(+N more)`, which is survivable when a reader knows the full list is one command away and not otherwise. On a list that fits, the same sentence is noise pointing at what is already on screen.
    private var recoveryTail: String {
        let remainder = paths.count - min(Self.bannerPathCap, paths.count)
        return remainder > 0 ? " — `sift status` lists them all" : ""
    }

    /// The shared shape of all three banners: the named paths, capped, with the remainder counted rather than listed.
    private func line(prefix: String, tail: String = "") -> String? {
        guard !isEmpty else { return nil }
        let named = paths.prefix(Self.bannerPathCap).joined(separator: " ")
        let remainder = paths.count - min(Self.bannerPathCap, paths.count)
        let counted = remainder > 0 ? " (+\(remainder) more)" : ""
        return "\(prefix) \(named)\(counted)\(tail)"
    }

    /// Every file in the index the parser could not finish — the notice for an answer whose claim is an absence, built in one place because both faces make the same decision from it.
    ///
    /// Repo-wide on purpose, and the one notice here that is: an absence claim rests on what is *not* in the index, so the file that would disprove it is by definition not among the paths the answer cites. Scoping it would go quiet in exactly the case it exists for.
    static func acrossRepository(_ store: IndexStore) throws -> ParseErrorNotice {
        try ParseErrorNotice(paths: store.filesWithParseErrors().map(\.path))
    }

    /// The `status` listing: the tally the header already reported, plus the paths behind it.
    public static func statusLines(files: [FileRow]) -> [String] {
        guard !files.isEmpty else { return [] }
        var lines = ["⚠ \(files.count) file(s) have parse errors — \(consequence):"]
        for file in files.prefix(statusListCap) {
            let count = file.parseErrorCount
            lines.append("  \(file.path) (\(count) error\(count == 1 ? "" : "s"))")
        }
        if files.count > statusListCap {
            lines.append("  truncated: \(files.count - statusListCap) more files")
        }
        return lines
    }
}

extension ParseErrorNotice {
    /// Which figure a floor note is about — the caller names the count, never the sentence.
    ///
    /// An enum rather than a string, and that is the whole of its job: a call site handed a phrase could write a second wording for the same warning, which is the divergence this type exists to prevent.
    ///
    /// **It is a registry of wordings and not a census of exposed counts.** The class is defined by the query — anything read out of a repository-wide lookup, while the answer citing it is scoped to a few files — so the way to enumerate it is to look for those lookups, never to read this list and assume it is complete. A case is added when a site is found; one that has not been found yet is missing from here and exposed all the same.
    enum UnscopedCount: Sendable {
        /// A type digest's extension count: an extension may be declared in any file, so a truncated one leaves no row and no path to cite.
        case typeExtensions
        /// Every count in a `where` answer — declarations, extensions, conformers — each read out of a repository-wide lookup, and worded together because three notes on one answer is the noise a single one avoids.
        case whereCounts

        /// The half of the sentence that names the figure; the rest is worded once in ``ParseErrorNotice/floorNote(about:)``.
        var claim: String {
            switch self {
            case .typeExtensions:
                "this type's extension count is a floor — an extension may be declared in any file"
            case .whereCounts:
                "the counts in this answer are floors — declarations, extensions and conformers each come from a repository-wide lookup"
            }
        }
    }
}
