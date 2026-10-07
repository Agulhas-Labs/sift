//
// Copyright © Agulhas Labs
//

/// What an affected-tests answer cannot see, stated in the answer rather than in documentation.
///
/// This is the load-bearing half of the command and the reason it is a type rather than a string literal at the point of use. Everything else here computes a list of tests; this says what the list is *not*, and the two are only safe together. The command reports and never runs, never filters and never decides what to skip — so the one way it can do real damage is a reader taking "not listed" for "not affected" and shipping on a green run of a subset. Docs/Design.md §2's placement lesson applies at full strength: these lines print **above** the list, because a caveat below the content is a caveat read after the decision.
///
/// Each line names a mechanism by which a test can depend on changed code with no reference the index can find. They are not hypothetical: they are the same boundary `where --refs` already states about code occurrences, plus the ones a *test* specifically runs into — a fixture loaded by filename, a `#selector`, a subclass reached through its base.
struct AffectedBlindSpots {
    /// The permanent limits — true of every answer, at every depth, however fresh the store.
    static var permanent: [String] {
        [
            "reflection, #selector, key paths spelled as strings, @dynamicMemberLookup and any other string-keyed lookup name a symbol in a way the index never records",
            "a subclass override reached through its base type is an occurrence against the base, so a test exercising only the subclass can be missing here",
            "resources, fixtures and golden files loaded by name are not code occurrences at all — a test that reads a file this change rewrote has no reference to find",
            "macro-generated code is invisible to the parser, so a test touching only what a macro expands to is not listed",
            "comments and string literals are not indexed — the same boundary `where --refs` states — so a name that only appears in them is missed",
            "a test that fails on behaviour rather than on a symbol (an ordering, a timing, a total) needs no reference to this change to break",
        ]
    }

    /// The heading that has to be read before the list, in the imperative, because it is an instruction and not a disclaimer.
    static var heading: String {
        "what this cannot see — read before trusting the list below:"
    }

    /// The line that closes the block, and the only sentence in the answer that says what to do with all of it.
    static var conclusion: String {
        "this is a lower bound, not a safe-to-skip set: it reports, it does not run, and it never decides what to leave out. A green run of only these tests is not a green suite."
    }

    /// The depth clause, which changes with the query and so cannot be a constant.
    ///
    /// Given the changed files the resolved walk went on from, it names them as the exception, so a list holding tests past the bound does not sit under a line saying the walk stopped there.
    static func depthLine(_ depth: Int, walkedOn files: Int = 0) -> String {
        let exception = files == 0 ? "" : ", except from the \(files == 1 ? "changed file" : "\(files) changed files") the note above names, walked on past it toward \(files == 1 ? "its" : "each one's") first test, as far as that note says it went"
        return "the reference walk stops at \(depth) hop\(depth == 1 ? "" : "s")\(exception) — a test reaching this change through a longer chain of helpers is not listed, and a bounded walk is bounded"
    }

    /// `diff`'s tests section's clause for the changed files the walk went on from, which says toward a first test and not to one.
    static func walkedOnClause(_ files: Int) -> String {
        files == 0 ? "" : ", and on from \(files == 1 ? "1 changed file" : "\(files) changed files") that reached no test within them, toward \(files == 1 ? "its" : "each one's") first test as far as `sift affected` says it went"
    }

    /// Named only when the answer prints runner arguments, because it is a caveat about the identifiers *in* them.
    ///
    /// This is the one place the answer stops being a lower bound and becomes an instruction, so it is the one place a caveat is not optional. Recognising tests by shape from indexed rows is what lets this cover SwiftPM, XcodeGen and `.xcodeproj` at once, and the whole cost of that choice lands here: the index holds the **module**, `-only-testing:` takes the target, and the two part company wherever a target overrides `PRODUCT_MODULE_NAME`. `xcodebuild` does not skip an identifier it does not recognise — it fails the entire invocation — so a wrong name here does not narrow a run, it loses one. ``TestSymbolReader`` says the cost is stated where it is felt; this is where.
    static var moduleNameCaveat: String {
        "the `-only-testing:` arguments below name the **module**, which is the target name for SwiftPM and for any Xcode target that has not overridden `PRODUCT_MODULE_NAME` — where one has, the identifier is not a target `xcodebuild` knows and it fails the whole invocation rather than skipping that selection; check one before running the set"
    }

    /// Named only when the answer contains a test in an XCTest case nested inside another type, since the two runners' lines each treat that test their own way.
    ///
    /// Measured on macOS: `swift test list` prints such a case as `LibTests.Outer.Inner/testOne`, and every `swift test` filter tried — that id, `Outer.Inner`, the mangled runtime name, and the enclosing target's own filter — runs none of its tests, while an unfiltered run does. `xcodebuild test` ran it only by its mangled runtime class name, `-only-testing:LibTests/_TtCO8LibTests10ChoreTasks9LampTests/testOne` for `ChoreTasks.LampTests`; every dotted or slashed spelling ran nothing and exited 0. So the `swift test` line leaves the test out, and the `xcodebuild` line names it by that runtime name, or leaves it out where an enclosing type is one the name cannot be spelt for.
    static var nestedXCTestCaseCaveat: String {
        "an XCTest case nested inside another type (`Outer.Inner`) is, on macOS, selected by no `swift test --filter` — not its listed id, not its mangled name, not even its whole target's filter, each of which runs none of its tests — so the `swift test` line below leaves it out and only an unfiltered `swift test` runs it; the `xcodebuild` line names it by its mangled runtime class name (`_TtCO8LibTests10ChoreTasks9LampTests` for `ChoreTasks.LampTests` in `LibTests`), the one `-only-testing:` spelling that ran it, and leaves it out, counted, where an enclosing type is declared by an extension or is private, since then that name cannot be spelt"
    }

    /// The line under the `swift test` command that counts what it leaves out, so the command is never pasted as though it covered the list.
    static func leftOutOfTheFilter(_ count: Int) -> String {
        "leaves out \(count) test\(count == 1 ? "" : "s") above in a nested XCTest case, which no filter selects (see the limits above) — an unfiltered `swift test` runs \(count == 1 ? "it" : "them")"
    }

    /// What the `swift test` line says in place of a filter when every test reached sits in a nested XCTest case, so the bare command reads as the whole suite it is.
    static func nothingFilterable(_ count: Int) -> String {
        "no filter: \(count == 1 ? "the 1 test" : "all \(count) tests") above \(count == 1 ? "is" : "are") in a nested XCTest case, which no filter selects (see the limits above), so the only `swift test` that runs \(count == 1 ? "it" : "them") is the whole suite"
    }

    /// The line under the `xcodebuild` arguments that counts the nested-case tests they leave out, because no runtime name could be spelt for them.
    static func leftOutOfOnlyTesting(_ count: Int, noneLeft: Bool) -> String {
        let tests = "\(count) test\(count == 1 ? "" : "s")"
        let reason = "in a nested XCTest case whose runtime class name cannot be spelt (an enclosing type declared by an extension, or private; see the limits above) — "
        return noneLeft
            ? "no argument: the \(tests) above \(count == 1 ? "is" : "are") " + reason + "a run without `-only-testing:` is the only one that selects \(count == 1 ? "it" : "them")"
            : "leaves out \(tests) above " + reason + "a run without `-only-testing:` selects \(count == 1 ? "it" : "them")"
    }

    /// Named only when this repository's own configuration dropped a changed file, because the answer is then narrower than the diff it claims to be about.
    ///
    /// The case this exists for is the one the tool is built for: `roots: ["app"]` on a two-surface product means every edit under `web/` was never examined, and without this line the answer would say "nothing changed — no .swift file differs". A narrowing a reader did not ask for in this query, and cannot see in this answer, is exactly the empty result they are entitled to read as "safe".
    ///
    /// The count is exact and the listing is capped, unlike ``unreadableFiles(_:)`` beside it, because this list is *routine* rather than rare — a monorepo change can put hundreds of files here, and a limits block that scrolls is a limits block nobody reads before the list it qualifies.
    static func excludedByConfig(_ paths: [String], listing cap: Int) -> String {
        let sorted = paths.sorted()
        let listed = sorted.prefix(cap).joined(separator: ", ")
        let more = sorted.count > cap ? ", and \(sorted.count - cap) more" : ""
        return "\(paths.count) changed .swift file\(paths.count == 1 ? " is" : "s are") outside the indexed roots or excluded by `.sift.json` and \(paths.count == 1 ? "was" : "were") not examined: \(listed)\(more)"
    }

    /// Named only when a changed file left the working tree, because its declarations then cannot be read at all.
    static func unreadableFiles(_ paths: [String]) -> String {
        "\(paths.count) changed file\(paths.count == 1 ? " is" : "s are") not in the working tree, so \(paths.count == 1 ? "its" : "their") declarations could not be resolved and nothing is reported for them: \(paths.sorted().joined(separator: ", "))"
    }
}
