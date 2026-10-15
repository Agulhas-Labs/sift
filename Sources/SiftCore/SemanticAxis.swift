//
// Copyright © Agulhas Labs
//

/// The second freshness axis: the index store cannot self-heal — only a build refreshes it (Docs/Design.md §2).
public enum SemanticAxis: Sendable {
    /// The query was answered from syntax alone; the store, if any, was never opened.
    case syntacticOnly
    /// The caller turned the store off with `--syntactic`, so whether one exists was never asked.
    case off
    /// A semantic query ran but no index store exists: in this worktree, which has no build directory of its own, or for this tree, which has not been built yet.
    ///
    /// The header says which in place of sending the reader to a note, since the remedy differs: a worktree builds its own store, a checkout builds once.
    case noStore(inWorktree: Bool)
    /// `status` found no index store — ``noStore(inWorktree:)``'s fact, pointing at where `status` says it.
    ///
    /// A query's note about the missing store sits directly under its header, so "see note" is true there. `status` names the store on its own `index store:` line further down, and a header sending the reader to a note that is not under it sends them looking for something that is not there.
    case noStoreInStatus
    /// A semantic query ran about files no open store answers for, each store being a nested package's, which this clause names (`Kit/.build answers only for files in Kit`).
    case noStoreCovering(String)
    /// A store exists and is still being read, past this query's budget — the opposite remedy to ``noStore(inWorktree:)``: ask again, never build.
    ///
    /// Rendering the two alike puts "build the project" in the header of an answer whose body says no build would help.
    case warming
    /// A store exists but opening it failed, so semantics are as unavailable as with ``noStore(inWorktree:)`` — but the reason differs, and a build does not fix an open failure.
    ///
    /// The open error is left to the body, which already quotes it: it carries a full path, and the header is the line that gets pasted.
    case openFailed
    /// A semantic query ran, every declaration it answered for predates the store's newest unit, and so does every file the answer cites.
    case fresh
    /// A semantic query ran and the store no longer matches the tree: the files it cited that were written since their own build (a declaring file among them refuses outright), are gone from the tree, or are new to it, each counted once under its worse kind.
    case stale(StaleFiles)
    /// No store was opened, and file state alone says the tree has moved past the last build: indexed files written since it are counted changed, and files this index dropped since it that are still gone are counted deleted.
    ///
    /// `status`'s reading of ``stale(_:)``, rendered in the same form. A query knows the store still cites each deleted file, because it read the occurrence; this reading never opened the store, so it cannot say the store holds anything in the file — only that the file was here and is not now (Docs/AnswerContract.md §8).
    case staleByFileState(StaleFiles)
    /// No file is stale, but this many declarations have no unit in the store covering them — a different fact from staleness, and one a rebuild may not fix.
    case unresolved(symbols: Int)
    /// No file is stale, but this many indexed test files have no unit in the store, or these non-test targets have files that write the asked name and no unit for any of them: their target was not built (a plain `swift build` builds no test target, `swift build --target` builds one), so every reference from them is missing and the store's answer is a lower bound.
    ///
    /// Never read as ``fresh``: a store answering "no test references" for a test target it never compiled states the one thing it could not have seen, and one answering "1 caller" for a package one of whose targets it never compiled, where that target writes the name, states it of that target.
    case partial(testFiles: Int, targets: TargetsNotBuilt = .empty)

    var rendered: String {
        switch self {
        case .syntacticOnly: "syntactic-only"
        case .off: "off (--syntactic)"
        case let .noStore(inWorktree): inWorktree ? "none (no index store in this worktree)" : "none (no index store for this tree yet)"
        case .noStoreInStatus: "none (no index store — see the index store: line below)"
        case let .noStoreCovering(scope): "none (no index store covers these files; \(scope))"
        case .warming: "warming (index store still loading — ask again shortly)"
        case .openFailed: "none (index store found but failed to open)"
        case .fresh: "fresh"
        case let .stale(files): "stale since last build (\(files.rendered(cited: true)))"
        case let .staleByFileState(files): "stale since last build (\(files.rendered(cited: false)))"
        case let .unresolved(symbols): "fresh, \(symbols) declaration\(symbols == 1 ? "" : "s") not found in the store"
        case let .partial(testFiles, targets):
            "partial (" + Self.partialClauses(testFiles: testFiles, targets: targets).joined(separator: "; ") + ")"
        }
    }

    /// Target names a `partial` header lists before it counts the rest.
    static let namedTargetCap = 3

    /// `target Extra`, or `targets Extra, Other`, at most ``namedTargetCap`` names and then `+<k> more`: how every clause about targets not built names them.
    static func namingTargets(_ targets: [String]) -> String {
        var named = targets.prefix(namedTargetCap).joined(separator: ", ")
        if targets.count > namedTargetCap {
            named += " +\(targets.count - namedTargetCap) more"
        }
        return (targets.count == 1 ? "target " : "targets ") + named
    }

    /// The clauses of a `partial` header, the targets not built first, with how many of their lines write the asked name, then the test files without a unit, each left out where there are none.
    private static func partialClauses(testFiles: Int, targets: TargetsNotBuilt) -> [String] {
        var clauses: [String] = []
        if !targets.isEmpty {
            var findings: [String] = []
            if !targets.written.isEmpty {
                let lines = targets.lines == 1 ? "1 line there names" : "\(targets.lines) lines there name"
                findings.append("\(lines) \(targets.written.joined(separator: " or "))")
            }
            if !targets.unfindable.isEmpty {
                findings.append("its uses of \(targets.unfindable.joined(separator: " or ")) cannot be found by name")
            }
            clauses.append("\(namingTargets(targets.names)) not built — \(findings.joined(separator: ", and ")), not counted")
        }
        if testFiles > 0 {
            clauses.append("\(testFiles) test file\(testFiles == 1 ? " has" : "s have") no unit in the store — references from tests are a lower bound")
        }
        return clauses
    }

    /// The verdict for a query that opened the store: it must never claim more *or worse* than the body it heads.
    ///
    /// The two refusal causes are different facts and must not be conflated: a file edited since the build is genuinely stale and a rebuild fixes it, while a declaration the store has no unit for is *not* evidence any file changed — reporting it as "1 file changed since last build" would state a falsehood and send the reader to a rebuild that could not help.
    ///
    /// Cited files count as well as declaring ones. A body listing a caller in a file the tree no longer has, under a header saying `fresh`, is the same conflation from the other end — the header claiming *better* than the body — and a deleted file must move the header rather than let the answer go out unchanged.
    ///
    /// It lives on the axis rather than on a renderer because `where` and `affected` reach the same verdict from the same two inputs, and a header that disagreed between them would be a bug no test of either one alone could see.
    static func of(refusals: [SemanticRefusal], occurrences: OccurrenceFreshness, testFilesWithoutUnit: Int = 0, targetsNotBuilt: TargetsNotBuilt = .empty) -> SemanticAxis {
        of(refusals: refusals, occurrences: [occurrences], testFilesWithoutUnit: testFilesWithoutUnit, targetsNotBuilt: targetsNotBuilt)
    }

    /// The same verdict over several stores' judges, each file counted once whichever store cited it.
    ///
    /// Staleness outranks `testFilesWithoutUnit` and `targetsNotBuilt`, which outrank a declaration without a unit: a stale file is the stronger fact and a rebuild fixes it, and a target the store never compiled, test or not, hides every reference from it, where an unresolved declaration hides only its own, and `targetsNotBuilt` holds only the targets that write an asked name, so one that could hide nothing from this answer leaves it `fresh`.
    ///
    /// The files the answer lists by written name, given by kind (``WhereChangedFileMentions``), are cited by the answer as surely as an occurrence's, so they count too.
    static func of(refusals: [SemanticRefusal], occurrences judges: [OccurrenceFreshness], testFilesWithoutUnit: Int = 0, targetsNotBuilt: TargetsNotBuilt = .empty, listedByName: [String: FileKind] = [:]) -> SemanticAxis {
        let counted = countedFiles(refusals: refusals, occurrences: judges, listedByName: listedByName)
        if !counted.isEmpty {
            return .stale(StaleFiles(counted))
        }
        if testFilesWithoutUnit > 0 || !targetsNotBuilt.isEmpty {
            return .partial(testFiles: testFilesWithoutUnit, targets: targetsNotBuilt)
        }
        // A declaration under `#if` with no occurrence recorded is unresolved as one without a unit is: the store answers nothing for it, and no file is shown to have changed.
        let unresolved = refusals.count { refusal in
            switch refusal.reason {
            case .noCoveringUnit, .unrecordedUnderCondition, .outsidePackage: true
            case .modifiedSinceBuild, .newSinceBuild: false
            }
        }
        return unresolved == 0 ? .fresh : .unresolved(symbols: unresolved)
    }

    /// Each file a verdict over its refusals, judges and by-name files counts stale, under the worse of the kinds it was found to be (deleted, then changed, then new), so a file two stores cite is counted once.
    static func countedFiles(refusals: [SemanticRefusal], occurrences judges: [OccurrenceFreshness], listedByName: [String: FileKind] = [:]) -> [String: FileKind] {
        var counted: [String: FileKind] = [:]
        func count(_ path: String, _ kind: FileKind) {
            counted[path] = min(counted[path] ?? kind, kind)
        }
        for refusal in refusals {
            switch refusal.reason {
            case .modifiedSinceBuild: count(refusal.path, .changed)
            case .newSinceBuild: count(refusal.path, .new)
            case .noCoveringUnit, .unrecordedUnderCondition, .outsidePackage: break
            }
        }
        for judge in judges {
            judge.deletedFiles.forEach { count($0, .deleted) }
            judge.modifiedFiles.forEach { count($0, .changed) }
            judge.newFiles.forEach { count($0, .new) }
        }
        for (path, kind) in listedByName where kind < .notBuilt {
            count(path, kind)
        }
        return counted
    }
}
