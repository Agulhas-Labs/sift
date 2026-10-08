//
// Copyright © Agulhas Labs
//

/// Reference material for rare moments, served by `sift help <topic>` rather than carried in the always-loaded rule.
///
/// `Sift.md` is a path-scoped rule that reloads on every `.swift` file an agent opens, so a paragraph that only ever matters once a build has already gone red — reading a failure block, `flakes`'s counts, the two parse-error banners, root resolution — was being re-sent on every reload whether or not this turn needed it. Moving it behind a command a caller reaches for only when the moment actually arises is what this type is for; `Sift.md` keeps one line per topic naming when to pull it.
///
/// Carried the same way ``SessionPrimer``'s banner is: literal Swift string content, compiled straight into the binary rather than read from a file on disk. The binary reaches every machine that installs the rule; a checkout of this repository does not, so a topic stored as a file beside the source would answer on the machine that built it and nowhere the rule was actually installed.
public struct HelpTopics {
    /// The topic named `name`, or `nil` when nothing carries it — `sift help` alone lists what does.
    public static func topic(named name: String) -> Topic? {
        all.first { $0.name == name }
    }

    private static var runBody: String {
        """
        **The answer opens with a verdict, or says out loud that it has none** — derived from the action the \
        command invoked rather than from whichever `** … **` line turned up, with interruption reported as its \
        own state and a known issue counted apart from failures. Read `⚠` as *this answer cannot be trusted as \
        a verdict, go and read the raw log*: it means the log ended without one, or carried another action's, \
        or declared success over a nonzero exit. Nothing here is ever answered as a pass — not a run killed \
        mid-suite, and not a `swift test` whose Swift Testing half passed while its `XCTestCase`s failed.

        **A gate that fails in bulk** — read the line above the failures before reading the failures. Every \
        red run opens with the same measurement: how many failed, how many distinct kinds of failure they \
        reduce to, how many files they span, and how many landed in a file the working tree has changed (a new \
        file not yet added counts, one git ignores does not) — a line like `666 failures · 210 signatures · 53 \
        files · 0 in changed files` is what separates a broken environment from a broken change. Read it as a \
        measurement and nothing more: it names no cause and suggests no retry, deliberately, and "0 in changed \
        files" is matched by filename rather than by path — the log prints no paths, and the wording says so \
        wherever the number appears. **What follows it is every failure by name while that listing is small \
        enough to serve, and one example per kind once it is not** — the bound is on the size of the answer, \
        not on a count of failures, so forty distinct failures are forty names and six hundred are a sample. \
        Where the block *is* a sample and a signature stands for more than one failure, only the first of them \
        is named — the `×N` counts the rest, and a closing line says how many were counted and never named. \
        **So read the second field before deciding what the block is**: `40 failures · 40 signatures` under a \
        full listing is forty separate things to fix, and `40 failures · 1 signature` is one.

        **Each example says which declaration it happened in** — `in ChartGridTests.assertLayout(at:) — \
        Tests/…/ChartGridTests.swift:20-23 (syntactic)` — so the second round trip asking what is at that line \
        is already paid for. **When the name on the failure and the declaration under it differ, that is the \
        finding**: the framework prints the *test's* name over a line that may belong to a helper, and this is \
        the tool saying so. Where every failure of one signature lands in one declaration the line reads `all \
        117 are in …`, which answers what a bare `×117` never does — 117 broken tests, or one helper 117 tests \
        reach through. Read `(syntactic)` strictly: it is a *containment* fact, parsed from the file on disk \
        and so never stale, and it is never a claim about what the failing line called. The line is absent — \
        silently — when there is no index, when the capture came from another repository, when the filename \
        names two files in this one, or when the location was printed with a directory that does not place it \
        in this repository (a dependency's tests under `.build`, say, which is never indexed); nothing else \
        about the answer changes.

        **A build that fails wide** — the same line, over errors: `200 errors · 1 signature · 40 files · 0 in \
        changed files`, and beneath it one example per kind carrying the count it stands for, because listing \
        200 copies of one sentence is 22.7 KB of answer. A rename, a changed signature or a moved dependency \
        produces exactly that, and the count of *signatures* is what tells you so at a glance. Where the \
        errors are genuinely different — `8 errors · 8 signatures · 8 files` — every one is listed in full, in \
        the compiler's own `File.swift:2:15: error: …` form, which is a `Read` target, so open it rather than \
        grepping for it. An error raised inside a macro expansion is located in the expansion's own buffer \
        (`macro expansion #require:1:54: error: …`), so it ends in `(expanded at File.swift:7)`, the source \
        line the expansion sits at, which is the one to open. Here the changed-files field points the other way from a test run's: an error in a \
        file you just edited is almost certainly yours, and one in a file you never touched usually means \
        something moved underneath you. One line you will not see: `error: <subcommand> command failed with \
        exit code N` is the build system's own exit status, not a diagnostic, and is not counted among the \
        errors — `clang: error: linker command failed …` is, because it names its tool and is the real report \
        of a link failure. **Where that line was the only one the log carried, the whole raw log is served \
        instead.** A nonzero build with nothing left that explains it is the state a short filtered answer \
        must never be given for, so the fallback fires and the output can be *thousands* of lines longer than \
        a filtered one — the one direction this command otherwise never goes. Read that as the tool saying it \
        could not name what went wrong, not as a filter that failed.

        **A plain `swift test` is checked against the tests the index declares** — an unfiltered, serial \
        `swift test` of the package at the repository's root carries one more line under `totals:`, \
        `inventory: 3411 declared, 3411 reported` when the two agree, and `inventory: 3 declared to run, 2 \
        reported — 1 never reported: …` naming the tests that never reported, and any that reported more than \
        once, when they do not. A runner's tally counts whatever reported, so a test process that died takes \
        the tests it never reached out of the arithmetic and the summary can read green over them; this is the \
        line that notices. A test declared at file scope is counted like a suite's and named \
        `Target/(file scope)/f()`; one inside an `#if` this platform does not compile is named apart as not \
        run here, a test the runner itself reports skipped is named `N skipped by the runner, not run` \
        rather than read as one that ran, and one under a condition sift cannot decide, such as `DEBUG`, counts only if it prints a line, \
        so one that started and never ended is never reported. \
        **It is a note and never a verdict: the exit code is the wrapped command's either \
        way** (a run that executed no test exits 4 for its zero, not for this line), and that run is reconciled \
        as zero reported, `inventory: 3 declared, 0 reported — 3 never reported: …`. A filtered, skipped or `--parallel` run, a nested package's run and an `xcodebuild` run print \
        nothing, since each runs a set the root manifest does not bound. A run in scope that could not be \
        checked prints the one line saying why, `inventory: not checked — …`: the checkout has no index yet, \
        which this never builds; the inventory could not be read; every test the index declares was lifted \
        out of the counts; or bringing it up to date and reconciling took longer than 20 s.

        **A test process that crashed is a failure** — `✘ swift test — exit 1 — test process crashed`, the \
        runtime's `File.swift:12: Fatal error: …` line, the test it was in, how many selected tests never started, \
        `totals: ✘ crashed`. A gate that matches `totals: ✘ failed` must match `crashed` too, or match `^totals: ✘`. \
        Its `inventory:` line never reads clean: it adds `test process crashed`. Exit 0 is never a crash.

        **"Has this test failed before?"** — `sift flakes` from Bash, when a red test might be a regression \
        you just caused or might be one that comes and goes. Every wrapped run records which tests it named as \
        failing, so this reports, for tests that have both failed and passed: `5 of 18 · last 2026-08-27 · \
        theGridReflowsAfterARotation()`. **Read it as counts and never as a verdict about a test.** A test \
        named by 5 of 18 runs may fail at random, or may have been failing on a change that was present for \
        exactly those 5 — the tool cannot tell those apart and does not pretend to, which is why nothing in \
        the output says "flaky". So it splits by the content of the tree each run started on: first the \
        tests that both failed and passed on identical bytes under one command line (`2 of 9 on one tree`), then those that failed \
        only on trees they never passed on — which is what a deliberate red, such as a negative gate, looks \
        like — and apart from both, runs recorded before the log kept a tree, whose tier is unknown. \
        Test names are pseudonymised by default, as `usage` and `audit` are; \
        `--unredact` prints them, and `--root` narrows to one repo. Two things it withholds rather than \
        guesses at, both stated in the answer: a run recorded before the log kept failure names is *unknown*, \
        never "nothing failed"; and a run whose command key does not say which action it ran is set aside \
        entirely, because one key covering a build, a test and a clean alike makes any fraction over them a \
        fraction over nothing. **A machine that mostly runs `xcodebuild` will see little here at first** — \
        runs recorded before the log kept an action carry none and stay set aside permanently, so the \
        population builds only from new runs.
        """
    }

    private static var answersBody: String {
        """
        Every index answer opens with a header naming the tree it read (the freshness header on `digest` and \
        `where`; a live one on `search` and `strings`, which read the working tree and store nothing to go \
        stale) and states its own limits inline — refusals, parse-error banners, and the syntactic-fallback \
        caveat all appear in the answer that is subject to them. What follows is what those in-band notices \
        *mean*, and one failure mode that has no notice at all.

        \(AnswerHeaderNotes.body)

        **The header's `semantic:` is the mode that produced this answer, not a property of the tree.** \
        `digest` never opens the store, so it says `syntactic-only`; `status` judges from file timestamps, \
        so it can say `stale (2 files changed since last build)`; `where` consults the store, so it can say \
        `fresh`. A file counts as changed when its contents or its file status moved past the build, so a copy that \
        preserves modification times still reads as changed. On one tree you can therefore see all three in a row: \
        `status` stale, `digest` syntactic-only, `where` fresh (it asked about a symbol in a file no edit touched). \
        In a tree with no index store yet, such as a fresh worktree, `digest` still says `syntactic-only` and \
        `where` says `none (no index store — see note)`: `digest` never asked for the store, `where` asked and \
        found none. They do not contradict; read the one on the answer you are acting on.

        **Syntactic answers** — digests, declarations, extensions — are never stale. Files dirty in the \
        working tree are reparsed before the answer is built, so an edit you just made is already reflected.

        **A parse error truncates a file's symbols rather than discarding them**, so an answer drawn from one \
        can be quietly missing a member. The `⚠ parse errors` banner names the files *this* answer drew on: \
        read them directly before concluding something isn't there. The header's `parse_errors:` count is the \
        repo-wide tally and does not mean the answer in front of you is affected — only the banner does.

        **Read the banner's first clause, because there are two of them and they mean opposite things.** \
        `⚠ parse errors — declarations may be missing from: …` is the one above: those files are what the \
        answer was built from. `⚠ parse errors elsewhere in this repo — … Not files this answer drew on: …` \
        is the other, and it appears on answers whose claim is an *absence* — "no symbol named X", "no \
        declarations found", "could not resolve the path … not under Y", and a nearest-symbols list. There \
        the files named are ones the answer never touched, and the point is the opposite of the first: a \
        truncated file is how a declaration goes missing from the index, so one of *those* files may hold the \
        very thing the answer says is not there. Both lists cap at eight paths and count the rest, so when the \
        second carries a `(+N more)` the file that settles your question can be inside the count — it tells \
        you to run `sift status`, which lists every one.

        **Semantic answers** — callers, overrides, store-recorded conformers — come from the build's index \
        store, and only a build refreshes it. A symbol whose file changed since the last build is **refused \
        with "build the project"** rather than answered from stale data. Take that literally: re-running the \
        query won't help and neither will reindexing. Symbols in untouched files still answer in the same \
        response. Alongside a refusal, `where` adds name-matched **syntactic call sites** — matched on \
        written name over the working tree, never stale. The answer itself prints only a one-line heading; \
        **Call sites** below has the full version.

        **(index store)** With no index store — none has been built for this tree — `where` answers \
        declarations from syntax, and callers, overrides and references do not answer. **To build one:** \
        \(SiftEngine.buildCommandNote). **A nested package needs one more step:** \
        \(SiftEngine.nestedStoreNote). `status` and `affected` carry this recipe in full; a `where` \
        answer carries a one-line pointer here.

        **Call sites.** A name-matched site is a lead to verify, not a resolved fact: the scan matched a \
        written name, not a symbol, so it takes in same-named members of unrelated types and same-named \
        local variables and parameters of that name, and it misses a dynamically dispatched call.

        A property is read and written rather than called, so its uses are listed: every expression \
        spelling its name.

        An enum case is named rather than called — written .name or matched in a case pattern — so its \
        uses are listed: every expression spelling its name.

        A function is named as well as called — handed on unapplied as T.f(x:), as T.f on a type declaring \
        it, or in a #selector — so its references are listed with its calls.

        A type is reached far more often than it is built — through its static members, in annotations, \
        generic arguments, conformances and casts — so its uses are listed under "syntactic uses": every \
        line writing its name, per file, split into production and tests as the store's "used by" verdict \
        is. A line inside its own declaration, or an extension written with its own path in its own module, \
        is counted apart, not as use, and listed too under a --refs sweep with no index store, since a \
        rename changes it; another module's extension of it, or a type of the same name nested \
        elsewhere, is not its own, so the lines inside it stay uses. A bare name that a generic parameter \
        list around it binds, `T` in `func f<T>(_ x: T)`, is that parameter and not listed.

        An initializer is called through its type — T(x:), T<U>(x:), a T.init call, a self.init call or \
        Self.init call inside T, a super.init call in a class naming T as its superclass, an .init call \
        where a declared type is T, @T on a stored property or a parameter where T is declared a \
        property wrapper, and a call passing $label: to a parameter declared with such an @T, which calls \
        T.init(projectedValue:) — and named unapplied as T.init call, so those are listed under T.init, as a \
        function's calls and references are; an .init call whose type the scan cannot tell is not listed \
        but counted after the list, whether or not anything is listed, and a call through a subclass or a \
        typealias is missed. A type declaring no init of its own is still answered as T.init: its \
        declaration, a line saying whether the compiler writes its initializers or it inherits them, and \
        its sites by name. Where types share T's name, the store's reference on a site's line says which \
        it builds, where the store covers the file as it stands and names one of them there. Elsewhere a \
        site is dropped from a type's list, and counted on the name's line, only where a qualifier written \
        on it (for an implicit .init call, on the declared type) resolves fully in the index — through \
        typealiases, supertypes and the typealiases declared inside them — to another scope. Labels never \
        drop a site, since a type may have inits no scan sees (another module's extension, a macro's, \
        literal coercion): labels only another type's inits take keep it, flagged (labels fit Other.T). \
        Its scope — the innermost type around it that declares, inherits or aliases a type of the name, \
        else the top level — only credits it too: a site kept for several types is flagged under each its \
        labels or scope do not name, as is one qualified with a name the index cannot resolve, or inside \
        a type whose superclass or protocol is outside the index.

        After a resolved answer, `where` may also list a property wrapper's @T attribute sites the store \
        records no call at — on a line where the store records the type and no call of its initializers, \
        as on a function's parameter — kept only where the store records a reference to that very type, so \
        a same-named wrapper in another module or nested in a type lends it none. The same block lists the \
        $label: calls of its init(projectedValue:), where the store records none of that initializer and \
        resolves the parameter's @T to that type and records a call of the parameter's own declaration \
        where the call names it; a call is kept where a file those facts come from was written since the \
        build, as is every @T in such a file, even one the store's own row may also list, and the answer is \
        then headed stale. Without a store, a $label: call whose labels also reach a \
        same-named declaration's parameter declared with another wrapper is listed under each, flagged \
        "labels also reach an overload declaring @T". Each site is listed once, \
        under the initializer its labels reach, or once for the type where they reach none or several.

        Label narrowing: a name whose declarations are all functions, or all initializers of one type, \
        keeps only the calls whose argument labels could reach one of them — a defaulted argument left \
        out, a trailing closure standing for its parameter — and its line gives the count by name beside \
        the count kept. A call's receiver is judged only to keep a site: one that may name the method on \
        its type and give it only its instance — Self.m(x) — is kept whatever its labels. Calls that can \
        be dropped: a call of a declaration the query did not match — an override or a witness called \
        through its base type or protocol, where its labels or defaults differ, or an overload a macro \
        generates — judged by the labels of those it matched; a subclass's or a conformer's Self.m(x) \
        naming an inherited method unapplied; and a method given its instance through a metatype held in \
        a lowercase name (let m = T.self; m.run(x)). An initializer's site matching none of the declared \
        initializers stays listed instead, as one the compiler wrote (a memberwise one, init(rawValue:)) \
        or one inherited must, unless the query itself named labels, which drops it too.

        Receiver narrowing: for a qualified query T.m, a call or a property's use written on another \
        type — U.m(x), U(y).m(x) or U.m — is dropped and counted on the name line as "on other types dropped", unless U is T or \
        a subclass of it, a typealias or associated type, a generic parameter in scope, or a name written \
        behind a dot or inside an extension that the repository declares no type for. A call with no \
        receiver or on self is dropped only inside a type that is none of T, its subclasses, its \
        superclasses and the protocols it conforms to, or an extension of one or constrained to one — and, \
        where one of those supertypes is declared outside the repository, only inside a type the repository \
        declares. An inheritance clause is followed through any typealias it names, to every type the \
        alias writes, so a subclass or a conformance written against an alias counts; and a call is kept \
        inside a function whose own where clause names one of those types, and inside an extension of a \
        protocol whose where clause does, or that inherits a protocol whose where clause does. A type or \
        typealias declared inside a function body is never indexed, so a call inside one or written on one \
        is kept. A type with a subscript(dynamicMember:), in its declaration or an extension, or one \
        inheriting from such a type, may hand on any member, so a site written on it or inside it is kept. \
        So is a site written on a type the repository does not declare, which a framework may give one \
        (SwiftUI's Binding), unless it is a standard library, Foundation or Dispatch type known to have \
        none; the name line counts those kept as "on types outside the tree". \
        A receiver the scan cannot type is kept, and nothing is dropped where T is a protocol or \
        a type the repository does not declare. One leading-dot call is dropped and counted the same way \
        under any query, on any type: .m(x) with nothing applied after it — no member, call, subscript, ? \
        or ! — where every declaration of m is an instance member. Implicit member lookup resolves it on \
        the contextual type, and an instance method found there is only handed its instance, so it never \
        ends in that type; where m is also a static member, a case or an initializer, it is kept, and so is \
        .m(x)(y) or .m(x).n(), which may end in the contextual type through what follows, and a leading-dot \
        line inside a postfix #if clause, which continues the expression written above the #if.

        A rule that fired for an answer is flagged on the row it kept, not in the heading: `(may be \
        unapplied on Self)` marks a site kept whatever its labels because its receiver may be the \
        instance, and `(no declared init matches — compiler-written or inherited)` marks an initializer \
        site kept although it matches none of the declared initializers. `(labels reach A or B)` marks an \
        initializer site whose written arguments reach more than one declared initializer, one of them an \
        initializer the list does not stand for, and names every one it reaches. A site whose arguments \
        reach only initializers the list does not stand for is counted in its heading, `N whose labels \
        reach only A`, and listed after the list's own sites under `reaching only A by their labels, with \
        no line of their own above:` — never dropped, since a file written since the build leaves no \
        caller above to list it, and a caller's (N sites) count or the cap on callers lists no line of \
        it. The heading says `labels \
        narrowed` only where narrowing dropped a site. Sites in one file sit under its path, and sites \
        with the same enclosing declaration and flag share a row; a line more than one of those sites falls \
        on prints once, with a (×N) count rather than repeating the line number.

        **A row the store still holds but the tree no longer backs is labelled, not dropped.** The store \
        keeps every occurrence the last build compiled, deleted files included, so `where` can name a caller \
        in a file that no longer exists. Those rows carry `(file deleted since last build)` — or `(file \
        changed since last build)` where the file survives but has been written since — sort after the live \
        ones, and are counted out in the section heading and in the header's `stale (N occurrence files \
        deleted since last build)`. The changed label is decided on the later of the file's mtime and its \
        ctime, so an edit whose mtime was put back (`touch -r`, `cp -p`) still carries it, and so does a file \
        rewritten with the bytes that were built — it over-warns and never under-warns. **Read the label as "do \
        not act on this row"**: an unlabelled row in the same section is unaffected and still resolved. \
        Keeping them listed is deliberate — after deleting a file, this is what separates a reference the \
        delete just orphaned from one that was already dead — and a build is the only thing that clears them.

        **`sift status` reports the same axis without opening the store**, from file state against the \
        store's last build, so its header reads `stale (N files changed since last build, M files deleted since \
        last build)` — each part only when its count is not zero. A file counts as changed when its contents or its file status \
        moved past the build, so a copy that preserves modification times still reads as changed. It says *files*, not *occurrence \
        files*: having read no occurrence, it knows a file was written or removed after the build, not that the store cites it. It \
        may over-warn, and the lines under its header name what it cannot see, which only a query shows.

        **"Still warming" is the opposite of that, and is worth reading carefully.** A large store takes a \
        while to read the first time — minutes on a monorepo — so the first semantic query against a cold one \
        answers with declarations and says it is still warming, rather than holding the call open until the \
        read finishes. Nothing is broken and nothing needs building: the read continues in the background and \
        a later query picks it up. **Ask again in a moment; don't rebuild, don't reindex, and don't fall back \
        to grepping the tree** — that last one is the failure this exists to prevent.

        **Module resolution on a monorepo can be wrong, and says so.** It reads SwiftPM manifests and \
        XcodeGen specs — discovered anywhere in the tree and identified by shape, whatever the file is named \
        — and `.xcodeproj` targets; anything else falls back to a guess from the directory name, and those \
        files still answer — they just answer about a module that doesn't exist. An answer drawn from one \
        carries a `⚠ module guessed` banner naming the files, on the same answer-scoped rule as the \
        parse-error banner: you see it when *your* files are affected, not because the repo has some \
        elsewhere. `status` lists every affected file. No setup is needed for any of the three build systems \
        above, and an upgraded binary re-attributes an existing index on its own, so a banner is a report \
        about an unrecognised build system rather than a step anyone skipped.

        A repo self-indexes on its first query — no setup step, and a slow first call on a large codebase is \
        the index building inside it, not a stall.

        **How `sift status` knows a server is actually still running.** It confirms one is, by checking \
        each recorded process against the start time the kernel holds for it, plus when and why the last \
        one stopped — a stale pid file left behind by a crash reads as a live server otherwise.

        Every query resolves against one repository root. In a session spanning several repos, or rooted \
        above them all, pass `root:` with the repo's absolute path — but a missing one is not a dead end: \
        `digest`, `where` and `search` resolve a rootless query against the indexed root that declares the \
        name — or, for a `digest` of a repo-relative file path, the one that contains that file — and name \
        the root they picked on the line under the header. Failing that, any tool run from a folder holding \
        exactly one indexed repository resolves to it, so a query from a product container like `Orchard/` \
        (which holds `app/` and `web/`) answers rather than refusing. Only a target *several* indexed roots \
        match, or a folder holding several of them, still has to ask, and then it lists just those. Pass \
        `root:` anyway when you know it; resolving costs a probe of every registered root, and the answer is \
        only as good as those roots' last index.

        **If you are a subagent working in a git worktree, this matters to you specifically.** The MCP server \
        belongs to your parent and is rooted where *it* started, so a call with no `root:` would be answered \
        from the parent checkout — a different tree, indistinguishable in the answer, since a worktree shares \
        its parent's `head:` and holds the same symbol names. The `PreToolUse` hook pins a rootless call to \
        the directory you are actually in — but the hook is a separate registration from the server, so on a \
        machine that has only the server, pass `root:` yourself. Either way, **read the header's `tree:` \
        field**: `tree: Sift (worktree agent-1a2b3c4d)` is your worktree, and a bare `tree: Sift` from inside \
        one means the answer came from somewhere else.

        Installing, registering, configuring for a monorepo, and troubleshooting are all covered in the \
        tool's own guide (`Docs/Guide.md`) — point a human there rather than guessing at setup on their behalf.
        """
    }
}

/// Kept apart from the struct's own body, same reason as ``buildOutputBody`` below: `type_body_length` counts a type's own declaration, not its extensions, and this topic's body is long enough on its own to have pushed the struct over the limit once `--count` joined it.
private extension HelpTopics {
    static var queriesBody: String {
        """
        The depth behind `digest`, `where`, `search`, `strings` and `affected` that the short rule's \
        one-line summaries don't have room for.

        **`digest`, for a screen or one member.** A `some View` property or method carries an outline of \
        what it builds, so the shape of a view is answerable without opening it — and views are the \
        biggest files in an app repo and the most wasteful to read whole. `digest Type.member` is the \
        one-call version of the digest-then-ranged-Read loop, for when you know what you want rather than \
        still looking.

        **`digest` and `where` with `--at <rev>`, for a past commit.** "Was this already declared at the \
        base?" is answered from a parse of that revision's files that name the target, read through git — \
        never the index or the working tree — under a header reading `at: <rev> (syntactic, from git)`, \
        with a line counting the files parsed. Callers are matched by name only; a module, `.` or `.md` \
        target is refused.

        **`where refs`, for a rename or delete sweep.** Callers alone cannot do that job: a *type* has no \
        callers at all, and test payloads never appear among them — `refs` lists every reference site, \
        one line per file, not just the calls. Mind the boundary anyway: the index store records **code \
        occurrences only**, so doc comments and string literals naming the symbol are invisible to it. \
        Grep for those before you delete.

        **`where` on a property lists its reads and writes, not its callers.** A `var`, a `let` or a \
        subscript is read and written through its accessors, never called, so the store has no call to \
        list: the section is headed `reads and writes of …`, one row per line marked `read`, `write`, \
        `read and write`, or `referenced` — named with neither, as a memberwise initializer's argument is — \
        and an empty one says `no reads or writes of … recorded in the store` (a witness's: `no direct …`, with what it satisfies) — never "no callers", which \
        would read as dead code. Mind the line under it: a synthesized `Equatable`, `Hashable` or `Codable` \
        conformance reads a property with nothing recorded, so a short or empty list is not proof it can go. \
        A use through a property wrapper's `$flag` or `_flag` — a binding handed to a `Toggle` — is listed \
        as one, marked `read via $flag`, and `refs` sweeps those lines too. A wrapper declared in the same \
        module, or one such as `@AppStorage`, `@FocusState` or `@Bindable`, has its `_amount` and `$stored` \
        uses recorded on the property itself, as a read whatever they do, so those are marked `used via \
        _amount` — never a read the store cannot vouch for. A `didSet` that `@Observable` \
        moves into its generated storage is listed as moved, on the attribute's line, with what that leaves \
        out said under it.

        **`where` on an enum case lists its uses.** A case is named — `.name`, `case .name:` — never read, \
        and called only where a payload is built, so the section is headed `uses of …`, one row per line, \
        and an empty one says `no uses of … recorded in the store`; `CaseIterable` and a raw value's \
        initializer reach a case with nothing recorded, and the line under it says so. A case with \
        associated values answers to its bare name and to its labeled one, `value(_:)`.

        **`search`, for code by shape.** "Every `@Test` function that wraps a call in an unstructured \
        `Task`", "every class conforming to `X` that force-unwraps", "every async function that never \
        awaits". Grep cannot answer these reliably because the pattern spans nesting and line breaks.

        **`search`'s query syntax in full.** Whitespace-separated `field:value` terms, ANDed, negated \
        with a leading `!` — `kind:` `attr:` `name:` `calls:` `uses:` `inherits:` `modifier:` `effect:` \
        `has:` `sig:` `imports:` `path:` `owner:`. For example `kind:func attr:Test calls:Task !has:await`; \
        `imports:HealthKit` finds whole files by an import, and `sig:` matches the signature as written \
        (return and parameter types) without a body walk; `owner:` is the type a member is declared in, \
        its extensions included (`kind:func modifier:static owner:StructuralQuery`); `kind:case` is an enum \
        case, each name of `case a, b` a declaration of its own, named as `where` names it. A miss names the term \
        that removed the last declarations. `name:` matches a case-insensitive substring; every field takes \
        `a|b` for any of several values, each read as the field reads one (`kind:struct|enum`, also written \
        `kind:struct|kind:enum`; `!kind:struct|enum` matches neither), and `name:` `path:` `sig:` also take \
        a regex, `/^open|close$/` (case-insensitive, unanchored). `name:` patterns list whole-name matches \
        first and say how many on the summary line; a `name:` regex that does not compile is read as the \
        words it plainly spells, the reason quoted, or refused in one line, as is a regex that repeats a group \
        (`(ab)+`), since that can take unbounded time. A wrong field name is rejected with the full field \
        list, so guessing costs one call; a bare term is read as `name:`, so `search module resolver` finds `ModuleResolver`; the answer echoes the query as parsed.

        **`search --count`, for "how many".** The header and the summary line — `N declaration(s) in M \
        file(s)` — and nothing past it: no per-match listing. When the matches span more than one \
        module it adds the breakdown a caller would otherwise build by hand with `grep | sort | uniq \
        -c`, sorted by count. The same query without `--count` answers the same two numbers first, so \
        a count taken now and one taken after a change are read the same way.

        **`search`, before writing a helper: does it already exist?** A helper is recognisable by the \
        call it cannot do without, whatever it was named, so ask by that call: an atomic file write is \
        `kind:func calls:rename` (then `calls:write has:try sig:URL`), a debounce `kind:func calls:sleep`, a \
        retry loop `kind:func calls:sleep has:try`, a JSON decode of a file `kind:func calls:decode \
        uses:JSONDecoder`. Terms are ANDed and there is no OR, so two candidate callees are two queries; \
        `sig:` narrows by a parameter or return type (`sig:URL`), `path:Sources` keeps tests out. A hit \
        is a lead to read with `digest Type.member`, and no hit is not proof: a helper built on a \
        different callee answers a different query.

        **`similar`, when you already hold something like it.** `sift similar Type.member` from Bash — or \
        `similar File.swift:12-40` — ranks the declarations whose shape is closest to that one, and names \
        the shared callees that earned each. The gate is rarity-weighted callee overlap measured over the \
        tree it scanned, so a common name like `append` or `map` counts for a fraction of what a rare one \
        like `rename` does — several common ones can still add up, which is why `shares:` lists what \
        actually earned the hit; control flow and written types only order what is already through. A target \
        whose body makes fewer than three calls is answered as **too thin to compare**, with the `search` \
        recipe instead, and an overloaded one lists its candidates. Read it as `search`'s complement: that \
        query asks by the one call a helper cannot do without, this one by a body you already have. Same \
        two limits as `search` — written names, and a lower bound: an empty answer means nothing close by \
        callee or shape, not that there is nothing to reuse.

        **`dupes`, the same comparison as an audit.** `sift dupes` from Bash — or `sift dupes Sources` \
        to narrow it to the files under a path — groups the declarations whose bodies are near-duplicates \
        of each other, across types, with no target to name: pairs that clear 0.50 shared-callee overlap \
        and share enough rare callees to mean it are joined, so A~B and B~C read as one group of three, \
        each with the callees its members share. Run it before a helper is written for the third time. \
        Read it as a lower bound: the same callees do not mean the same behaviour, a body that inlines \
        what another calls is invisible to it, and an empty answer means nothing close by callee, not \
        that nothing is duplicated.

        **`strings`, tracing UI text either way.** Searches the repo's string catalogs by value (any \
        language, case-insensitive) or key, then lists where the key is spelled as a literal in Swift. \
        **When a key has no literal sites**, that key is likely behind a generated accessor — the answer \
        says so; it is not unused. Every query also lists the Swift string literals holding the text, each \
        with its enclosing declaration and `file:line` — the whole answer in a repo with no catalog, where \
        the wording lives in the source. Only text inside a literal counts, never a comment. Literal \
        matching is smart case: any uppercase letter in the query makes it case-sensitive, an all-lowercase \
        query stays case-insensitive.

        **`affected`, read as a lower bound and nothing else.** It reports; it does not run anything, and \
        it never decides what to skip — reflection, `#selector`, string-keyed lookups, macro-generated \
        code, fixtures loaded by name and a subclass reached through its base are all ways a test can \
        depend on your change with no reference the index can see, and the answer lists them above its \
        own list for that reason. Running only what it names is a decision you are making, not one it \
        made for you, and a green run of a subset is not a green suite. The reference walk is bounded \
        (two hops by default) and says so; a store older than your edit **refuses** rather than \
        guessing, and falls back to a name match it labels as one.
        """
    }
}

public extension HelpTopics {
    private static var refusalsBody: String {
        """
        The hook's own accounting, and the shapes it never interrupts — the nuance behind "a lookup of \
        Swift source is answered in place, or let through." (This is `pre-tool-use`'s accounting; the \
        separate `post-tool-use` nudge never denies a call, so none of it applies there.)

        **The outcome is one of two.** Where the index's answer accounts for everything the command \
        would have printed, the call is denied and that answer comes back in the denial, so the round trip \
        a refusal costs is never spent. It is proven against the command's own search for four of the six \
        shapes; the other two — a symbol search across a tree and a whole read of a Markdown document — \
        are handed over unproven, each the offer's own answer: one `where` per name, every site's path \
        shown and bounded by the paths the search named, or the document's heading outline read live \
        from disk. Where it is not — no answered shape for this lookup, \
        an attempt withheld, a budget overrun — the command runs exactly as it would have without the \
        hook. Nothing is ever refused with a bare "call this instead": that cost about four times what \
        the call it named could save. The one exception is a lookup sent in the same message as the \
        index call it would be offered, which is held back with a pointer at that call, because its \
        answer arrives in the same batch of results and so the pointer costs no round trip. The miss is still counted, by `sift audit` and the share, so a \
        shape the hook cannot yet answer stays visible as one.

        **What counts as a search that went around the index.** `grep -n` and `sed -n '/pattern/p'` on a \
        `.swift` file, and `grep -rn Symbol Sources/` across a tree, are text matches where `where` and \
        `search` are resolved answers, and they are counted as lookups that went around the index exactly \
        as the Grep tool is. A numeric window instead — `sed -n '120,160p'` on one file — \
        is a ranged read, not a search, and is covered below.

        **A denial is not a wall and not a permission problem**: re-run the same lookup and it is \
        allowed — for a shell command, that means the reading stage alone (pattern, flags, paths), so \
        changing what rides beside it still counts as the identical re-run. Take the suggestion when it \
        fits — usually it is the shorter path anyway — and re-run when \
        it does not. **A re-run search is never held against you** — it is the hook's own escape hatch, \
        for whenever you are after something the index does not record: a comment, a string literal, \
        wording in a `.md`. A search for text the index does not record — the re-run a refusal offers, or \
        a name no index declares — is not counted against the share either.

        **A read is counted the same way whether or not it was refused first.** A whole read of a Swift \
        file this context has already digested is not refused — the refusal could only repeat the digest \
        you hold — but it is still counted, because that read is the cost the index exists to avoid. A \
        `Read` with `offset`/`limit` of a file an index call located is never counted against you, and a \
        *ranged* read of a file this context has been handed the digest of is never interrupted, in either \
        spelling — `Read` with `offset`/`limit`, or `sed -n '120,160p'`, `head`, `tail` on one file — that \
        is the second half of the loop the hook is asking for. A ranged read of a Swift file nothing has \
        located yet is the lookup itself, and is answered in place with the file's digest exactly as a whole \
        read is; the identical re-run goes through. Where that digest is over the answer's size budget, each \
        window is answered instead with the members its lines overlap — the opening line still names the call \
        as `digest F.swift`, with a note naming the lines actually shown, since the record kept of it is the \
        real range (`F.swift:a-b`), which locates the file without being its whole digest. A bounded answer \
        that would cost more than the lines it replaces is withheld instead, the same as any other over the \
        budget. Where the digest is over the budget and no members answer stands in for it, its first page is \
        served cut to fit, ending in the `truncated:` cursor that pages on from where it stopped. Either way, the ranged read of the member you wanted is then let through. **A whole read's \
        answer says what its own identical re-run costs**: its opening line ends ` — re-run the identical \
        command for all N lines, about K tokens, or Read just a member's line range below with offset and \
        limit.`, N being the file's lines and K its tokens at four bytes each, for a file of up to 2000 \
        lines, the most a `Read` prints by default. The ranged `Read` is the \
        cheaper route, and the one that is never interrupted. Every other answer's opening line keeps ` — \
        re-run the identical command if you wanted its raw output.`

        **The hook asks once per command**, and goes quiet for a while only after a hundred distinct \
        answers — a runaway guard, and the quiet lifts on its own. Only an answer given in place or a \
        build's wrapping spends any of that budget — a command the hook let through was told nothing, so \
        it counts for nothing.

        **Several shapes are never interrupted, and none of them is your job to remember.** Text you are \
        *writing* rather than reading — a `gh issue create --body`, a commit message, a heredoc — is \
        never read as a lookup, whatever the words in it happen to be about. Neither is a count \
        (`grep -c`, or a `wc` in the same pipeline), because the number a count asks for is not one a \
        symbol index measures; nor a directory listing; nor a tree-wide search whose pattern names \
        nothing at all, such as a version literal or a date. A pattern made of Swift's own words is not \
        that — `final class` and `@Test func` are shape questions and keep their nudge, because `search` \
        is exactly what answers them. **A tree-wide alternation carrying a prose branch beside a name is \
        answered for the name, and says what it leaves out**: `grep -rn "UsageWindow\\|stale index" \
        Sources` comes back as `where UsageWindow` with the line `This answer does not cover "stale \
        index"; re-run the identical command to sweep for that.` — and that re-run goes through. One of \
        prose alone is still text, and is let through.

        **Nor is anything no index answer could reproduce, wherever it is pointed.** A grep of one file \
        for prose, a comment marker or a call site — `grep -n "stale gate is open" View.swift`, \
        `MARK:`, `// TODO` — is let through, because a digest records none of them; a grep of the same \
        file for its declarations (`func save`, `final class`) is still that file's digest. So is a \
        pattern hunting a string literal (one holding a `"`), a fixed-string search (`-F`, `fgrep`) for \
        anything but a name, an unresolved merge's `<<<<<<<`, `=======` or `>>>>>>>`, and a search or a \
        whole read of a tree no index holds — `.build/`, a dependency's `checkouts/`, `DerivedData`, \
        `/tmp`. A `git grep` of another revision is no lookup at all, and a `cat` of one file piped into \
        a window (`cat View.swift | head -80`) is the ranged read it stands for. Nor is a read or search \
        whose output a later stage of the same pipeline filters — `grep -rn Symbol Sources | sort -u`, \
        `cat View.swift | cut -d: -f1` — because no index answer prints the lines a filter kept or \
        dropped; a line window after the read is not this and keeps its ranged-read answer instead \
        (`| head -20` prints the opening of that same answer).

        **Nor is anything the index would answer for more round trips than the command costs.** A \
        pattern no Swift name could be is let through — it opens on a `-` (`grep -n -e "--only" \
        HelpTopics.swift`), holds a quote, holds literal whitespace or `[[:space:]]` no declaration's \
        form explains (`"  --only "`), or holds a wildcard dot between two lowercase words \
        (`tab.about`); an escaped `\\s` is none of those, so `grep -n "isProse\\s*("` is refused with \
        that function's digest. So is a grep of one named file printing context around matches that \
        are *not* a member's declaration (`grep -n "matchedLines" -A8 ShellGrep.swift`) — where the \
        pattern is one, the refusal runs it and hands that member's source back, context and all. And \
        so is an alternation of two or more names in the files the search names outright \
        (`grep -n "waitForExit\\|temporaryLog" RunLauncher.swift`): naming a file this way already draws \
        its digest, standing on whichever names it declares, but a digest gives back only the file's \
        shape and locates neither branch's sites — strictly weaker than the one `where` per name a \
        tree-wide sweep of the same alternation would earn, so it is withheld rather than offered. Swept \
        across a tree instead — `grep -rn "waitForExit\\|temporaryLog" Sources` — the same alternation \
        keeps its nudge, because there the names' resolved sites are what a raw sweep cannot give. A name \
        beside prose in the named files is withheld the same way, and for the same reason.

        **On the build side**, a toolchain run is rewritten in place to `sift run -- <command>` where no \
        permission prompt can follow — in `auto` or `bypassPermissions` mode, or where the user's allow \
        rules already cover the wrapped command — and runs filtered in the same turn, its raw log kept \
        under `.sift/runs/`. Everywhere else it keeps its one-shot refusal: `swift test` or `xcodebuild` \
        draws `sift run -- <command>` once, because there is no answer to hand back for a build — no \
        digest of one — and what the refusal spares is a whole build or test log instead of the one \
        sentence a lookup's refusal would cost. The identical re-run is allowed, on the same ledger and \
        the same terms as any other denial. It is still worth reaching for unasked. The judgement is the \
        hook's, so a command that reaches you undenied was one it decided against, or one it had no \
        answer for, not one it missed. A linter run carrying `--quiet` draws none: the flag already drops \
        the progress lines, so there is no log for the wrapping to spare.

        **A build the user's own rules speak for runs as written.** Where an ask or deny rule of theirs matches anything the line \
        runs — any statement of it, one inside a subshell, a loop body, a function body, a `case` arm or a command substitution included — the \
        hook neither rewrites the build nor refuses it with the wrapping named, since either would hand you a command that rule, \
        written for the original, does not match. It is let through, and Claude Code applies the rule to it. So is every build \
        while a settings file has something in it the hook cannot read as JSON, since a rule there is one it cannot see. A line \
        the shell could not run as written (an operator with nothing beside it, a quote or parenthesis left open) is let through \
        the same way, neither rewritten nor refused, since no wrapping of it is a command you meant to run.
        """
    }

    private static var testBody: String {
        """
        **The verdict line names the worst thing first** — `✔ sift test — 214 tests passed across 3 \
        shards`, or `✘ sift test — 4 failed · 1 missing · 1 duplicated`, with the exit code appended \
        where a failure's is not the plain `1`. Under it, the counts line reconciles the plan against \
        what every shard actually reported: `expected · ran · passed · failed · skipped · missing · \
        duplicated`. **Any *missing* or *duplicated* makes the run not green, whatever `xcodebuild` \
        said** — a test the plan assigned that never reported an ending, or one that reported twice, is \
        a shape no exit code speaks to.

        **A missing test is named by the shard that owed it** — `missing: shard 2: \
        DemoUnitTests/CalculatorTests/testAddition()` — and, under it, every crash report written \
        while the run was going, by name: the nearly-always cause of one.

        **Each shard answers with its own line**: tests run, wall clock against what the plan \
        predicted, the tests' own time against both, how many iterations it took, its exit code, and \
        its log path. Wall clock at more than twice the tests' own time draws a line saying so — launch, \
        session start and bundle load, all outside any one test's own time. Under the shard lines, one \
        line times the run itself, phase by phase — `build 12s · enumerate 7s · devices ready +30s · \
        shards 200s · teardown 6s` — where the enumeration runs while the devices boot, and `devices \
        ready` is the wait for them beyond the build and the enumeration they overlapped.

        **A shard is ended at three times its predicted cost, never under a ten-minute floor** — a \
        prediction of a short shard is small enough that host contention alone would blow a \
        proportional bound. `--shard-timeout <seconds>` lowers that floor for a caller who has already \
        measured that a suite never needs it (refused under 30); a shard ended there is named in the \
        notes with the bound that fired it, `(bound Ns, set by --shard-timeout)`, since the default \
        floor needs no reminder but a moved one does.

        **`slowest:` names the individual tests that cost the most, worst first.** A green run keeps it, a \
        SwiftPM package's too: `sift test` with no `--scheme` in a package runs `swift test` split by suite \
        across processes and creates no simulator.

        **Two sentences explain the plan, when either applies**: one where the shard count was lowered \
        from what was asked — too little work for it, or a predicted makespan that would not have paid \
        for another shard — and one where some tests had no recorded duration and were charged the \
        median of those that did.

        **A failure carries its own re-run line**: `re-run just these, serially: sift test --scheme \
        … --device … --shards 1 --only …` — the same invocation that ran, unsharded, on just the \
        failures — since a failure under N-way load is not yet a failure and the same shard run alone \
        may pass, so this is a way to find out rather than a verdict.

        **The sweep runs first, and reports what it found**: a device a dead run of this checkout left \
        behind, swept by prefix and udid before this run creates anything of its own, one line per \
        device it removed and one per device it could not. Under it, the devices line is this run's \
        own — `N simulators created, N deleted` — with any already gone called out, and a device a \
        delete could not remove named along with the command to remove it by hand. `sift test --sweep` \
        runs that sweep alone, without a run, and names each device it deleted.

        **Durations live in `.sift/test-durations.json`**, which is what the lowered-shard and \
        estimated-charge sentences above are reading — a plain `sift run -- xcodebuild test` seeds it \
        too, so a plan's first run is never the only thing that feeds it.

        **`sift test --analyse` answers the other question, and shares none of the machinery above.** \
        It builds nothing, boots nothing and runs nothing: it reads the index for every declared test, \
        reads the `.xctestplan` files off disk, and prints the difference between them. Its verdict \
        line carries five figures with their arithmetic under it — `declared`, `in a plan`, `runs`, \
        `never runs`, and `conditional`, which is reported on its own and folded into neither of the \
        two beside it, because whether a `.enabled(if:)` test runs is decided at runtime and a count \
        that guessed would be wrong in one direction silently. A per-target table follows, and then \
        only the residue: a section with nothing in it is not printed at all.

        **The section worth reading first is whatever the answer found.** A test target no plan names \
        is reported by what the `.xcscheme` files say about it — run by a scheme's `TestAction` with no plan involved, run by nothing at all, or named by no plan and settled by no scheme read here. A `skippedTests` entry naming a \
        swift-testing test is ignored by Xcode and excludes nothing, and so is an XCTest entry whose \
        identifier carries no parentheses — both are named as having no effect, because a reader of \
        that plan believes something is excluded that is not. An entry that *is* honoured is named \
        too: it leaves no log line, no `.xcresult` node and a tally smaller by one, so the advice \
        beside it is to move the exclusion into the test, where every report shows it skipped with \
        its reason. An entry matching no declared test at all is its own case, and never folded into \
        those three.

        **`--plan <name>` narrows it to one plan**, and a name no plan under the repository carries is \
        refused with the names that were found. `--analyse` is refused together with every flag that \
        describes a build or a run — `--scheme`, `--device`, `--os`, `--shards`, `--shard-timeout`, \
        `--only`, `--skip`, `--project`, `--workspace` and anything after `--` — since there is nothing \
        here for one to name. **A repository with no plan at all is answered rather than refused**: SwiftPM has none \
        and `swift test` runs every test in every test target, so there `declared` is the expected set \
        and the answer says so in place of the plan sections.

        `sift test --help` has every flag.
        """
    }
}

/// The topic list itself, kept apart from the struct's own body for the same reason as ``buildOutputBody`` below: `type_body_length` counts a type's own declaration, not its extensions, and six topics' worth of name/summary/body triples pushed the struct over the limit on their own.
public extension HelpTopics {
    static let all: [Topic] = [
        Topic(
            name: "run-output",
            summary: "Reading a red `sift run` block — bulk failures, per-example locations, wide builds — and what `sift flakes` counts.",
            body: runBody + "\n\n" + RunFailingByFile.helpNote
        ),
        Topic(
            name: "answers",
            summary: "What every index answer promises: the parse-error banners, semantic staleness, and how root resolution picks a repository.",
            body: answersBody
        ),
        Topic(
            name: "queries",
            summary: "The depth behind `digest`, `where`, `search`, `strings` and `affected` — boundary cases, query syntax, and how to read a lower bound.",
            body: queriesBody
        ),
        Topic(
            name: "refusals",
            summary: "The hook's own accounting — what counts as a lookup, what doesn't, when it goes quiet, and which build commands it never nudges.",
            body: refusalsBody
        ),
        Topic(
            name: "test-output",
            summary: "Reading `sift test`'s answer line by line — the verdict, the counts, a missing or duplicated test, the per-shard line, and what feeds durations.",
            body: testBody
        ),
        Topic(
            name: "worktree-index",
            summary: "Why `where` and `affected` answer thin in a linked worktree, why the checkout it was cut from is not read in its place, and how to build a store here.",
            body: WorktreeIndexTopic.body
        ),
        Topic(
            name: "build-output",
            summary: "Reading `sift build --analyse` — the clean build it runs, the slowest bodies and expressions, the totals that are never added, and when it refuses.",
            body: buildOutputBody
        ),
    ]
}

/// Kept apart from the struct's own body (rather than one more `private static var` beside `runBody`): `type_body_length` counts a type's own declaration, not its extensions.
private extension HelpTopics {
    static var buildOutputBody: String {
        """
        **It builds, clean, unlike `sift test --analyse`.** It deletes `.build/sift-timing`, runs \
        `swift build --build-system native` into it with the compiler's two timers passed on the \
        command line, and reads what they printed; the manifest is never edited and your own `.build` \
        products are untouched. `--build-system native` is deprecated by SwiftPM, but on Swift 6.4 it \
        is the only one that prints the timings one per line, so a successful build that printed none \
        is refused, never read as nothing being slow — a future toolchain that drops it entirely will \
        need a different flag here.

        **The header is the build it ran** — `✔ sift build --analyse — clean build, 42.3s, 1,204 timing \
        lines over 87 files`. Under it, the slowest function bodies, then the slowest expressions, each \
        `file:line · ms · enclosing declaration`, with `(×N)` where one site was timed N times (a stored \
        property's initializer is checked in every frontend job that needs it; its synthesized accessors \
        are separate bodies at one place). An expression row names its shape too, when it is one of three \
        named at the site from the same parse — `long literal chain` (three or more `+` over literals), \
        `untyped mixed collection literal` (an array or dictionary literal with no type annotation on its \
        binding and elements of more than one literal kind), or `ternary chain` (a ternary whose then or \
        else branch is itself a ternary). Then the files holding the most body time, and the totals: \
        `bodies 12.4s of which the 10 listed are 61% · expressions 3.1s, listed 74%`. **A body's time \
        includes its expressions', so the two totals are never added.** Time spent in dependencies is \
        counted on a line of its own, function bodies and expressions outside any body apart, and never ranked. \
        So is time in a macro expansion's generated `@__swiftmacro_…` buffer, which names no file of the package: \
        its own `macro expansions:` line, bodies and expressions apart. A `deinit` row is named \
        `Type.deinit`, also for a class declared inside a function. `swift build` does not compile test targets, so \
        unless `--build-tests` was passed, and the package declares one, a line says the ranking covers the compiled targets only. The last line names the raw log under \
        `.sift/runs/`.

        **SwiftPM only.** A tree with an Xcode project and no `Package.swift` is refused in one line; \
        `--root` names a package directory. A failed build is answered as `sift run` answers one, and \
        exits with the build's own code. `--top N` sets how many rows each list keeps (default 10).
        """
    }
}

public extension HelpTopics {
    /// One topic: the name it is asked for by, the line `sift help` alone lists it under, and the text `sift help <name>` prints.
    struct Topic: Sendable {
        public let name: String
        public let summary: String
        public let body: String
    }
}
