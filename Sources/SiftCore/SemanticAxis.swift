//
// Copyright © Agulhas Labs
//

/// The second freshness axis: the index store cannot self-heal — only a build refreshes it (Docs/Design.md §2).
public enum SemanticAxis: Sendable {
    /// The query was answered from syntax alone; the store, if any, was never opened.
    case syntacticOnly
    /// A semantic query ran but no index store exists.
    case noStore
    /// `status` found no index store — ``noStore``'s fact, pointing at where `status` says it.
    ///
    /// A query's note about the missing store sits directly under its header, so "see note" is true there. `status` names the store on its own `index store:` line further down, and a header sending the reader to a note that is not under it sends them looking for something that is not there.
    case noStoreInStatus
    /// A store exists and is still being read, past this query's budget — the opposite remedy to ``noStore``: ask again, never build.
    ///
    /// Rendering the two alike puts "build the project" in the header of an answer whose body says no build would help.
    case warming
    /// A store exists but opening it failed, so semantics are as unavailable as with ``noStore`` — but the reason differs, and a build does not fix an open failure.
    ///
    /// The open error is left to the body, which already quotes it: it carries a full path, and the header is the line that gets pasted.
    case openFailed
    /// A semantic query ran, every declaration it answered for predates the store's newest unit, and so does every file the answer cites.
    case fresh
    /// A semantic query ran and the store no longer matches the tree: `newerFiles` files it cited have been written since the last build (a declaring file among them refuses outright), and `deletedOccurrenceFiles` files it still holds occurrences in are gone from the tree entirely.
    case stale(newerFiles: Int, deletedOccurrenceFiles: Int)
    /// No store was opened, and file state alone says the tree has moved past the last build: `newerFiles` indexed files have been written since it, and `deletedFiles` files this index dropped since it are still gone.
    ///
    /// `status`'s reading of ``stale(newerFiles:deletedOccurrenceFiles:)``, and worded one step weaker on purpose. A query knows the store still cites each deleted file, because it read the occurrence; this reading never opened the store, so it cannot say the store holds anything in the file — only that the file was here and is not now (Docs/AnswerContract.md §8).
    case staleByFileState(newerFiles: Int, deletedFiles: Int)
    /// No file is stale, but this many declarations have no unit in the store covering them — a different fact from staleness, and one a rebuild may not fix.
    case unresolved(symbols: Int)
    /// No file is stale, but this many indexed test files have no unit in the store: their target was not built (a plain `swift build` builds none), so every reference from them is missing and the store's answer is a lower bound.
    ///
    /// Never read as ``fresh``: a store answering "no test references" for a test target it never compiled states the one thing it could not have seen.
    case partial(testFiles: Int)

    var rendered: String {
        switch self {
        case .syntacticOnly: "syntactic-only"
        case .noStore: "none (no index store — see note)"
        case .noStoreInStatus: "none (no index store — see the index store: line below)"
        case .warming: "warming (index store still loading — ask again shortly)"
        case .openFailed: "none (index store found but failed to open)"
        case .fresh: "fresh"
        case let .stale(newerFiles, deletedOccurrenceFiles):
            "stale (\(Self.staleDetail(newerFiles: newerFiles, deleted: deletedOccurrenceFiles, deletedNoun: "occurrence file")))"
        case let .staleByFileState(newerFiles, deletedFiles):
            "stale (\(Self.staleDetail(newerFiles: newerFiles, deleted: deletedFiles, deletedNoun: "file")))"
        case let .unresolved(symbols): "fresh, \(symbols) declaration\(symbols == 1 ? "" : "s") not found in the store"
        case let .partial(testFiles):
            "partial (\(testFiles) test file\(testFiles == 1 ? " has" : "s have") no unit in the store — references from tests are a lower bound)"
        }
    }

    /// The verdict for a query that opened the store: it must never claim more *or worse* than the body it heads.
    ///
    /// The two refusal causes are different facts and must not be conflated: a file edited since the build is genuinely stale and a rebuild fixes it, while a declaration the store has no unit for is *not* evidence any file changed — reporting it as "1 file changed since last build" would state a falsehood and send the reader to a rebuild that could not help.
    ///
    /// Cited files count as well as declaring ones. A body listing a caller in a file the tree no longer has, under a header saying `fresh`, is the same conflation from the other end — the header claiming *better* than the body — and a deleted file must move the header rather than let the answer go out unchanged.
    ///
    /// It lives on the axis rather than on a renderer because `where` and `affected` reach the same verdict from the same two inputs, and a header that disagreed between them would be a bug no test of either one alone could see.
    static func of(refusals: [SemanticRefusal], occurrences: OccurrenceFreshness, testFilesWithoutUnit: Int = 0) -> SemanticAxis {
        of(refusals: refusals, occurrences: [occurrences], testFilesWithoutUnit: testFilesWithoutUnit)
    }

    /// The same verdict over several stores' judges, each file counted once whichever store cited it.
    ///
    /// Staleness outranks `testFilesWithoutUnit`, which outranks a declaration without a unit: a stale file is the stronger fact and a rebuild fixes it, and a test target the store never compiled hides every reference from it, where an unresolved declaration hides only its own.
    static func of(refusals: [SemanticRefusal], occurrences judges: [OccurrenceFreshness], testFilesWithoutUnit: Int = 0) -> SemanticAxis {
        let staleFiles = Set(refusals.filter { $0.reason == .modifiedSinceBuild }.map(\.path))
            .union(judges.flatMap(\.modifiedFiles))
        let deleted = Set(judges.flatMap(\.deletedFiles)).count
        if !staleFiles.isEmpty || deleted > 0 {
            return .stale(newerFiles: staleFiles.count, deletedOccurrenceFiles: deleted)
        }
        if testFilesWithoutUnit > 0 {
            return .partial(testFiles: testFilesWithoutUnit)
        }
        // A declaration under `#if` with no occurrence recorded is unresolved as one without a unit is: the store answers nothing for it, and no file is shown to have changed.
        let unresolved = refusals.count { refusal in
            switch refusal.reason {
            case .noCoveringUnit, .unrecordedUnderCondition: true
            case .modifiedSinceBuild: false
            }
        }
        return unresolved == 0 ? .fresh : .unresolved(symbols: unresolved)
    }

    /// Both counts are named whenever both are non-zero — they are separate facts about the same store, and reporting only the louder one is how the header comes to claim less than the body already shows.
    private static func staleDetail(newerFiles: Int, deleted: Int, deletedNoun: String) -> String {
        var parts: [String] = []
        if newerFiles > 0 {
            parts.append("\(newerFiles) file\(newerFiles == 1 ? "" : "s") changed since last build")
        }
        if deleted > 0 {
            parts.append("\(deleted) \(deletedNoun)\(deleted == 1 ? "" : "s") deleted since last build")
        }
        return parts.joined(separator: ", ")
    }
}
