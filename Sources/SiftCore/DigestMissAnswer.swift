//
// Copyright © Agulhas Labs
//

import Foundation

/// What a target that resolved to nothing is answered with: the diagnosis that separates a wrong path from an absent name, and the cross-root pointer.
///
/// Split out of `DigestRenderer` itself — which it wraps rather than extends, so the file it lives in is free to be named for what it holds — to keep `DigestRenderer.swift` under the line-length guideline.
struct DigestMissAnswer {
    let renderer: DigestRenderer

    /// The fallback when a target names no local type: local extensions of an external type, else nearest symbols.
    ///
    /// A qualified target has already been tried as a member by this point, so its message says so rather than reporting only the type miss. A *module* qualifier scopes the extension list — five modules extending one dependency type is the monorepo norm, and `digest DesignKit.Theme` asking for one module's extensions must not be answered with all five (dropping the qualifier silently serves every module's extensions whichever module was named).
    ///
    /// Only the extension listings resolved anything; every other outcome is a miss, and says so through `missed` — the redirect to the modules that do extend the type included, since it serves nothing for the one module asked about.
    func renderExternalTypeOrCandidates(name: String, qualifiers: [String], module: String?, wasMemberTarget: Bool, options: DigestOptions) throws -> MeasuredAnswer {
        // A *nested* qualifier scopes the list the same way a module one does, and for the same reason: matching on the bare name alone, `digest URLSession.Configuration` answered with `extension Locale.Configuration` beside it.
        //
        // It narrows only when it finds something. A framework qualifier is not a repo module, so it arrives here as a nested one — while the extension it names is written bare (`extension Color` in a file importing SwiftUI), matching nothing. Filtering unconditionally would turn `digest SwiftUI.Color` into "no type or member named Color" followed by a list of the three Color extensions it had just refused: the self-contradicting answer this branch exists to remove, reintroduced one path over. The same holds wherever module resolution is guessing, since the *real* module name is absent from `moduleNames` and lands in `qualifiers` too. Falling back is never worse than not having filtered, and the header says the qualifier bought nothing so a wider answer is not mistaken for a scoped one.
        let wanted = qualifiers + [name]
        // An extension is evidence of an external type only when the path it is written with names no type this
        // repository declares. A nested type extended by its full path (`extension Outer.Inner`) is the case where
        // it is not: `digest Wrong.Inner` misses on its qualifier, finds the local type's own extension, and would
        // report a type written in plain sight as "declared outside this repo". Matched by the whole written path
        // and never by the bare name, because Swift puts every extension at file scope: `extension Color` is the
        // top-level `Color`, so a nested `Theme.Color` is no evidence against it, and matching on the name at any
        // depth would hide an external type behind every nested type that happens to share its name. When every
        // extension found is a local type's, the miss goes to the wrong-path answer below, which names where the
        // type really is.
        let declaredHere = try renderer.store.typeDeclarations(named: name)
        // Each local extension set aside, by the qualified name of the declaration it extends.
        var ownedHere: [String: Int] = [:]
        var all: [SymbolRow] = []
        for row in try renderer.store.extensions(ofTypeNamed: name) {
            if let owner = try declaredHere.first(where: { try renderer.owns(extension: row, primary: $0) }) {
                try ownedHere[renderer.qualifiedTarget(of: owner), default: 0] += 1
            } else {
                all.append(row)
            }
        }
        let qualified = all.filter { row in
            row.name.split(separator: ".").map(String.init).suffix(wanted.count) == wanted[...]
        }
        // An extension is evidence of an external type only when one of the two paths ends the other: written with
        // the path asked for under a fuller spelling (`qualified`), or written as a suffix of it. The second covers
        // the bare name — the top-level type, which a framework qualifier may well be naming — and a nested path
        // the asked one only prefixes with the framework the extension's file leaves unwritten, so
        // `extension Notification.Name` is evidence for `digest Foundation.Notification.Name`. One written under
        // another parent says nothing about this path: `extension URLSession.Configuration` is URLSession's type
        // and no other, so beside a local `Loader.Configuration` it cannot make `digest Settings.Configuration` an
        // external type. With no such evidence a local declaration of the name decides it, and the answer is the
        // wrong-path one, which names where the type really is.
        let writtenAsSuffix = all.contains { row in
            let written = row.name.split(separator: ".").map(String.init)
            return written.count <= wanted.count && wanted.suffix(written.count) == written[...]
        }
        if !qualifiers.isEmpty, qualified.isEmpty, !writtenAsSuffix,
           let answer = try wrongPathAnswer(name: name, qualifiers: qualifiers, module: module)
        {
            return MeasuredAnswer(text: answer, missed: true)
        }
        let qualifierNarrowed = !qualifiers.isEmpty && !qualified.isEmpty
        let extensions = qualified.isEmpty ? all : qualified
        if !extensions.isEmpty {
            let scoped = module.map { qualifier in extensions.filter { $0.module == qualifier } } ?? extensions
            if let module, scoped.isEmpty {
                // The named module has no extension of this type; listing who does answers the question actually asked.
                let byModule = Dictionary(grouping: extensions, by: \.module)
                    .map { "\($0.key) (\($0.value.count))" }
                    .sorted()
                // The qualified target, for the same reason the hint below carries it: with a nested qualifier in play, `digest Configuration` asks a wider question than the one that got here.
                let qualifiedTarget = (qualifiers + [name]).joined(separator: ".")
                // These counts are of the same fallback set the answer below would serve, so they say so. Without the note they read as counts of `URLSession.Configuration` while counting every `Configuration` extension there is — a wrong number rather than a wide one.
                let counted = qualifiers.isEmpty || qualifierNarrowed ? name : "\(name) (no extension is written `\(qualifiedTarget)`)"
                return MeasuredAnswer(text: ([
                    "no \(name) extension in \(module) — \(counted) is extended in: \(byModule.joined(separator: ", "))",
                    "digest \(qualifiedTarget) serves every module's extensions",
                ] + siblingPointerLines(for: writtenTarget(name: name, qualifiers: qualifiers, module: module))).joined(separator: "\n"), missed: true)
            }
            let qualifiedTarget = (qualifiers + [name]).joined(separator: ".")
            // Both notes, independently. Hanging the widening note off `??` would let a module qualifier
            // short-circuit it, so `digest Core.URLSession.Configuration` would drop the nested qualifier in
            // silence *and* say "in Core" — the wrong answer reading as more scoped rather than less.
            let moduleNote = module.map { " in \($0)" } ?? ""
            let followed = ownedHere.isEmpty ? "every local `\(name)` extension" : "every local `\(name)` extension of a type not declared here"
            let widenedNote = qualifiers.isEmpty || qualifierNarrowed
                ? ""
                : " (no extension is written `\(qualifiedTarget)` — \(followed) follows)"
            let scopeNote = moduleNote + widenedNote
            var lines = ["\(name) — declared outside this repo (or not indexed); \(scoped.count) local extension\(scoped.count == 1 ? "" : "s")\(scopeNote):"]
            var budgeted: [DigestRenderer.BudgetedLine] = []
            var outlineBudget = DigestRenderer.outlineCap
            for extensionRow in scoped {
                budgeted.append(DigestRenderer.BudgetedLine(text: "", counted: false))
                budgeted.append(DigestRenderer.BudgetedLine(
                    text: "extension \(extensionRow.name)\(extensionContext(extensionRow)) — \(extensionRow.module) — \(extensionRow.path)\(extensionRow.rangeDescription)",
                    counted: false
                ))
                for member in try renderer.store.children(of: extensionRow.id) {
                    try budgeted.append(DigestRenderer.BudgetedLine(
                        text: renderer.containerAwareLine(member, options: options, outlineBudget: &outlineBudget),
                        counted: true
                    ))
                }
            }
            lines.append(contentsOf: renderer.paginate(budgeted, options: options, unit: "member lines").map(\.text))
            if scoped.count < extensions.count {
                let elsewhere = extensions.count - scoped.count
                // The unqualified target, not the bare name: with a nested qualifier in play `digest Configuration` asks a wider question than the one that got here, and the recovery hint should not quietly widen it.
                lines.append("(+\(elsewhere) extension\(elsewhere == 1 ? "" : "s") in other modules — digest \(qualifiedTarget) serves them all)")
            }
            // The local types' own extensions are left out of a list of an external type's, and said to be, so a
            // reader who knows the repo extends `Theme.Color` does not take their absence for a missing file. Not
            // where a qualifier narrowed the list, since they were never candidates for it then.
            if !qualifierNarrowed {
                for (owner, count) in ownedHere.sorted(by: { $0.key < $1.key }) {
                    lines.append("(+\(count) extension\(count == 1 ? "" : "s") of \(owner), which this repo declares — digest \(owner) serves \(count == 1 ? "it" : "them"))")
                }
            }
            lines.append(contentsOf: siblingPointerLines(for: writtenTarget(name: name, qualifiers: qualifiers, module: module)))
            return MeasuredAnswer(text: lines.joined(separator: "\n"))
        }
        if let answer = try wrongPathAnswer(name: name, qualifiers: qualifiers, module: module) {
            return MeasuredAnswer(text: answer, missed: true)
        }
        let written = writtenTarget(name: name, qualifiers: qualifiers, module: module)
        // Search on the base name: the FTS sanitizer strips `(` and `:` out of a labeled form, leaving an unmatchable token, so `Engine.start(mod:)` (one wrong label) would dead-end with no suggestions at all. Ranked against the whole path written, the module put back in front of it, so that same miss ranks Engine's own candidates first by the rule `where` resolves the path with, rather than leaving them to be outnumbered by every other type's same-named member.
        let candidates = try renderer.store.searchCandidates(
            prefix: QualifiedPath.baseName(of: name),
            limit: 12,
            qualifiers: (module.map { [$0] } ?? []) + qualifiers
        )
        guard !candidates.isEmpty else {
            // The most absolute absence claim the tool makes: a file the parser could not finish is *exactly*
            // how "no symbol named X" comes to be said about a symbol written in plain sight, and without this
            // the reader has nothing in the answer to suspect it with.
            let text = try (renderer.absenceBanner() + ["\(DigestMiss.noSymbolPrefix)\(name)\(DigestMiss.noSymbolSuffix)"] + siblingPointerLines(for: written)).joined(separator: "\n")
            return MeasuredAnswer(text: text, missed: true)
        }
        // In the class too: "no type named X, here are some near ones" leads with an absence, and a fuzzy
        // candidate is not the declaration asked for. Leaving it out would make the rule something a reader has
        // to know rather than something the answer states.
        var lines = try renderer.absenceBanner()
        lines.append("no \(wasMemberTarget ? "type or member" : "type") named \(name)\(DigestMiss.nearestSymbolsSuffix)")
        for row in candidates {
            lines.append("  \(row.name) — \(row.kind.rawValue) — \(row.module) — \(row.path):\(row.line)")
        }
        lines.append(contentsOf: siblingPointerLines(for: written))
        return MeasuredAnswer(text: lines.joined(separator: "\n"), missed: true)
    }

    /// The answer for a path that names something real but addresses it wrongly, or `nil` when nothing of the name is declared outside the path.
    ///
    /// Said apart from a name that names nothing: answering `Outer.Nested.member` with nearest symbols reads as "you have the wrong name", and a caller who believes that goes looking for a member it was already holding — or reads the whole file instead.
    private func wrongPathAnswer(name: String, qualifiers: [String], module: String?) throws -> String? {
        let under = (module.map { [$0] } ?? []) + qualifiers
        guard !under.isEmpty else { return nil }
        let baseName = QualifiedPath.baseName(of: name)
        let elsewhere = try declarationsOutside(under, named: baseName)
        guard !elsewhere.isEmpty else { return nil }
        let written = writtenTarget(name: name, qualifiers: qualifiers, module: module)
        if let own = try DigestMemberMissAnswer(renderer: renderer).answer(baseName: baseName, qualifiers: qualifiers, module: module, elsewhere: elsewhere.count, written: written) {
            return (own + siblingPointerLines(for: written)).joined(separator: "\n")
        }
        // Repo-wide, unlike every other banner here, because this answer's claim is one of *absence*:
        // "declared, but not under X" is exactly what a file truncated by a parse error produces, and the
        // files that would prove it are precisely the ones missing from the list. Scoping the banner to
        // the cited paths would name every file except the one that mattered.
        var lines = try renderer.absenceBanner()
        lines.append("\(DigestMiss.unresolvedPathPrefix)\(written) — \(baseName) is declared, but not under \(under.joined(separator: ".")):")
        for row in elsewhere.prefix(DigestRenderer.memberCap) {
            try lines.append("  \(renderer.qualifiedTarget(of: row)) — \(row.kind.rawValue) — \(row.path)\(row.rangeDescription)")
        }
        // The list *is* the evidence in this answer — a reader who does not find their member in it
        // concludes it does not exist — so a cut list that does not say it was cut is the same silent
        // under-report the answer is warning about.
        if elsewhere.count > DigestRenderer.memberCap {
            lines.append("  truncated: \(elsewhere.count - DigestRenderer.memberCap) more declarations")
        }
        lines.append(contentsOf: siblingPointerLines(for: written))
        return lines.joined(separator: "\n")
    }

    /// Declarations of `name` when none of them sits under `qualifiers` — the evidence that a path is wrong rather than a name.
    ///
    /// Empty where one of them *does*: the path resolved and only the labeled spelling missed (`Engine.start(mod:)` for `start(mode:)`), which the candidate list answers better, since it names the labels.
    private func declarationsOutside(_ qualifiers: [String], named name: String) throws -> [SymbolRow] {
        let rows = try renderer.store.symbols(named: name)
        for row in rows {
            let chain = try renderer.store.parentChain(of: row).map(\.name)
            if QualifiedPath.matches(qualifiers: qualifiers, chain: chain, module: row.module) {
                return []
            }
        }
        return rows
    }

    /// The target as the caller wrote it, reassembled from the parts the miss path carries separately.
    private func writtenTarget(name: String, qualifiers: [String], module: String?) -> String {
        ((module.map { [$0] } ?? []) + qualifiers + [name]).joined(separator: ".")
    }

    /// The cross-root pointer for a missed target: one line per registered sibling root whose existing index accounts for it exactly.
    ///
    /// A pointer, deliberately not a proxy answer — serving the sibling's digest here would put another repository's content under this repository's freshness header. The parenthetical states the claim's real strength: it comes from that root's *last* index, so it is a lead to follow with a re-rooted query, not a freshness-contracted fact.
    ///
    /// The *whole* target goes to the probe, never its last component. Probing the base name and printing the path would claim what had not been checked: `Type.column` would be answered with unrelated repositories, each of which merely had something named `column` somewhere in it, under a line reading "Type.column is declared in …" — a lead worse than none, since following it costs every one of those repositories opened.
    private func siblingPointerLines(for target: String) -> [String] {
        guard let siblingRoots = renderer.siblingRoots else { return [] }
        let pointers = siblingRoots(target)
        guard !pointers.isEmpty else { return [] }
        return [""] + pointers.map { $0.line(for: target) }
    }
}
