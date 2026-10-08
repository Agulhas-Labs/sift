# sift — design

`sift` reduces the context cost and the error rate of AI-assisted work on Swift codebases by serving
compressed, structurally accurate views of code instead of whole files. One binary, two faces: a CLI for
people, and an MCP stdio server for coding agents. **Scale is a requirement, not a stretch goal** — a
~200-file project and a 5,000+ file codebase are both first-class, and the large profile drives the
storage, memory and output-budget decisions below from the first line of code.

Two rules are carved in stone, and everything else bends around them. **Never retain syntax trees across
files**: parse a file, walk it once, emit compact value records, discard the tree before the next. And
**the MCP server's stdout carries JSON-RPC and nothing else**, with all logging to stderr or a file.

Two principles run through everything that follows. **Refuse with instructions rather than guess** — a
wrong answer is worse than a slow one, because a wrong one is believed, so every freshness or resolution
ambiguity resolves toward naming what is missing and what would fix it. And **a knob every repository
needs is a missing default**: if the tool can read the answer off disk it must, and configuration is the
escape hatch for what cannot be read, never the price of admission.

A `#NNN` reference in this document points to the private tracker the design was developed against; it is
kept as a decision identifier.

The form every answer takes — header, verdict, residue, arithmetic, refusal — is stated once in
[AnswerContract.md](AnswerContract.md), so that a tool built on the same idea can keep the same shape.

## 1. Scope

**In scope:** a syntactic index of declarations (types, members, signatures, conformance names,
extensions); semantic augmentation from an existing compiler index store when one is available; output
compressed for a language model rather than for a person scrolling; explicit freshness on every query
answer (§2's freshness contract names the commands that open otherwise); invalidation driven by git.

**Out of scope, deliberately:**

- **No daemon and no filesystem watcher.** Invalidation is query-time git state plus a content check; a resident
  process is something to supervise, and the latency it buys back is milliseconds.
- **No LSP reimplementation** — no completion, formatting or linting — and **no `sourcekitd`**:
  compiler-argument discovery is the iceberg that sinks that ship, and hover-style queries inside function
  bodies are too unreliable to build answers on.
- **No indexing of dependencies or SDKs.** Only repository sources. Local extensions *of* external types
  are indexed, and a digest of an external type says "declared outside this repository" and lists those
  extensions rather than pretending completeness.
- **No network calls.** Everything local; nothing about a repository leaves the machine.
- **No indexing of non-Swift sources.** Objective-C headers are out. The one non-Swift shape served is a
  Markdown document's heading outline (§3, `digest`), read from disk at query time and never stored.
- **No cross-repository or multi-workspace indexing.** One repository root per index.
- **No writes to source**, with one specified exception — `rename` (§3), the one edit that is mechanical
  once the symbol is resolved. "Help me refactor" stays out: vagueness is where a write tool starts
  guessing. `run --without` sets uncommitted changes aside for one test run and restores every byte,
  checked by content hash. The tool does write its own files: the `.sift/` cache and `~/.sift`, a
  `.sift.json` on `init --write`, the report page, the Claude Code settings `install-hook` edits and their
  `settings.json.bak-sift` backup, and one line of `.git/info/exclude` — never a file the build compiles.
- **No generated agent-instruction file describing the code.** Derivable structure — layouts, type
  inventories, architecture overviews — is what `digest` serves on demand under a freshness contract, so
  writing it to a committed file makes it a cached digest with no invalidation. What such a file is
  legitimately *for* — rationale, pitfalls, invariants — is not in the syntax, so this tool could never
  author it. Writing the wiring that points *at* the tool is a different thing and is fine.
- **No rewritten call, and no permanent block.** Symbols and structure are here, free text is grep's: a
  text match is not a resolved symbol, so a grep is never silently turned into a `where`, and a search is
  never taken away. What ships is §4's advice hook: a lookup is answered in place or let through, and a
  build or test is the one call rewritten to `sift run --` (only where no permission prompt can follow),
  in the open. Nothing is passed off as the command's own output, and a call never becomes unavailable:
  the most advice can cost is a round trip, never the answer.

## 2. Architecture

### Package layout

`SiftCore` holds parsing, storage and query with no I/O framing; `SiftCLI` is the swift-argument-parser
front end; `SiftMCP` is the stdio server, and also holds what both faces share above Core — the usage
log, the transcript audit, the report page, the advice hook's logic and the server
roster — which is why `SiftCLI` imports it. **Core knows nothing of either front end**, both stay thin, and
anything reusable belongs in Core. macOS-only. Dependencies: `swift-syntax`, pinned exactly because it
must track the toolchain deliberately rather than drift; `swift-argument-parser`; Yams, for XcodeGen
specs; system SQLite; and `indexstore-db`, which publishes no semver tags, so a release branch matched to
the toolchain is pinned by revision. The JSON-RPC framing is hand-rolled — about 150 lines — rather than
taken from the MCP Swift SDK, which is pre-1.0 with a moving API against an exact-pin policy.

### Storage

**SQLite, not JSON**: at 5,000 files a JSON blob can be neither partially loaded nor partially updated.
WAL mode, at `<repo>/.sift/index.db`, kept out of git by `.git/info/exclude` rather than a committed ignore.

**A tree that cannot be written gets its index in memory.** A vendored checkout under a package cache, a CI
read-only mount or another user's checkout has nowhere to put `.sift/`, and refusing every command there would
refuse the four that never open the index (`search`, `similar`, `dupes`, `strings`) along with the rest. So
where `.sift/` cannot be made, or `.sift/` or its `index.db` is there but not writable, the engine opens the
index in memory for its own life instead, and writes nothing under the tree. Only a permission refusal (no
write permission, a read-only volume) is read that way; any other failure to open the store still fails, so a
corrupt or locked index is never quietly replaced. The in-memory index is built and kept fresh exactly as the
file is, so the header still measures the tree; what changes is the cost — each CLI command parses the whole
tree, while the MCP server keeps one engine per root and so pays once per session — and the answers say it:
`digest` and `where` carry a note under the header naming the in-memory index and why, and `status` prints
`db: in memory` in place of a size. `index` and `reconcile`, whose whole effect is the stored index, refuse in
such a tree with one line saying the tree is not writable and that the query commands index it in memory on
each call. The hook never pays that parse: it is a process of its own per call, so an in-memory index would
be a whole-tree parse on every Read or grep of a `.swift` file (1.3–1.9 s at 3,000 files, measured, and a
back-off only past the 3 s budget). Before it opens an engine it asks where the index would live
(`SiftEngine.wouldKeepIndexInMemory`, a stat and an `access` call, making nothing under the tree), and where
the answer is memory it withholds the in-place answer as `treeNotWritable`: the call runs as it would without
sift, and the withholding is logged like any other. A document outline, which parses nothing, is still served.
No relocated cache under another directory: it would be a store with no owner to prune it (§6),
keyed by a path that moves, for a tree that is read-only precisely because it is not ours.

```
meta(key, value)      -- indexed_head, resolution_fingerprint, last_dirty, incremental_count
files(id, path, mtime, size, content_hash, module, module_guessed, imports, parse_error_count)
symbols(id, file_id, parent_id, kind, name, line, column, end_line, access, is_static,
        is_stored, signature, doc_summary, if_config, view_outline)
inherited(symbol_id, name, position)      symbols_fts   FTS5 over symbols.name
```

Every table and column name is a typed constant (`FilesTable.contentHash`, …), and every statement the
store runs is built from those constants in a small per-area enum under `Sources/SiftCore/SQL/` — no
query builder or DSL, since the schema is four tables and a DSL would hide the SQL; the constants exist so
a renamed column fails to compile everywhere it is read instead of failing a query at runtime.

The schema version is `PRAGMA user_version`, readable before any table exists (§6.6). `view_outline` holds
the outline a digest prints under each `some View` property or method — the containers, the screen's own
view methods and its `if`/`switch`/`for`, each with its line — because a view's declarations alone say
nothing about the screen, and views are the largest files in an app repository.

The non-obvious column decisions. **`end_line` is load-bearing**: a digest prints each member as
`file:start–end`, so the caller fetches one method body with a ranged read instead of re-reading the file.
**`doc_summary` is the doc comment's first line only**; full doc text stays in the file. **`if_config`
tags both branches**, because the active configuration is unknowable without build settings — two
same-named symbols under different conditions are honest rather than duplicates, but untagged they look
exactly like §6.1. **`inherited` stores the inheritance clause as written**, less type attributes such as
`@unchecked` and `@retroactive`, since syntax alone cannot tell a superclass from a protocol; the reverse
lookup on it answers conformers-of with no build at all. A composition (`Reading & Ledger`) is one entry, so
that lookup reads each of its components at query time, skipping comments and the `>` of a `->`. **There is no `usr` column** — USRs resolve at
query time from the declaration's location, and persisting them creates a second staleness axis. **Paths
are repo-relative with symlinks resolved**, one canonical form per file, or §6.1's delete-then-insert
quietly stops matching. FTS5 is a plain content-bearing table keyed on the symbol id, so delete-by-rowid
works.

`PRAGMA foreign_keys = ON` must be set **on every writing connection** (the read-only probe of another
repository's index deletes nothing, so it does not): SQLite defaults it off, and then every
`ON DELETE CASCADE` here is a no-op. **Extensions are symbol rows** (`kind = extension`, name = the
extended type path as written, members parented to the extension row), and a type's digest aggregates its
declaration plus every extension whose written name matches. That is name-based, so same-named types in
different modules can collide: the output says so whenever more than one candidate exists, and semantic
mode disambiguates by USR.

### Module resolution

Each file records a module, merged from four sources with the config map winning ties by longest prefix.
**SwiftPM manifests are parsed syntactically** — each source-bearing target with a literal name mapping
its literal path, plus every directory under `Sources/` and `Tests/` beside it mapped by convention to a
target of its own name, a declared path winning where it names that exact directory; parsing rather than
executing means no toolchain dependency and no arbitrary code execution, and a computed path degrades to
the convention scan. **XcodeGen specs are identified by shape, never by name**: any shallow enough
`.yml`/`.yaml` with a top-level `targets:` mapping that resolves to sources, with includes and templates
merged key by key and chained, a target's own sources concatenating with its templates', and `excludes:`
honoured. **`.xcodeproj` targets** come from the pbxproj, an OpenStep plist Foundation reads directly, so
there is no vendored parser. **A config path-prefix map** is the fallback.

All three are *discovered* by one shared walk that closes bundles, follows symlinks logically, never enters
a hidden or excluded directory (§5 — the walk and the enumerator apply one rule, so a build file cannot name
modules for files the index will never hold) and honours the configured exclusions, because **a supported
build system is only supported at the paths the tool looks in** — a resolver pinned to where one house
convention puts its files reads as support while being false for every other layout. A stale spec entry
must not claim a same-named tree elsewhere: a claimed prefix counts as resolved, so it would answer with a
module name and *no* guessed-module banner, strictly worse than the guess it replaced. Reporting counts
*contributions*, not candidates, or a repository resolving nothing prints the same line as one resolving
everything.

Two invariants sit under all of it. **Manifests are inputs to resolution, never subjects of it** — the
enumerator excludes them outright, because indexing one mints a phantom module from its directory name
that no module map could clear. And **attribution is invalidated by a resolution fingerprint**: a file's
module depends on inputs *outside* that file — the manifests, the specs, the config map, and the
resolver's own logic carried as a hand-bumped version — which content-keyed invalidation can never see
change. A content hash over all of them is stored, and any query that finds it moved re-attributes every
file: a path-to-module recompute, no reparse, cheap enough to be unconditional.

### Parsing

SwiftSyntax: parse, walk once with a visitor, emit value records, discard the tree, because holding
thousands of trees is the memory cliff at scale. Parallelism is a task group bounded to the active
processor count; writes are batched one transaction per N files, never per file. **Signatures are source
slices, not reconstructions** — first attribute through the return or inheritance clause,
whitespace-normalised and stored whole (an answer line cuts it at 200 characters, except a digest member
line, which wraps at parameter boundaries and past 800 characters cuts the list with a count of the
parameters left off), a property's initializer kept whole up to 44 characters and dropped beyond that
rather than cut — because reconstructing from syntax nodes loses exactly what modern Swift work needs
visible: `@MainActor`, `nonisolated`, `async`, `throws`, `some`/`any`, availability. **Parse errors are
surfaced, never hidden**: a file that fails to parse cleanly still indexes, but its error count is
recorded and stated in the freshness header and inline on any answer touching it, because a digest missing
a member reads exactly like a type that never declared one.

**The notice is answer-scoped** (the banner lists the files the answer drew on; a repository overview is
repo-wide, a module digest names its own module's broken files) **with two exceptions.** (a) An answer
whose claim is an absence — "no symbol named X", "no declarations found", "declared, but not under Y", a
nearest-symbols list — inverts: the file that would disprove an absence is by definition not among the
files drawn on, so it carries the repo-wide list, in **different words** from the scoped banner, whose
instruction to open the named files is false here. (b) Any figure read out of a repository-wide query, in
an answer scoped to fewer files than that query reads, says the count is a **floor** (§4 of
AnswerContract.md): a file truncated before the row it would have contributed leaves no row and no path, so
the scoped banner falls silent about exactly that file. The class is defined by the lookup, not a site
list. Today's sites: a type digest's extension count, both ambiguity answers (over types and over
members), and all three of `where`'s counts (declarations, extensions, conformers), which share one
notice — worded for one, it would tell a literal reader the others are *not* floors — and fire whenever
the repository holds a parse error at all, even at a count of zero, which is the worst case rather than
the exempt one.

**List or count, by one rule:** the notice lists the affected files where it stands alone, and counts
them, pointing at `sift status`, where a scoped banner is already present and a list would nest inside it.
The ambiguity answers carry no other banner, so they list; a type digest and a `where` answer usually do,
so they count. A listing notice says which kind of list it is: where the files are ones the count was
*drawn from*, the reader may open them to see what it covers; where the number is low *because* of them
(the ambiguity answers), the answer never read them, and an unlabelled list reads as *here is where these
came from*.

**What would tell us this has become decorative.** Mid-edit files are a normal state, so these notes fire
whenever a file is mid-edit, and a marker present on every answer stops being read. The accepted trade is
that a wrong answer is worse than a slow one. **The signal to revisit is the repository carrying parse
errors through most of a normal editing session** (`parse_errors:` in the freshness header is the
measurement); the answer then is to narrow *when* the notes fire, never to make the counts silent.

### Semantics

The index store opens **lazily** — only when a query needs cross-file reference data, never at startup and
never for a syntactic-only query, because on a large codebase it is large and opening it is not free.
Discovery order: an explicit config path; `buildServer.json` at the root, taking its index-store path or
else the workspace it names; SwiftPM's own `.build`, in either layout — `.build/out`, where Swift Build
(SwiftPM's default build system as of Swift 6.4) writes the store whatever `-index-store-path` says, or the
native build system's `.build/index/store` and per-configuration `.build/{debug,release}/index/store` —
which exist after a build with indexing enabled; then a scan of derived data for a workspace path inside
this repository, the two compared in canonical form, since Xcode records the path as the filesystem
spells it and a root arrives however its caller spelled it (through `/tmp`, or case-folded).
**Among SwiftPM candidates holding a store the newest unit wins**, an earlier candidate keeping a tie (the
scan applies the same rule across its entries): a toolchain change or a `--build-system native` build
leaves the older store behind, and a fixed order would anchor staleness at the wrong build. The rule holds
between the two native configurations too. `.build/debug` is no guide: under Swift Build it is a symlink
into `.build/out/Products/Debug`, which holds no store. **The newest unit is one file, not a whole
build** — the approximation the staleness anchor makes everywhere: a partial build (`swift build --target
X`) can win, and its units for everything it did not compile are older than the tree yet read as fresh.
**The scan passes over every entry that describes some other tree**, because at a different commit such a
store would name callers that do not exist here and miss ones that do, and newest-unit-wins would
otherwise prefer it whenever it was built last. Three kinds are passed over: a workspace that no longer
exists (Xcode keeps an entry after `git worktree remove` deletes the folder); one under a directory the
index never covers, judged by the indexer's own rule applied to the path *below* this root (a hidden one
such as `.claude/worktrees`, or a vendored one); and one inside a *nested* checkout (a live linked
worktree of this repo, or any other repo checked out beneath it). Querying from a nested checkout itself
still finds its own entry. A candidate is recognised as a store by its shape, a versioned directory
(`v5`, `v6`, …) holding a `units` subdirectory: a configured `indexStorePath` pointing at a build root
instead of the store itself must be rejected rather than accepted and read as permanently stale. The shape
check and the staleness anchor read the same directory — the highest-numbered `v<N>` holding `units`. **A
rejected `indexStorePath` is said, not skipped over silently**: `status` and the no-store note both name
it (`indexStorePath 'X' in .sift.json is not an index store (no v<N>/units under it)`, likewise for
`buildServer.json`). The index-store library comes from the active toolchain, and each store is ingested
into a cache of this tool's own (below), so a warm reopen is instant.

**If nothing is found, semantic queries name the exact build command for the tree's shape** (a SwiftPM
root, an `xcodebuild` scheme with `-workspace` when there is one, the iOS simulator destination an iOS
project needs, a nested package or custom `-derivedDataPath` needing `indexStorePath` in `.sift.json`,
pointing at the directory holding `v<N>/units`) **and say that declarations still answer from syntax while
callers, overrides and references do not.** The string lives in the store-less note builder. A bare
`xcodebuild build` with no scheme never passes `-index-store-path`, which is why the scheme form is what
gets named. A linked worktree gets a one-line note of its own: its own build directory does not exist, and
the checkout it was cut from is deliberately *not* borrowed, since that store describes a different tree
and would name callers at the wrong commit. The note says the worktree has none and points at
`sift help worktree-index`, which carries that reasoning and every build command; **where a `Package.swift`
sits at the worktree's root it names `sift run -- swift build --build-tests` in the same line**, since that is the one
command the reader then needs, and a bare pointer sent agents to `grep` instead. It never builds on demand.
**`where` carries a one-line form of the note on its mode line**, since a tree with no store is asked of
again and again and the recipe was most of what each answer said: which tree has no store (`no index store
for this tree yet`, or `no index store in this worktree`), each `indexStorePath` setting read and rejected,
and where the recipe is: `sift help answers, section (index store)` for a checkout, `sift help
worktree-index` for a worktree, with `sift run -- swift build --build-tests` kept where a `Package.swift`
sits at the worktree's root. Both topics quote the same build command and config key; other answers carry
the note unchanged.
The header's semantic axis reads
`none (no index store — see note)` either way, rather than answering from degraded guesses. `status`
carries no such note under its header, so its header reads
`none (no index store — see the index store: line below)`.

**In-tree `xcodebuild` stores are read as additional sources, for `where` only.** A target the package
build never compiles — a UI-test runner built from its own `.xcodeproj`, say — has no unit in the primary
store, but a gate that ran `xcodebuild … -derivedDataPath .build/<dir>` left one at
`.build/<dir>/Index.noindex/DataStore`. Discovery lists every such store whose derived-data directory sits
inside a directory git ignores (asked of git in one `ls-files --others --ignored --directory` call, so an
unignored directory is never read and `.git` never walked), at most two levels below an ignored directory
and four path components below the root, never inside a nested checkout, never through a symlink and never
inside `.sift`, in path order, and never the primary store again. **The walk is bounded, ordered and
remembered**: breadth first across every ignored directory at once, but a directory that looks like build
output — one already holding `Index.noindex`, or spelled `.build`, `build`, `DerivedData`, `xcbuild`, `out`
or ending `-dd` — is queued ahead of every directory that does not, at every level, so a real store under
a build-named directory is found before the cap even beside a vastly wider sibling (`node_modules`).
Stopped after 2,000 directories: an ignored `node_modules` of sixty thousand costs what two thousand do,
and when the cap cuts the walk short the `where` mode line says so in one clause (`in-tree walk cut short
at 2,000 directories`) and the project-ownership hint below is withheld, since its advice can already be
exactly what happened, just past where the walk reached. An engine reuses its last walk while git lists
the same ignored directories and every visited directory keeps its modification date, and checks afresh
which of the walk's build directories holds a store. Each store is opened through a cache of its own by
the same rules as the primary, and **an open that discovery no longer names — a store deleted, or rebuilt
under a new units directory — is let go on every query that reads in-tree stores**, whatever the
primary's state. **A declaration belongs to the first store that resolves it** — the primary, then the
in-tree stores in path order — and every relation, reference and staleness judgement for it is read from
that store alone, against that store's own build anchor; stores are never merged hit by hit. Where no
primary exists, `where` answers from the in-tree stores alone (`in-tree store via .build/<dir>`), and
nothing else changes: the primary is never replaced by an in-tree store, so `status`, the deletion
ledger's seed, `affected` and `diff` see exactly the primary store, or none. The mode line names each
in-tree store that answered (`index store via .build; in-tree store via .build/<dir>`) — **named the
moment it owns a declaration, before that declaration's staleness is judged** — and each one still loading
or failed to open; a declaration no open store resolves, while an in-tree store still loads, reads
`warming` rather than unresolved, **but never where a refusal against that declaration is already the
stronger fact a loading store could not change**. A stale declaration owned by an in-tree store ends its
refusal `; rebuild with -derivedDataPath <dir>`, naming that store's own directory; **one SwiftPM's `.build`
owns ends it with the command itself**, `` ; rebuild with `sift run -- swift build`, then retry ``, adding
`--build-tests` where a refused file imports XCTest or Testing, since a plain `swift build` never rebuilds a
test target (in `where` and `affected` alike, which refuse in the same words). A test-file
declaration SwiftPM's store has no unit for is refused with `` ; build with `sift run -- swift build
--build-tests`, then retry ``, because an unbuilt test target is the commonest such case and "build this
target" does not say how; any other declaration without a unit keeps the generic advice, since a non-test
file SwiftPM's own build left uncovered is usually compiled out (`#if`), which no build fixes.
**Where a
declaration's file has no unit in any store and a `.xcodeproj` or `.xcworkspace` sits in its directory or
an ancestor's**, `where` adds one line naming the project and how to build it into the tree (`<dir> is
built by <Project>.xcodeproj; build it with -derivedDataPath inside the tree for semantic answers`),
whatever the file's date; a file a store covers but that was edited since keeps the stale refusal alone,
and a file with no project owning it says nothing new. The hint is withheld while an in-tree store loads,
when the primary is already a DerivedData store (a miss under it is the declaration, not the build), or
when the walk was cut short; the generic "build one" advice is dropped when a hint is present, so one
answer never says two things that could disagree. `digest`, `search`, `affected` and `diff` read the
primary store only.

**Each store has a cache of its own, and no cache answers for a store it was not filled from.** The cache
is `.sift/isdb/<key>`, the key a hash of the layout, the store's canonical path, and the identity — inode
and creation time — of the `v<N>/units` directory the shape check and the anchor read. IndexStoreDB never
forgets a unit: a removal is raised only for a unit seen to vanish while that cache was open, so a cache
filled from another store answers `fresh` for a call the tree no longer makes, from a file older than the
build and so with no modified-since label. Two ways in: discovery moving between stores, and a store
deleted and rebuilt at one path (`rm -rf .build`, `swift package clean`). The path tells the first apart
and the directory's identity the second; not the device number, since an external disk can come back
under another one at its next mount and re-import every store on it for nothing. **Per store**, so
switching back (`--build-system native` and back, or the DerivedData scan alternating between two
entries) finds the other cache still warm instead of re-importing a store that takes minutes on a
monorepo. **Reclaimed, not accumulated**: each cache names its store in a `store` file, every open
removes each sibling whose store is gone, has another identity now, or names none, and empties the flat
`.sift/isdb/v<N>` of earlier versions, so the caches on disk are bounded by the stores that exist.
**Never out from under a running process**: IndexStoreDB moves the database a process opens into a private
`v<N>/p<pid>-…` copy and back on close, so a cache holding a live process's copy is left until that
process lets go; a `-dead` name is not such a copy, whatever pid it carries. **A cache comes into being
whole**: made under `making-<pid>-t<start>-…` (a name reclamation passes over while that maker runs; the
start time is the kernel's, so a reused pid cannot pass for the maker), marked, and renamed into place;
what reclamation removes it renames aside first, so nothing is half-removed under a name an open reaches.
A race between creating a cache and reclaiming one costs at worst a cold import, never a failure
remembered for a store that is there, and never another store's unit. The protocol's details live in the
cache type's doc comment and its tests. **The key is read again once an open settles**, since
IndexStoreDB reads the store after the key is named, through a cold import that can run for minutes: a
store replaced in between would fill the cache named for the old store with the new one's units. An open
whose store changed discards its cache before letting go of it (renamed aside while still open; if that
fails, the open's own copy is renamed to a `-dead` name), or the cache would wait under a key the old
store brings back if it returns to its path (`mv store x; …; mv x store` keeps its inode and creation
time). The query reads the key again too: an open whose store's key changed is set aside, neither
answered from nor remembered as a failure, and the query opens the store there now within what is left of
its budget; past it, that open goes on in the background and the answer says warming. **The key carries
its layout**, so no cache an earlier per-store version named is ever opened; each version reclaims what
the other left once nothing holds it, at the cost of a cold import.

**The residuals**, none detected: a store that loses units in place, its directory kept (no SwiftPM
operation was found that does it, and `sift reset` clears it; a running server goes on answering from
the database it has open until a build makes it reopen, or it restarts); a store moved away and back
while one open reads it; **one store holding two configurations** (native builds of both that pass one
`-index-store-path`, as `-Xswiftc -index-store-path .build/index/store` does, write debug and release
units into one store, and no key can reach it; building the other configuration again, or deleting the
store and building once, clears it; the default layouts do not hit it); and a filesystem that reports no
creation time (NFS reports zero), where a rebuilt store's directory that gets its predecessor's inode
brings back the rebuilt-in-place case. An open cut short from outside Sift (a reset) fails like any other
and is remembered for its store, by a server until the next build or restart. Last, **while an earlier
version's server runs alongside this one on the same repo, an open can fail transitionally**: the two
versions' reclaimers compute different keys, so in the microseconds between one's `prepare` and
IndexStoreDB's own creation of its copy the other can discard the cache. It needs two versions open on
one repo and is gone once every server is this version, so no code fix is warranted.

**A cold store is waited on for a budget, not for as long as it takes.** A large store's first read runs
to minutes, which from the caller's side is indistinguishable from a hang, so the open runs on a thread of
its own and a query waits five seconds for it. Past that the answer carries declarations and says the
store is *still warming* — found, being read, nothing to build and nothing to reindex, ask again in a
moment — and the next query finds the open finished. It is deliberately not cached as a failure, since
the query after this one is expected to succeed. `where --syntactic` skips the store entirely.

### Invalidation

**Query time, not hooks.** Every query against the index opens with `git rev-parse HEAD` and
`git status --porcelain -uall -- '*.swift'` — around 20 ms, yielding the dirty set (edits,
untracked files, deletes, renames) with git's own ignore rules applied, and it cannot be "missed" the way
a hook can. Dirty files are reparsed before answering; deleted paths are dropped. **The dirty set is every
edit git reports, which is not every edit**: a file git is told to overlook (`git update-index
--assume-unchanged` or `--skip-worktree`) never appears in it, and listing those flags on every query
(`git ls-files -v`) costs as much as the status itself. Such an edit is caught two ways. A `digest` that
serves source (a member body, a range, the source served below the compression floor) hashes the bytes it
read anyway against the file's row, and on a mismatch reparses that file into the index and renders the
answer again, so the outline and the source describe the same bytes; the header's `dirty:` count then
names the file (`dirty: 0 (+1 not in git status, reparsed from the live file: Sources/App/Alpha.swift)`).
That holds for a file digest that stays a digest too: the passthrough reads the source to weigh it against
the digest, so a large file is hashed and reparsed like a small one. A stale file that cannot be parsed (not
UTF-8, unreadable, gone since the read) keeps its old rows and the header says so (`could not be
reparsed: <path>`), never "reparsed". Every other answer — a miss naming a declaration only the new bytes
hold, `where` — keeps the old rows until `reconcile` (§6.4), which hashes every file. **Whether a candidate
changed is settled by content, never by its stat alone**: a size that differs from the row reparses, and an
equal size is hashed and compared with the row's `content_hash`, whatever the mtime says, because size and
mtime both survive a real edit (`touch -r`, `cp -p`, `rsync -t`, an archive extraction, a same-length
rewrite inside one mtime tick) and an answer built from the old parse would then go out under a fresh
header. Only candidates are hashed (the dirty set, a head move's range, the files settled since the last
query), never the tree, so a clean query reads no file (outside the §6.4 sweep a query can trigger, and the
source a digest serves, which it reads in any case); a standing dirty file costs one read and hash per
query and no parse, and an equal hash under a new mtime only refreshes the stored mtime. Enumeration comes from
`git ls-files --cached --others --exclude-standard`, so gitignored files sit *outside* the tool: the
invalidation layer could never see their changes, and indexing what cannot be invalidated serves stale
answers under a fresh header. **A path that is itself a symbolic link is left out for the same reason**:
git tracks the link's own text, so an edit to the file behind it marks only that file dirty, and a row held
under the link's path would go on citing lines the file no longer has while the header called it fresh.
Leaving links out keeps one row per file, under the path git reports that file's edits on, and a file that
becomes a link loses its rows on the next query. The file behind a link is indexed under its own path
wherever the index covers it; one outside the repository, or gitignored, is not indexed at all.
Path-emitting git commands run with `-z`, or git's quoting of non-ASCII paths corrupts them. `.sift/` is
added to `.git/info/exclude` on first index. **No read writes the index**: `git status` and a porcelain
`git diff` against the working tree both write back the stat refresh they make, taking `index.lock` for it,
and another session committing in the same checkout fails on that lock. Every read therefore runs with
`GIT_OPTIONAL_LOCKS=0` (which stops `status`) and `diff.autoRefreshIndex=false` (which stops `diff`, whose
refresh ignores that variable). `status`, and a diff printing counts or a patch, still settle a
touched-but-unchanged file by content; a `--name-only` or `--name-status` diff against the working tree
does not, and lists the file, so a list of changed working-tree paths is read from `status` instead.

### The freshness contract

An answer from any of the four query tools, on either face, or from `status` or `affected` on the command
line, opens with one line, and any note it carries — an adopted root, an argument read under another key —
sits under that line, never above it. `search` and `strings` read the working tree live and consult no
stored row, so theirs is the live header, which names the tree and says so (`tree: Orchard source:
working tree, read live — nothing stored to go stale`) and carries none of the freshness fields; every
other answer's is:

```
tree: Orchard  head: a1b2c3d  dirty: 3  parse_errors: 1  semantic: stale (2 files changed since last build)
```

**`index` and `reconcile` are the exception, and it is deliberate**: each writes an index, so which
repository it adopted is said before any work starts, and the header follows the work it measures. The
reports — `usage`, `audit`, `run`, `servers`, `flakes` and `report` — describe logs, runs and processes
rather than one tree's index, and open with first lines of their own.

**`tree:` leads, because it is the subject the rest of the line makes claims about**: a header that does
not say which checkout it measures gives two checkouts of one repository byte-identical headers. A linked
worktree is marked as such and names the repository as well as itself — `tree: Orchard (worktree
agent-1a2b3c4d)` — because two worktrees of one repository are told apart only by their own names. It is a
name and never a path (the Answer Contract's Wording rule keeps absolute paths out of answers meant to be
shared, and the header is the line that gets pasted). A directory git cannot answer for keeps its own name.

**A clean tree says so in one word** (#614). Where the working tree's dirty count and parse-error count
were both measured and both are zero (no Swift file changed since `head:`; the count is of Swift files) — 87% of headers in a week of real sessions — the header carries
`clean` in their place: `tree: Orchard  head: 0207cf8  clean  semantic: fresh`. Every other state prints
both fields as before: either one nonzero, a dirty count git could not measure (the `dirty: 0 (+N not in
git status, …)` form, where files were reparsed that git did not list), an answer `--at` a revision, an
answer read live. That is 20 characters on most answers (`dirty: 0  parse_errors: 0` is 25, `clean` is 5),
written once and re-read on every later turn. The `mode:` line names the mode and keeps a short pointer to
`sift help answers` instead of explaining a degraded mode on every answer, and the two `references:`
caveats are one line. The in-place answer's opening line is left alone: its suffix was just given the
re-run's cost (#613).

Freshness has **two independent axes**, and conflating them is a bug. **The syntactic index against the
working tree self-heals**: dirty files are reparsed on demand, so syntactic output is never stale, and a
HEAD move diffs the recorded head against the new one and reparses only the Swift files that range
changed — a plain commit of edits already indexed costs a `stat` and a hash per file and no parse. It must not refuse
and must not rebuild the index, because the head comparison is a fast path for "diff nothing", not a
validity gate; a recorded head that no longer resolves (a rebase, a rewritten history) converges through
`reconcile` (§6.4). **The index store against the working tree cannot self-heal**, because only a *build*
refreshes it: semantic answers about a symbol whose file changed since the store's unit was built refuse
**per symbol**, and the instruction is "build the project", since rebuilding this tool's own index fixes
nothing on that axis.

The header's `semantic:` field reads `syntactic-only` when the store was never opened, `none (…)` when a
semantic query ran without one (the detail says whether none was found or one was found and failed to open,
since a build fixes only the first), `warming (…)` when one was found and is still being read past the
query's budget, `fresh`, `stale (…)` naming the files written since the build and the occurrence files
deleted since it, and `fresh, N declarations not found in the store` when nothing is stale but the store
has no unit covering a declaration — a different fact from staleness, and one a rebuild may not fix.
**`partial (N test files have no unit in the store — references from tests are a lower bound)`** when
nothing is stale but some indexed test file (one importing XCTest or Testing) has no unit in any store the
query reads: its target was never compiled — a plain `swift build` compiles no test target — so the store
records no reference from it, and an answer about tests read from the store alone would report none of
them under `fresh`. It outranks `fresh, N declarations not found` and yields to `stale`. `affected` and
`diff`'s reaching tests then also walk the declarations the store did answer for by written name, keeping
only tests in those files, marked `name match`, under one line naming the files' count and, for SwiftPM's
store, the build that adds them (`sift run -- swift build --build-tests`). Every SwiftPM build command
this tool recommends for a store carries `--build-tests` for the same reason. Where a test build ran (some
test file has a unit), `affected` and `diff` set aside a unit-less test file whose module no store holds a
single unit for when it sits in another project: the deepest directory enclosing it that holds a build file
of its own (a `Package.swift`, an XcodeGen spec, an `.xcodeproj`, as `ModuleResolver` finds them) is not
the store's project, which for SwiftPM's store is the root package and otherwise any project some store
holds a unit in, or, for SwiftPM's store, the root manifest declares no target of that module (a stray
fixture). No build of the store's project compiles such a file, so they neither count it toward `partial`,
nor advise a build for it, nor walk it, in the store-backed walk or the name-matched fallback: its tests
would land in runner lines naming a target that build does not have. `affected` names those files on one
line, `N test files outside any built target`. Project, not unit presence, decides it, so a test target
added to the root package since the build, which has no unit in any file either, is still counted, walked
and advised, as is a file added to a target the build compiled; a manifest that names no target literally,
or any target by a computed name, is read as declaring them all, so doubt lands on counting the file (#586). `where` reads `partial`, and
advises a build, only where **no** indexed test file has a unit (the test targets were never built); where
some do, a test build ran and the rest sit outside any target it builds (a stray file, a fixture, a sample
project), which no build adds, so advising one would repeat on every answer however often it was followed.
Those files are still named, as `N test files outside any built target`, and never dropped: in a repo
whose modules are all guessed, dropping them would bring back `0 tests` (`TestFileCoverage`).

**`status` judges this field from discovery and file state, never by opening the store**: an already-warm
store belongs to whichever process holds it open, and a health check that opened its own copy would pay
full ingestion. So `status` runs the two comparisons a resolved query runs per cited file, over every file
at once: a stored file's own change moment against the store's build anchor (the one expression a query judges by
too), and a file gone from the tree. The second needs a record of its own, because every route to a
deletion drops the file's rows before any report reads them: the index keeps the path and moment of each
file it drops in a bounded ledger in its own `meta` table, and `status` counts those dropped after the
anchor that are still missing. It reads `fresh` when both counts are zero, `stale (N files newer than last
build, M files deleted since last build)` when either is not, and the no-store state when discovery finds
nothing. The deletion half is worded one step weaker than a query's — *files*, not *occurrence files* —
because only a query reads the occurrence that shows the store still holds something in the file. It errs
by over-warning, never under-warning: a drop is recorded when the index notices it, and only when the file
is actually missing at that moment, since a row can be dropped for a reason that leaves the file where it
was (narrowed away by a fresher `.sift.json`, newly gitignored), and recording that would crowd the
ledger's bound and let eviction forget a file that is genuinely gone.

A store with no ledger at all (a `sift reset`, a schema-version rebuild, a wiped `.sift/`, the first index
of a tree, or one written by a binary from before the ledger) is **seeded once**, on the first route into
the index that finds none, before any row is dropped, and the ledger is written even when the seed finds
nothing. The seed is timestamped at that moment and drawn from what git still records: paths git tracks
but the worktree lacks, staged deletions, and files deleted by commits dated at or after the store's
newest unit (a merge commit read as its diff against its first parent; a staged or committed rename
counted as the deletion of its source). With no store there is no build for a commit to postdate, and
history is not searched. Each seed is kept only while the file is still missing and the index would cover
it. A sparse checkout over-warns: every tracked file outside its cone is seeded as deleted, until the next
build dates the store past the seed.

Four deletions stay uncounted, and the note under `status`'s header names each in plain words, since a
query still shows every one: a never-tracked file's deletion after a ledger wipe; a deletion dated before
the build that the tree reached afterwards without a commit of its own (fast-forward, checkout, hard
reset, rebase onto older work); SwiftPM keeping a deleted file's unit until a clean build, so `status`
reads `fresh` where a query reads the file as deleted; and an older binary's drop after this store's
ledger already exists, since the seed runs once. `unresolved` is a per-declaration fact, and `partial`,
`warming` and `openFailed` are facts only a real open establishes; the note names each as showing only on
a query.

That second axis covers the files an answer *cites*, not only the file it is about — the files the store
names as calling, referencing, overriding or conforming can be edited or deleted with the declaration
untouched, and neither the head nor the dirty set would notice; each is judged against the same build
anchor, one `stat` per distinct occurrence path. **"Changed since last build" is decided on the row's
change moment: the later of the file's mtime and its ctime**, recorded when the file is parsed and
refreshed when a hash proves an unchanged file was only touched. The mtime alone under-claims: an edit
after the build whose mtime is put back (`touch -r`, `cp -p`, `rsync -t`, an archive extraction) keeps
it under the anchor, and the reparse that follows records the restored value. The ctime is the half no
user command restores, since every write and every restore of the mtime moves it to the present. Three
limits are stated: the moment knowingly over-claims, since no build-time content hash exists to compare
against, and a ctime moves without an edit too (a `chmod`, an extended attribute); an edit git never
names stays unseen until it is a candidate (a repository told to ignore the ctime, `core.trustctime=false`,
with a minimal stat check; a clock set back past the build); and a path that fails to `stat` for any
reason other than deletion degrades to live, because the failure to avoid is calling a live reference
dead.

**A linked worktree never has a store, and what the answer says about that is the whole of the
difference between a gap and a silent miss.** A worktree has no build directory of its own, so the
semantic half of `where` is off in every one — the ordinary case where change-producing agents run in
worktrees. **The parent checkout's store is not borrowed and never will be**: it describes a different
tree and would name callers that do not exist there and miss ones that do, the confidently wrong answer
that pinning the root to the caller's tree exists to kill. So the gap is made unmissable in two places.
The store-less note says the parent's store is not being used and why, and names both ways out (`where`'s
one-line form names the `worktree-index` topic, which says both). And every
answer built without a store says what an empty result under it does *not* mean: the fallback matches a
written name and it matches **calls**, so a type in an annotation, a generic parameter, a conformance, a
test payload, a `#selector` or a name in a string is not in it, and a type, which is what a rename sweep
is usually after, has no calls at all. "No call of that name was found" is the reading; "nothing uses
this" is not.

**A label and a refusal are not interchangeable.** A refusal is right when the tool cannot tell which part
of an answer is wrong — an edited declaring file poisons the USR resolution the whole answer hangs off. A
label is right when it can tell exactly: a `stat` settles each row, and rows in surviving files are as
sound as they were. So dead rows stay listed, carry `(file deleted since last build)` or
`(file changed since last build)`, sort after the live ones so a truncated section spends its cap on what
still stands, and the heading names how many of its own rows it is disowning.

## 3. Tool surface

Beyond the query tools the CLI carries the lifecycle commands: `index` (incremental, or `--full`),
`status` (the doctor: freshness header, row counts, database size, modules, config, the store-discovery
result, every file with a parse error or a guessed module, and the hook-registration, agent-allowlist and
server checks of §4), `reconcile`, `reset`, and `init`, which inspects a repository's layout and
proposes a config, printing unless asked to write and adding only missing keys, because the module map
is where a person supplies target names the tool could only guess at. `test` builds a scheme once and
splits its plan across N simulators it creates and deletes itself, answering with one reconciliation —
expected, ran, passed, failed, skipped, missing, duplicated — counted against what `xcodebuild` itself
said the plan would run rather than the tallies the runners printed; `sift help test-output` reads that
answer line by line. `help [<topic>]` sits apart from all of it: fixed reference text for rare moments
(reading a red `run` block, `flakes`, the parse-error banners, root resolution, per-tool depth, and the
hook's accounting rules), compiled into the binary rather than read from the index, so it carries no
freshness header and no `--root` — the always-loaded agent rule (`Sift.md`) names each topic in one line
and points here rather than repeating the depth. A name that matches a registered subcommand instead of a
topic falls through to that subcommand's own usage. The commands that serve, wire and measure the MCP
face — `mcp`, `session-start`, `pre-tool-use`, `install-hook`, `uninstall-hook`, `uninstall`,
`usage`, `audit` and `servers` — are §4's. Configuration is one committed file at the repository root,
`.sift.json` — directory allowlist, exclusion patterns, module path-prefix map, explicit index-store path,
extra linter executable names — beside the git-excluded `.sift/` cache. Everything works with no config
file, and **a key the binary does not model is read past, never rejected**.

### `digest <Type | File | Module | . | Type.member | File.md | File.swift:12-40> [--at <rev>]`

Declarations only, no bodies — stored properties with declared types, member signatures, inheritance
clause, access level, grouped by extension — with **each member as `file:line–endLine`**, so the follow-up
"now show me *that* method" is a ranged read rather than a second full-file read. That pairing is the core
loop, and the tool description has to teach it. Ambiguous names return candidates rather than a guess, and
so does a file suffix more than one indexed file ends in (the candidates capped as a page is). A candidate
whose exact target another candidate shares (overloads differing only in parameter types) is named by its
file range instead, so every suggested call answers rather than repeating the ambiguity. **A
`Type.member` whose declarations are small together is served, not listed.** Where the name resolves to
several member declarations whose ranges add up to no more than 60 lines (the crossover's own bound,
`SourcePassthrough.floorLineCeiling`), the answer opens on one line naming the count and the combined
length (`SemanticStore.inherits names 2 declarations, 26 lines together; each follows`) and serves every
one of them in declaration order, each under the header a lone member's source carries (qualified name,
kind, `path:start-end`) and separated by a blank line, with no part marker: they are one target's answer,
not several. This is not a guess (answer contract §5 refuses a guess, and the list exists for the caller
who must choose): every declaration the name has is shown, with the header that tells it apart (§6), so
the one thing removed is the second call the list forced. The list stands where the ranges add up to
more, where any one of them cannot be sliced (unreadable, an empty range), and where an `--offset` is
passed, which names a place in one body and so needs one declaration. The repository-wide parse-error
banner leads the served answer as it leads the list, since both state a count; the per-file banners lead
it once for every file touched. A type's own ambiguity, `Type.deinit`'s `#if` branches and `diff`'s
member answer keep their lists. Nothing that reads an answer back changes: a `Type.member` answer is
credited by the file declaring the type whichever form it takes (`DigestedFiles.locatesAsMember`), and
each header prints the same `path:start-end` the list's line did. The list's own line drops its trailing
location where the exact target already is that location (`digest F.swift:297-299 — func`, not the range
twice). An
externally declared type answers so and lists the local extensions, taking as evidence only an extension
whose written path and the path asked for end one another — the asked path under a fuller spelling, or a
suffix of it, the bare name included, so `extension Notification.Name` answers for
`Foundation.Notification.Name` — so that `extension URLSession.Configuration` cannot turn a local
`Loader.Configuration` reached through the wrong parent into an external type; that miss is answered as a
wrong path, naming where the type is. `digest .` is the repository overview; `Type.member` returns that
member's current source, read from disk at query time; `Type.deinit` is the one member the index does not
store (a deinit has no name and no kind), so it is read out of the type's own source and served the same
way, and `where Type.deinit` lists it at its lines. A type with none is answered as `T declares no deinit —
checked in its source, <path:range>` by both, never with a missing declaration's wording, which is true of every
deinit and so says nothing of this one; a type whose source cannot be read is answered `could not check T for
a deinit: its source could not be read`, never as one with none. Two deinits of one type sit in the branches
of an `#if`, so each is listed, and offered as a `digest` target, with its condition labelled as a
declaration's is (`[#else of #if os(macOS)]`) — the target still names both, so one is read by its range — and the list is capped with a `truncated:` line as every
other list of declarations is. A `some View` property or method carries its stored
outline (§2) beneath it, capped per member and across the whole answer, so a digest of a screen stays
smaller than the screen.

Output budgeting is mandatory at scale. **Type and file digests default to all access levels**, because
private stored properties *are* the shape of a type and `private` is file-scoped — the cap, not an access
filter, is the size guard; a module digest keeps a public-plus-internal default and states what it
withheld. The cap is 60 members, then a truncation marker and an offset cursor; **enum cases render
packed** and do not count against it; a file digest opens with its import list; output is deterministic.
A file digest lists the members of each top-level declaration and names those of a type one level down on
that type's own line (a dozen names, then `+N more`); a file whose only type is declared inside a
top-level extension lists that type's members beneath it with their ranges, under the same cap. **A doc
summary is capped at roughly 80 bytes**, cut at a clause boundary (a mark followed by whitespace, outside
a code span, not closing an abbreviation) that keeps at least half the budget, else at a word; a run with
no boundary is served whole up to a 160-byte ceiling and cut there, marked. The summary is stored at parse
time, so a change to this rule bumps the schema version (§6.6). Synthesized members are declared as a gap
rather than silently omitted, and since compression has a floor, a type below the crossover is served as
source with the arithmetic shown.

Several targets in one call (CLI: one per argument, so a quoted path with a space is one; MCP: `target` is
exactly one target and never split, since a path with a space is ordinary, and `targets` is an array,
beside or instead of it) each render exactly as they would alone, joined by a blank line. A `target` with
whitespace in it that names nothing says it was read whole and names `targets` as the way to send several.
An offset pages one answer, so a call naming several targets with one is refused. Only the two shapes that
weigh a digest against real source can report a saving, so a call naming more than one reports none. The
usage log records several targets as a list rather than one joined string, and the audit credits each.

A digest of a detected test suite — recognised the same structural way `affected`/`flakes` recognise one
(imports, `@Test`/`@Suite`, `XCTestCase` inheritance) — carries each helper's own source beneath its
signature line, and closes with each suite's last test, with its file and range, as where a new one goes:
one line per suite. That holds for the file's digest and the suite's own type digest alike, whose helpers
include those declared in its extensions. A helper is any non-test member with a body, and its source is
exactly what lies between the body's own braces. It is bounded twice: at 10 lines for one helper and 20
across the digest, past which a helper keeps its signature and range alone and the answer says how many
did.

A **`.md` target is answered from disk rather than from the index**, because prose is the other half of
what gets read whole: Markdown was 30% of the bytes agents read (219 subagent transcripts), a handful of
large documents opened end to end many times over, with no way to locate a section but to read the file or
grep it. `digest <file>.md` returns the document's heading outline under the same freshness header, saying
it was read live: one line naming the file with its total lines and bytes, then one line per heading,
indented by its depth below the shallowest level the document uses, with the heading's text, the line
range of the section it opens, and that section's size in lines and bytes. Nothing about a Markdown file
is stored — headings only, never prose. The path is exact, repo-relative or absolute under the root, with
no suffix matching: guessing which of several files a bare name meant would hand back a different
document's outline with confidence. A `.md` path that is not there keeps the miss that names it and says
a `.md` target takes the exact path; a document *readable at the path given but outside this root* instead
gets a miss naming the real reason and `--root <the repository enclosing the file>` (or says the file is in
no repository to root at), both roots spelled canonically. Headings are **ATX only** — `#` to `######` at
the start of a line, indented at most three spaces, followed by a space or the line's end, a closing run
of `#`s stripped where a space precedes it (`## C#` keeps its name), a heading with no text shown as
`(untitled)`, a CRLF document read as its LF twin — and a `#` inside a fenced code block (``` or `~~~`,
closed by the same character; an unclosed fence runs to the end of the file) is not one, which is
load-bearing since these documents quote shell sessions and Markdown at each other. Setext headings are
**not** recognised: that underline is also a horizontal rule and a table's divider, and a section boundary
claimed mid-paragraph is worse than one missed. A section runs from its heading to the line before the
next heading of the same or a shallower level; lines before the first heading belong to no section. The
60-entry cap, the `truncated:` marker and the `offset` cursor are the ones every digest uses, counting
heading lines; a document with no headings is told so in one line; and the compression floor applies as
it does to source. This is the locating step for a ranged Read, the same loop as for Swift.

A heading whose own body is one long run of top-level bullets gets those bullets woven in beneath it, one
row each, indented a level past their heading: the range first, then the bullet's leading `**bold**` run
or its first dozen words, and a `[struck]` flag where the item opens with `~~`. Only an unindented marker
counts; each bullet's range runs to the line before the next bullet or heading of any level; the rows
count toward the same 60-entry cap.

`File.swift:12`, `File.swift:12-40`, `File.swift:12:5` and a diagnostic's `File.swift:12:5:` (column and
trailing colon read and discarded; a reversed range read the right way round) are digest targets too — the
shape a `where` answer or a stack trace hands back — and healed from `path:` like a name. The lines
resolve down the file's declarations: one they cover whole is served as a single block, one they cover in
part is served whole if a leaf within the 60-line source floor and looked inside if a container, a longer
leaf holding every line asked for serves only those lines under one header naming the leaf, its whole range
and the call that serves it all. **A single line inside a leaf longer than 25 lines is windowed whatever the
leaf's length**: under the same header, the leaf's declaration (its stored signature, left out where the
window already shows the declaration's first line), the line with 3 either side clamped to the leaf, and a
last line `lines a-b; read it by range` naming the leaf's whole extent. One line is the stack-trace and log
question — which function is this in — and serving a 43-line function whole answered it with ~3,800
characters where the name and a few lines were wanted (#485). A range of two or more lines keeps the rule
before this one, since the asker named the extent, and so does `Type.member`. A doc-comment line
belongs to the declaration beneath it, and rows sharing one range (cases packed on a line) are served once. Lines inside a
container that none of its members reaches name the nearest members before and after with their ranges,
and serve the container itself only when it is within the 60-line source floor. When no declaration
reaches the lines at all, the file's own digest carries one line saying so. An offset pages one
declaration, so a range resolving to several refuses one, as several targets do, and each truncated block
there names its own exact range and the call that pages it; the neighbours answer is one page, so an
offset sent with it is served anyway, with one line naming it as unused.

### `where <symbol> [--at <rev>]`

The declaration site, plus conformers, callers and overrides, over `Name`, `Module.Name`, `Type.member`
and argument-labelled forms for overload selection. Syntactic mode returns declarations, extensions and
conformers-by-name — the reverse `inherited` lookup, useful with no build at all — and full mode adds
callers (for a property or subscript, its reads and writes; for an enum case, its uses; for a type, the
references that are its usage) and overrides from the store, and lists a protocol's conformers once, the
store's and the written names' merged (below); **the answer states which mode produced it**.
No exact match falls through to fuzzy search and returns candidates, ranked so a candidate declared under
the qualifier's own type sorts ahead of every other match, since a labeled-member miss
(`Engine.start(mod:)` for `start(mode:)`) belongs to that type before any other. "The qualifier's own
type" is decided by name resolution's own rule and nothing narrower — the written path matched against a
suffix of each possible container's flattened enclosing chain, with the module allowed in front — applied
to the containers before the page is cut, so ranking can never disown a member resolution would have
found: an extension stored under its whole dotted path answers to that path or any suffix of it, a type
nested inside such an extension answers through it, and `Module.Type` names the same type `Type` does.
`digest` ranks by the same rule.

**`--at <rev>` (on `digest` and `where`, and `at` on both tools) answers about a past commit, and its
freshness reading is different in kind: syntactic, against a revision.** Review asks structural questions
of a base commit ("was this already declared there?"), and `git show <rev>:<path> | grep` cannot tell a
declaration from a doc comment that mentions it. The answer is read from a parse of that revision's tree,
never from the store: paths from `git ls-tree`, filtered by the working tree's `.sift.json` and module
resolution (the revision's own are not consulted), a symbolic link read by the revision's own mode rather
than the working tree's; blobs from one `git cat-file --batch`, only those containing the queried name (or,
for a file target, at that path) parsed, each tree discarded before the next, into a transient in-memory
index, so the renderers answer unchanged and a member's source and the name-matched call sites are that
revision's text. The header replaces `head:`/`dirty:`/`parse_errors:`/`semantic:` with
`at: <rev> (syntactic, from git)` (`= <commit>` beside a rev not written as one) and never claims a
semantic resolution: callers are name-matched over the parsed files only, and say so. The line under the
header counts the files parsed of the Swift files at the revision. A revision git cannot read is refused in
git's own words, as is one naming a tree rather than a commit, and a module, `.` or `.md` target, since
none is answerable from a few files. `where --since` is not built.

The same name in several modules ranks equally rather than being resolved here, since `where` doubles as
the symbol-search tool — the reason the MCP surface stays at four. **A bare name declared under two or more
owners that no written inheritance or conformance relates lists its declarations and stops**: one line
each, with its use count split production · tests on the file's imports where the store can judge it (said
to be uncounted, and why, where it cannot), and the qualified query that narrows to it
(`where Lookup.readPath`), checked by resolving it. Overloads of one owner, an override or a witness and
what it implements, a qualified query, and `--refs` answer as before. An owner is a type, not a type's
name: two types that share a name in different modules or containers are two owners, and an extension is
the type it extends. The hook's in-place answer to a search keeps every owner's uses listed, since it
stands in for the lines that search prints.

`--refs` is the rename and delete sweep view, for every kind: every reference site, one line per file,
paged on a cursor, counting **distinct lines** so header and listing reconcile. Three things it must never
do: read as complete when it is not, count what it does not list, or return silently with no store, which
says UNAVAILABLE instead. **Where there is no store at all** (a worktree before its first build, a checkout
never built) and the name has a name-matched stand-in, the mode line names the missing store (the one-line
form above) and the `references:` line says the name-matched sites under it are the sweep, all of them by
written name and paged by file. An associated type, and an extension of a type the tree declares nowhere at the
path it writes (`extension URL` beside a nested `Endpoint.URL` too, both then named as owners, each once), stand in
by the lines writing their name as a type does, under `used by:`; the extension's own lines are uses there, since
no declaration of the type owns them. A dotted extension (`extension Depot.Gizmo`) is found by that whole spelling
when nothing else resolves it, and by that final component alone when nothing declares the bare name
(`where JSONDecoder` beside only `extension Foundation.JSONDecoder`, answered as that extension), and swept
by its final component. An extension written with generic arguments (`extension Dictionary<String, Net.URL>`)
is found the same way by its path with those arguments set aside, never by a name written inside them: `where
URL` does not reach it. One rule (in `ExtensionPaths`) reads every extension's path this
way, so a type the tree declares lists `extension Box<Int>` and `extension App.Box<String>` under `extensions
of Box` and counts their lines as its own, as it does `extension Box`. A query led by a name the tree
neither declares, aliases or extends as a type at the top level nor has as a module (`where Swift.Dictionary`)
is read as led by an imported module, so it reaches what the bare query does: the extensions written without
that name too, except one in a module that declares its own type at that path, which extends that type, and one
written through another qualifier; led by `Swift`, the sugar as well. A leading name the tree never writes may
still be another module's type (`UIView.ContentMode`); the bare extensions it reaches are then kept, not
dropped on that guess. (#592, #593) Where the type asked is one type, at one path in one module, each of those
extensions is placed against it (`ExtensionPlacement`): a leading name that is a module of the tree and no type
is that module, else the path is the extension's own module's type where it declares one, else a leading name
that module declares at the top level is read through that declaration and never an import's (a typealias is
followed to its target: `typealias Box = Int` makes `extension Box` Int's), else the one type of
the tree at that path among the modules its file imports. One placed as another type (`extension Other.Box` or
a bare one in `Other`, under `App.Box`) is not listed, not counted as its own, and not counted as another module's
use of it; nor is one whose path is a shorter tail of a nested asked type's (a bare `extension Box` under
`Outer.Box`). One that cannot be placed (`extension Shelf.Box`) is listed marked `may extend another module's Box`
and counted as before. The no-store use sweep keeps the header of a bare extension placed as another type's,
marked `— extends another module's Box` on its line (`— extends another Box` in the asked type's own module) and
noted beside the count; a typealias of no plain path (`[Int]`, `Int?`) makes it another type's too. A bare query with several owners
keeps its per-owner answer. (#592) An extension written through sugar (`extension [Net.URL]`, `extension Net.URL?`) is
found by `Array`, `Dictionary` or `Optional`, read by its outermost sugar, also beside extensions the name
resolved to, since its line never spells the name. An alias writing such an extension's path without its leading name is kept, never
folded in: the leading name may be a type of another module (`extension UIView.ContentMode`), not a
module; one writing the whole dotted path stays proven. With a store, a type the tree only extends is given the
same name-matched stand-in. A name the tree
declares nowhere gets no `references:` line at all, since a store would not turn that miss into an answer. A
macro, an operator and a precedence group have no stand-in yet and keep UNAVAILABLE. A type's block lists, with
its uses, the lines it writes its own name on inside its declaration and its extensions in its module, and the
typealias declarations naming it (`Circle(radius:)` inside `extension Circle`, `typealias Round = Circle`): the
verdict still counts them apart from use, adding `listed below as a rename changes them`, and each file's `(n)`
counts every row under it, since a rename changes those lines and nothing else in the answer lists them
(#489). Outside the sweep they stay counted, not listed. A stored property the compiler's memberwise
initializer takes (a struct whose body declares no init) lists with its uses the calls passing it by its label,
`Circle(radius: 1)` for `Circle.radius`, found by the struct's name and kept where the memberwise labels take the
call, every parameter with no default supplied in order (a default read from the declaration's own source where its
stored signature was cut before the initial value, and assumed where that cannot be read; a `lazy` property is one
with a default, as the compiler makes it). A struct whose labels cannot be worked out (a tuple pattern `var (x, y)`,
a signature that does not parse) is still scanned by its name, and each call writing the label is counted, `N calls
writing radius: to Circle(…) not listed, as its memberwise labels could not be worked out`, never left out; where
nothing else is listed, the verdict is `nothing spelled "radius" is listed here — …`, since a call was found and no
verdict of absence holds. A call is told apart
from a same-named type's as an initializer's own calls are: one that may build another type is listed with its
flag and counted apart (`N more writing radius: to Circle(…) that may build another type named Circle, flagged`),
and so is one whose qualifier the index reads as another type's owner or as declaring no `Circle`, flagged
`(behind a qualifier the index reads as Base, which declares another Circle)`, since that reading is not sound;
one whose labels the memberwise init does not take is counted, not listed. Its heading counts them apart, `plus N calls passing it as radius: to the memberwise init`, since a rename
changes each label and a scan for the name as an expression finds none of them (#446). `plus` adds them to a count
before them; a property with no use by name says so, `no use by name, N calls passing it as radius: to the memberwise
init`, and no count of uses by name is printed as zero: a name the scan found nowhere at all, a private one narrowed
to its file included, says `no use spelled "radius" anywhere in the working tree — <how it was narrowed>`. A property
with no label calls keeps the plain `(N uses in F files)` heading. A plain `where` of the property (no `--refs`) counts the same calls and lists none of them, ending the clause
`(--refs lists them)`, so it never says `no use spelled` of a name a call writes as a label; a `--refs` answer that is no sweep (`--syntactic`, a store warming or failing to open) lists them under the usual cap rather than pointing at the flag it was given; the struct's name is
scanned in the same pass as the property's, so plain lookups stay as fast as before. They are the whole sweep a rename has, so none is left to a sample cap or a "grep instead": every list of them (a
type's written uses, a name's call sites, the calls an initializer's labels leave to others, the `.init`
calls the scan cannot tell, the calls of a type that declares no init) **pages by file on the same
cursor** — files in path order, a file's lines never cut. **One offset is one boundary for the whole
answer**: every list shows its own files `[offset, offset+N)`, with N chosen once for the answer, the
largest that keeps the rows of every list together within about 5 KB, at most 40 and at least one so the
cursor always advances. `(…K files skipped)` goes above a later page and `truncated: N more files` below
each cut one; the first cut list in the answer carries the one continuation, `pass offset K to continue`,
and every other says it is on that same offset, so following the one cursor to the end shows every file of
every list exactly once. Lists budgeted one after another would hand the first list the budget and later
lists one file each, under a different cursor from the same answer, and following either skips the
other's files. The line names, compressed, what a written-name match misses (a use
reached through a protocol or a closure, and through a typealias except where a type's block says it folded
those in; comments and string literals) and that a same-named symbol's sites may be among them:
`references: all sites by written name, paged by file — may add same-named symbols'; may miss protocol,
closure, unfolded-typealias uses; skips comments, strings`. **A no-store answer opens with at most three
lines, none over 160 characters**: the mode line, the `callers/overrides: NOT ANSWERED` line (`used by: NOT
ANSWERED` for a type), and under `--refs` the `references:` line: 386 characters in all, from about 1,450
when the mode line carried the recipe (`Benchmarks/RESULTS-single-call.md`). The mode line says nothing of
what still answers, since the lines under it say that; a rejected `indexStorePath` setting, named on it,
can still lengthen it. A bare name
several unrelated owners declare (the narrowing rule above) whose sweep runs past one page gets one more
line: a written-name match cannot tell the owners' sites apart, and the query that narrows to one owner. A
`T.init` of a type that declares no init is swept the same way. An offset nothing in a no-store answer pages
(no `--refs`, an UNAVAILABLE line, a subscript) is named on one line as unused, never served silently. A
store warming or failing to open, `--syntactic`, and a subscript keep UNAVAILABLE, and the checkout's store
is still never borrowed in its place (the worktree note above). Comments and string literals are not
index-store occurrences and the answer says so. Hits on one line collapse to one row counting the **build units** that recorded it (IndexStoreDB
returns a copy per unit, told apart by module and write time, so one file compiled into two targets is
`×2 units`), never the occurrences; drifted ones stay listed. An implicit occurrence the same unit also
recorded written, of the same symbol in the same declaration, is a macro expansion's copy (`#expect`
records each call it wraps again at the macro) and is never listed; nor is one inside a declaration a
macro's expansion generated whose twin was written in no declaration at all, at or after its line (a
`#Preview` closure's call is recorded again inside the generated `makePreview()`, and the written call is
named `(inside #Preview)` rather than an unknown caller). One with no written twin is a use only ever made
implicitly — a property wrapper's `init(wrappedValue:)`, the function `@Test` calls from one it generates
— and is listed, a caller a macro generated named by the macro, `(@Test expansion of spans)`, as the Swift
runtime's own demangler reads the mangled name (a hand reading named `LampTests.dimLampWorks` `Works`,
since the mangling reuses an earlier word as a back-reference). A declaration counts as a macro's only
where the demangler reads an expansion in it, and on a runtime whose demangler predates a macro kind
(the Swift 5.9/5.10 runtime reads no body or preamble expansion) the caller keeps the store's name; a
declaration the store leaves unnamed is named by what it is and whose, `modify accessor of total`. A
protocol requirement's hits are headed "implementations", since the relation covers witnesses as well as
class overrides; emptiness is one summary line.

**A function that implements a requirement is never said to have no callers.** A call made through a
protocol requirement or a superclass member is recorded against that declaration, and one a library makes
(`sorted()` calling a type's `<`) is recorded nowhere in the store, so neither is ever recorded against the
witness or override itself. Read from the other end of the same relation: the function's definition
carries `overrideOf` to each declaration it implements, or, where an extension declares the conformance and
the type's body the witness, an implicit occurrence at that extension carries it and the definition does
not, so both are read. Its empty case is then its own line in the summary's
slot, `no direct callers of X recorded in the store — it satisfies Comparable.<(_:_:), so a call made through
Comparable, including one a library makes, is not recorded against it` (no route but a library's is named: no
existential reaches a requirement that mentions `Self`, as `<` does) (`overrides
Base.f()` and a superclass reference for a class member), and out of the summary's `k of N declarations`
arithmetic, carrying the zero-use verdict's note of the test files the store does not hold after `recorded in
the store`, as every other zero-use line does; the several-owners count is of `direct call sites`, with the same clause in its field. The
owner is named only from what the store holds: the requirement's definition's parent where the store has
the definition, else the protocol or class whose USR is the longest prefix of the requirement's (a member's
USR extends its container's: `s:SL` is `Comparable`, found at any conformance clause that writes it); where
neither resolves, only the requirement is named. The hedge never points at the requirement as where the
callers are, since a library's calls are not there either. A property or subscript witness (`description`,
`id`) is read through its requirement the same way, and carries the same relation, at its definition or its
conformance's extension: its empty
case is `no direct reads or writes of X …`, with `a use made through` in the clause, and its several-owners
count is of `direct uses`. A function that implements a requirement and has callers recorded lists them
under `direct callers of X (N, it satisfies …)`, the same clause in its count, and a property or subscript
witness lists its reads under `direct reads and writes of X (N, it satisfies …)`. A requirement a refining
protocol declares again (`protocol Refined: Named { var name: String { get } }`) is no witness: the store
records it as implementing the base's, and the clause says it `restates Named.name`, since a use made through
`Named` is still recorded against `Named.name` and never against it. Told apart by where the declaration
sits: a requirement is a child of its protocol, while a default implementation is a child of the protocol's
extension, and that one `satisfies`. A restatement is said under that clause only, and listed in no
`implementations of` block: not the base requirement's, and its getter not its own. The store, asked what
overrides a property, also returns the property's own accessor, whose `overrideOf` is of the base's accessor,
so only an occurrence whose relation to the asked symbol is the override is listed. A witness picked at a
conformance — a protocol extension's default a conformer takes, or a body's function an extension's
conformance makes one — is recorded as an implicit occurrence at the conformer's name or the extension, and is
listed at the witness's written definition instead, once however many conformers take it; one with no written
definition in the tree — synthesized, or defined only in the SDK's interface or a dependency the index never
covers (`extension Array: Counted {}`) — stays where it is recorded. A function that
implements nothing still says `no callers` and `callers of X`, unhedged.

**A type is neither called nor read: what it has is references, and they are resolved by default.** A type
is written in an annotation, a generic parameter, a conformance clause or a construction, never called, so
a call query finds nothing for one however much it is used, and a default answer with no section and no
empty case reads as "nothing uses this". Putting a type's only relation behind an opt-in flag was the
design error; `where <Type>` resolves it every time, under the per-query declaration cap of every other
relation. The section opens with **the verdict the deletion decision is made from** — `used by
SiftCore.SimilarTarget: 1 reference in 1 file — 1 production · 0 tests, split on the XCTest or Testing
import, never the path`:

- **The test bucket never states a count the store could not take.** Where an indexed test file has no unit in
  any store the query reads (a plain `swift build` compiles no test target), the bucket reads `tests not
  counted (N test files have no unit in the store; build with `sift run -- swift build --build-tests`)`
  in place of `0 tests`, and `K tests, a lower bound (…)` above zero; the same holds for the several-owners
  clause. The header's `partial` axis says it too, but the verdict is the line a deletion is decided on.
  Every zero-use verdict (`no references to X recorded in the store`, `no uses of …`, `no callers of …`,
  `no reads or writes of …`) carries the same fact after `recorded in the store`: `; N test files are not
  in it (build with …)`, since a type used only by its tests is otherwise answered as one nothing uses.
  Where a test build ran and the files sit outside any target it builds, both say so with no build advice:
  `1 test, a lower bound (1 test file outside any built target)` and `; not counting 1 test file outside any
  built target`.
- It counts distinct lines, as `--refs` does, and splits them by **the file's own imports**, never by where
  the file sits: a path prefix would be this repo's layout asserted about somebody else's. The verdict
  names that rule because it has an edge a deletion turns on: a helper inside a test target importing
  neither framework counts as production.
- A path the index has no row for is counted apart, in two causes: `N in files deleted from the tree` (the
  deletion ledger recorded leaving) and `N in files the index never held` (a build-generated source, a
  configured exclusion, a path outside the repository).
- Under the verdict, at most 40 lines in all (`siteTextLineCap`) are listed one row per line with the line's
  source text, `    :18  | <text>` under a `  path (n):` heading per file; above 40, one line per file,
  `path (count): line, line, …`, capped, with `--refs` named as the paged full view. The count is there to be
  checked against the lines, not believed. For a protocol, the verdict says how many of its lines are the
  conformances its conformers block lists (`, 3 of them the conformances listed below`), and the rows leave
  those lines out (below).
- **A reference inside the type's own declaration or one of its extensions is not usage**: an
  `extension SimilarTarget` header is itself recorded as a reference, and counting those would make every
  type with an extension look used. How many lines were dropped is said in the verdict, never in silence.
- **Which extensions are the type's own is decided by the extended type's USR, never by the name written
  after `extension`**: a leaf name repeats across modules (`extension Outer.Item` ends in `Item`), and
  taking a like-named extension for this type's would drop the real uses in its body and deny them out
  loud. **An extension in another module is a use, not its own**, even when the store attributes it to this
  USR: deleting the type breaks that module. So only an extension in the type's own module is excluded, and
  the verdict says which rule it followed (`N more lines inside its own declaration or its extensions in
  this module, which is not use`; `N extensions in other modules counted as uses — deleting the type
  breaks them`; the empty case `every reference recorded falls inside its own declaration or its
  extensions in this module`). A module guessed from a path component can split one real module in two,
  which errs toward "used", the direction a deletion survives.
- A reference *elsewhere in the declaring file* is a sibling reaching for it and stays counted.
- **A use written through a typealias is folded in, named for the alias it is written as.** The store
  records a use of `Crate` against `Crate`, not against the `Gizmo` it aliases, so references to the type's
  own USR cannot see it. Aliases are discovered where the store already records the aliasing — a
  reference to the type inside a `typealias` declaration's own span — and every reference to that alias
  breaks when the type goes, so it counts. A span is not enough on its own, since two declarations can
  share a line (`typealias Inner = Int; var s: Shadow?`): the alias's own declaration text must spell that
  name as a whole identifier too (`typealias Crate = Outer.Shadow` names `Shadow`; `typealias Inner =
  Int` names nothing), and in a chain the name it must spell is the previous round's alias, never the
  original type. An alias of an alias is followed to a fixed point over a visited set of alias USRs, capped
  at `typealiasFoldCap` (16 aliases per type), whatever the tree does, cycles included; a fold that
  reaches the cap says the count is a lower bound. The verdict says how many of its lines an alias is the
  only spelling of and which aliases, and the per-file rows say it line by line, since what a reader checks
  is not this type's name at the site; the spellings are named up to `aliasSpellingListCap` (3) and counted
  past it. Under `--refs` the sweep stays the rename view, so the folded lines are not in it and the
  verdict names the alias's own sweep instead. A `typealias Pair = (Gizmo, Widget)` names the type without
  aliasing it, and its uses fold in too, worded "a typealias naming it".
- **A typealias declaration of the type is not a use of it**, and its line is excluded like an `extension`
  header: the alias is dead exactly when the type is unless something uses the alias, which the fold has
  counted. How many lines went out on that ground is said. A type whose every reference is its own
  declaration or a typealias declaration naming it gets a sentence of its own, since the deletion it
  clears takes the aliases with it.
- The empty case is a sentence and not an absent section, in the sweep's words ("no references to X
  recorded in the store — check comments and strings with grep").
- The two boundaries a sweep carries — code occurrences only, and scope is this repo's own build — are
  carried here too, as one line, printed once when `--refs` is also on, and only when the semantic pass actually
  resolved something for them to bound (a row refused for staleness has no usage material). Every caveat
  in an answer is about something in that answer.
- Over a type `--refs` prints the verdict and leaves the enumeration to its own listing, so one set of hits
  is never listed twice. With no store, or with the type's file refused as stale, the name-matched stand-in
  answers for the type in the same shape, under its own `syntactic uses — by written name` heading: every
  line writing the type's name — a construction, a static member reached through it, an annotation, a
  generic argument, a conformance, a cast, an attribute — counted per file and split into production and
  tests as the verdict is. Its rows take the verdict's two forms: at most 40 lines in all
  (`siteTextLineCap`), one row per line, `    :22  | <the line's source text>`, under a `  path (n):`
  heading per file, the text cut as a call site's is (below); above 40, `  path (n): 22, 29, …`, line
  numbers only. Under a no-store `--refs` sweep either form pages by file. Only the store's own lines are counted apart: those inside the type's declaration
  and inside extensions written with its own path in its own module. Another module's extension of it, and
  a type of the same name nested elsewhere, are not its own, so the lines inside them stay uses. A bare name
  bound by a generic parameter list around it is that parameter, not the type, and is not listed. A bare name
  written inside a type that declares its own type of the name means that type, as Swift's lookup goes, so
  for a nested `Search.Site` the lines writing `Site` inside another type declaring a `Site` are counted
  apart, with the rule said, never listed as uses (#340). So is a bare name in the body of a protocol that
  declares an associated type of the name among its own members, outside any `#if`: Swift reads it as that
  associated type, unless an associated type is asked for (#532). Only a certain lookup sets a line aside: a
  typealias of the name, an associated type declared anywhere else (under `#if`, in an inherited protocol, read
  from an extension), a supertype declaring one or outside the index, or a path two types share keeps it a use.
  With no store, a bare name written inside a function, closure or accessor body that declares its own struct,
  class, enum or actor of the name, before or after the line, means that local type, so the line is counted
  apart (`1 more line writing "Log" bare inside a function that declares its own "Log", which is what the name
  means there, so not use`, #516). A typealias of the name, a declaration of it under `#if`, a freestanding
  macro or an attribute the language does not define in a body walked, a type, extension or protocol between
  the line and the declaration, and a value of the name bound in the file keep it a use. Swift finds a type
  nested in another by its bare name only inside that type, its extensions, the types nested in them and its
  subtypes, so with no store a bare name written where no type, extension or protocol is around it is counted
  apart when every type asked for is nested (`2 more lines writing "URL" bare outside every type, extension and
  protocol, where the name cannot mean a type nested in another, so not use`, #510). Only where nothing else may
  make the name the nested type there: the bodies around it as for #516, a value of the name or an import of a
  declaration or module of it in the file, a top-level typealias, function, variable or macro of the name in the
  index, a macro the repository declares whose `names:` say `named(URL)` however spaced or escaped, `arbitrary`,
  `overloaded`, `prefixed` or `suffixed`, and, in any file, a freestanding macro or a declaration carrying an
  attribute the language does not define at file scope, top-level `#if` clauses included, each keep every such
  line a use: an attached macro, another package's whose declaration the index never sees, may declare the name
  beside it for the whole module. An attribute the language defines is, but for `MainActor`, a spelling the
  compiler's attribute tables carry, which parses as that attribute wherever it is written, so no macro is
  applied under it: `@main`, `@_exported import`, `@_spi`, `@backDeployed` and their like leave the rule on.
  `@MainActor` is the standard library's global actor written as a custom attribute, so a macro of that name in
  a module the file sees would be applied instead; the set keeps it as the actor, an accepted gap. So do four SDK
  macros in a file importing a module that brings them in, which declare no name a user writes at file scope:
  `@Test` and `@Suite` under `Testing` (peer macros without `names:`, so unique names only), `@Observable` under
  `Observation`, `SwiftUI`, `SwiftData` or `Foundation` (the last two re-export Observation), and `@Model` under
  `SwiftData` (members, member attributes and conformances, no peers). Without that import, in that file, the
  spelling may be anyone's macro and keeps the lines, as any attached macro does; the digest's macro marker reads
  no imports, since these macros do add members it cannot list. A file-scope `#Preview`, a
  `@freestanding(declaration)` macro without `names:` in SwiftUI, UIKit, AppKit and WidgetKit, is read the same
  way beside them: under one of those imports it introduces no name, and without one, or as any other
  freestanding macro, it keeps the lines; an attribute written on it is read as on any declaration. An import
  counts only when it brings in the whole module and is outside every `#if` or in the same `#if` clause as the
  macro or a clause enclosing it (an import in a sibling `#elseif` or `#else` clause, or one the macro sits past
  the `#endif` of, may not be compiled), by its path's first component: `import struct SwiftUI.Text` brings in one declaration and no macro, and
  `import DepotKit.SwiftUI` is DepotKit's. The spellings are read, not resolved, so two more rules narrow
  what an overload of the same name could do: `@Observable` and `@Model`, whose SDK declarations take no
  arguments, count only written without an argument list (`@Observable()` and `@Observable(tag: 1)` keep the
  lines), and `@Test`, `@Suite` and `#Preview`, which take arguments, count only while no file of the tree
  declares a macro of their name. A same-name macro in a third-party package the file also imports, whose
  declaration the index never reads, is not told apart: that gap is accepted, and such a macro naming the name
  asked for would have a line set apart that is a use (#577). The files are read for that last gate only when
  a line is about to be set apart, once per answer, several at a time, no more started once one keeps the
  lines; the verdict is the one-at-a-time read's whatever order the reads finish in, and a read cancelled
  before it has seen every file keeps them (#582). The cheap test before each parse still lets through a file
  writing `@Suite` in a comment: a sound reading of comments and strings costs a lexer, and the files a real
  tree parses write a file-scope `@Suite` anyway. A qualified spelling is read as a construction's qualifier is, through typealiases and
  supertypes, its first name looked up around the line first, as Swift's is: inside a type declaring
  `typealias Log = Search`, `Log.Answer` is `Search.Answer`'s, and a generic parameter named `Log` around it,
  a generic typealias's own parameter or a name declared inside a function there leaves it unresolved. That
  reading never sets a line apart (#521). It is not sound: Swift also sees names the scan never writes down
  (an implicit conformance's typealiases, like a distributed actor's `ID`; a type an attached macro adds, like
  `@Generable`'s `PartiallyGenerated`; a supertype outside the index matched by its simple name; an enclosing
  extension's associated types and generic parameters), and three rounds of review each reproduced real uses
  a narrower set-apart still dropped, the third under a rule demanding a literal qualifier and every scope
  around the line held whole. So, as for a protocol (#446), a line the resolver reads as only other types of
  the name is kept, counted and noted (`1 of them writes "Item" behind a qualifier the index reads as Log,
  which declares another "Item", so may be that type's rather than this struct's`): the answer is noisier,
  and sound. The fixtures that broke each rule are kept as tests. An inheritance clause is read from outside
  the type or extension it belongs to, as Swift reads it, so the type's own members are not in scope there for
  the line or its conformer (#518).
  An implicit member's empty qualifier, a qualifier the index cannot resolve (a generic parameter, `Self`, a
  module, a type outside it), and an asked declaration that is no struct, class, enum or actor keep the line
  a use. A protocol's line is never set apart by its qualifier: every reading of one from the index tried for
  a protocol (through typealiases, supertypes, nested types of the name, an enclosing extension's associated
  types, generic parameters) dropped real uses (#446), so qualifier resolution is ruled unsound there and the
  answer annotates rather than drops. Where another owner declares a type of the name, a line writing the
  protocol's name only behind a qualifier spelled as that owner (the owner's path or a trailing part of it,
  and no asked owner's) stays listed and counted, and the verdict says how many such lines there are and whose
  spelling they match (`3 of them write "Answer" only behind Log.Shelf, which declares another "Answer", so
  may be that type's rather than this protocol's`); a conformer whose clause names it only that way is kept
  and marked `(clause writes Log.Shelf.Answer)`. A spelling comparison can add a note but never hide a site,
  and with no such owner the answer is unchanged. A `typealias Crate = Gizmo` is another name
  for the type rather than use of it, so its line is counted apart in the store's words, and the lines
  writing `Crate`, or an alias of `Crate`, are listed as uses and named for the alias (#333), as the store's
  fold does, capped at the same `typealiasFoldCap`. Only a right-hand side that is a plain name or member
  path is another name for the type, so only its line is counted apart. A generic argument, a tuple, an
  optional, a function type or a generic alias builds a type from the name
  (`typealias Book = Dictionary<String, Net.URL>`), so that line stays a use; but a use of the alias breaks
  with the type, so the alias is followed by every whole path its right-hand side writes, generic arguments
  included, by the same rules as a plain one, and the lines writing it are folded in. A member path counts
  only whole (`Net.URL` is no path to `Net`), and one led by the alias's own generic parameter
  (`typealias Depot<Gizmo> = [Gizmo]`) names no type of the tree. An alias writing the type's whole
  path behind one more leading name is not proven to name it, but is kept wherever that name may be the type's
  module (#548): where the type's file has a module guessed from its path
  (`typealias Link = App.Net.URL` beside a guessed `Sources`), its uses are listed under a clause of their
  own naming the alias and what it writes, saying why it is not proven, and its declaration line stays a use
  rather than being counted apart as another name for the type. A leading name the tree declares a type of
  is kept the same way, since that type may be invisible where the alias is written. A kept alias is
  followed past `typealiasFoldCap` and never counts against it, so kept aliases never crowd a proven one out
  of the fold and none of their uses drops. Where a kept alias shares its name with a proven one
  (`enum Holder { typealias Link = Net.URL }` beside a top-level `typealias Link = App.Net.URL`), a scan by
  name cannot tell which a use writes, so every use of the name is kept and the clause names both. An alias
  of a kept alias (`typealias Hold = Link`) is kept too, and named as an alias of a kept typealias, since it
  writes no leading name of its own. A typealias declared inside a function is no row of the index, so it
  is found by the type use its right-hand side writes, and its uses by a second scan for its name, kept to
  the file and to the sites where the nearest block declaring a type or typealias of the name declares it
  (two functions may each declare a `Loc` of another type, and an inner function may redeclare it); a
  declaration inside an `#if` clause may be compiled out, so it hides nothing further out. It
  is folded or kept by the same rules, read as declared at the top level where no type is around the
  function, and named by the declaration it sits in (`Sources.h().Loc2`); its own line stays a use. One whose
  right-hand side writes the name bare inside a type declaring its own type of the name names that type, as
  the bare-name rule reads the line, so it is not followed. A path that starts at
  an extension written by a bare name leaves the module unknown wherever the extension's module declares no
  top-level type of the name visible beyond its file and under no `#if` (#549): an alias writing any leading
  name before that path, the extension's own module included (`typealias Dec = Foundation.JSONDecoder` beside
  `extension JSONDecoder`), is kept the same way, with that reason, ahead of a guessed module's. Such an
  extension of a declared type's bare name, where that type is private, under `#if` or in another module, is
  followed the same way, and its lines are uses rather than that type's own: an extension is counted as part
  of a declaration only where the declaration is visible from the extension's file, private to no other file
  and under no `#if` the extension does not share. A scan for
  calls alone answered "no call spelled T" of a type used only through its static members, which reads as
  a deletion verdict; the empty case says uses were searched, and that a string literal was not. Where
  the store answers one declaration of the name and refuses another, a site the store listed under the
  answered one, matched by the `path:line:column` its name is written at and only in a file unchanged since
  the build, is counted apart in the refused one's verdict rather than listed twice (#333); a line writing
  both types keeps the refused one's use.

**With a store, a protocol's conformers are one list.** `where <Protocol>` prints one block, headed
`conformers of X (N: d direct, i indirect[, k inherited][, k through a typealias][, k resolved to another
declaration][, k in a deleted file][, k in a changed file without its clause] — direct
is every inheritance clause in this tree's source that writes the name, so a grep for the name finds the same
lines; a typealias to it is not followed, or, where a conformer is listed through one, through a typealias is a
clause writing a typealias of it; indirect is from the index store[; inherited is reached through a listed
protocol or class, so a grep for the name does not find it])`,
the files changed since the build counted after it, and lists each conformer once: its qualified name, kind
and location, marked `direct` where an inheritance clause writes the protocol's name (alone, in a composition,
qualified, with generic arguments or after an attribute), `indirect` where only the store has it, `through typealias <alias>` where the clause writes a typealias of
the protocol (`typealias P2 = P; struct S: P2`) — an alias whose underlying type, parsed and without its where
clause, is the protocol (an identifier or member type naming it, possibly qualified), a composition holding it
or another such alias, never one that merely names it (`Wrapper<any P>`, `Held<T> = Wrapper<T> where T: P`),
each such head matched to the store's reference to the protocol or alias by line and column, so another type of
the same name is not it —
found from the store's reference to the alias, accepted only where that reference sits, line and column, on an
entry of the declaration's own inheritance clause as a parse of the file reads it (an attribute line above it
and a clause wrapped onto the next line included; a member's type, a nested type's clause or a generic argument
writing the alias never), and checked the same way against the aliases before a conformance the store records
itself is called `indirect`, and
`direct; the index store does not have it` where a clause writes the name and the store recorded no
conformance — `direct; the index store has it through another type` where the store records none there but
records the row inheriting from the protocol through a chain of clauses, as `Ember: Answer` does where that
`Answer` is a class conforming to it. Where the store records neither, and resolves the name the clause writes, by line and column in
a file unchanged since the build, to another declaration of it in the tree (`typealias P2 = P` in a library beside
the app's own `protocol P2`), the row is marked `writes P2, which the index store resolves to Lib.P2` and counted
as `resolved to another declaration`, not direct: kept and labelled, since the clause does write the name. Where another protocol or class of the same name is declared (`Log.Shelf.Answer` beside a
top-level `Answer`), the scan by written name also finds that type's conformers or subclasses, and a clause
the store records as inheriting from it is the other type's: a row the store records no conformance of the
asked protocol for, whose declaration holds a conformance the store records to another protocol or class of
the name, in a file unchanged since the build, is left out and counted in the heading (`1 left out: the index
store records its clause as conforming to another "Answer"`). A type of the name that itself inherits from
the asked protocol, through any chain of clauses including one an extension declares, is no other type: its
inheritors are the asked protocol's too. It is the store's record that sets it apart, never the clause's
spelling, so a row in a file edited since the build stays, and so does a row that conforms to both. Rows
the tree no longer backs as built keep their mark and sort last among the rows the store or a clause lists, ahead
only of the inherited rows below — except a conformer only the store has, in a
file deleted since the build, which carries no mark (its clause cannot be read, so `indirect` would claim
what is not known) and is counted in the heading as `in a deleted file`, beside the `(file deleted since last
build)` label, and likewise one in a file changed since the build whose declaration no longer writes an entry
where the store recorded the conformance, nor anywhere the name the store recorded there, counted as `in a changed file without its clause` (one that still does
keeps its mark), so the cap
(`truncated: N more conformers`) is spent on the rows that still stand. It replaces two blocks, the store's
and the scan's by written name, which listed the same conformers twice and never said which conform directly;
the store's caption also claimed indirect conformers it does not hold, since the store records a conformance
only where a clause writes it. **A conformance line is listed once**: the `used by` verdict counts it among
its references and its rows leave it out, but only where the conformer is within the list cap and its file is
unchanged since the build, so the worst case is a line listed twice, never a site hidden; under `--refs` the
sweep leaves nothing out. With no store, and for a type that is not a protocol, the answer is the scan's block by
written name, with the inherited rows below added to it; a
second protocol of the same name keeps the store's own block, so none of its conformers leaves the answer. That
block is captioned `from the store` and no more, and a class's `direct subclasses from the store`: the store
records a conformance or subclass only where a clause writes it, so `includes indirect` was never true of either,
and a class's walked subclasses are in the block by written name after it (#602).
Why, with the source text on store rows (below): see that paragraph's figures.

**Conformers are listed to any depth, in both modes.** The store records an inheritance only as a clause writes
it (`Zed: PS`, `Sub2: Sub`), and so does the scan, so a list built from either stopped one level down: `where P`
left out a conformer of a protocol refining `P` and a subclass of a class conforming to it, under a caption that
read as complete (#594). From every listed protocol and class, and every class an extension listed extends, the
answer walks the types whose clause writes that name, by written name and to any depth, each row added once, so a
cycle of clauses ends; a row already listed, or a declaration of the asked type itself, is never added again. Each
row the walk reaches is marked `inherited through <Name>`, the simple name of the listed conformer it was reached
through, and listed after every other row, nearest first, so the row it names stands above it and the cap is
spent on the clauses writing the name first. The merged block's caption counts them as `<k> inherited` after the
indirect count; the block by written name, for a class, with no store, or beside a second protocol's store block,
appends `, <k> inherited — inherited is reached through a listed protocol or class, so a grep for the name does
not find it` to its `(N, by written name` caption, and its walked rows alone carry the mark. Both captions omit
the segment when the walk adds nothing. An extension of a type the tree declares nowhere is walked too, since it
can only add a conformance to a class from outside the tree (`extension UIViewController: P`), but only to the
classes writing that name first, as their superclass, so `enum E: String` beside `extension String: P` is never
reached (#600). The name of a typealias whose right-hand side, or a member of the composition it writes, is a
listed or walked class or protocol, by its last path component behind any qualifier, is walked too, and so is an
alias of such an alias, each alias once from each parent, so a cycle ends and a row the store refuted through one
parent is still reached through another; its rows are marked `inherited through <the alias's
name>` (#602). The walk is by written name in both modes, so a type of the same name elsewhere in the tree is
proposed too. In a protocol's merged block, a proposed row is left out, before it is added or walked further, only
where the store refutes it: it resolves to a symbol the store holds, in a file unchanged since the build, and the
store records it inheriting from the asked protocol through no chain of clauses and extensions, by USR, so a false
row's own subclasses never follow it (#601). A class's block by written name, or a protocol's beside a second
protocol's store block, takes the same check against the asked declarations of the name, where the store resolved
every one: a walked row is left out where the store records it inheriting from none of them (#602). Its direct
rows, the clauses writing the name, are never checked, so a nested class's subclass writing the bare name is still
listed there. The store is asked only of a row reached through a row it vouches for, a listed conformer it records
in a file unchanged since the build or a walked row it confirmed: through any other, its record of the step itself
may be stale (a class that gained the conformance after the build). With no store, or where the store cannot speak
for a row (it resolves to no symbol the store holds, its file changed since the build, or the row it was reached
through is one the store does not vouch for), no walked row is dropped, whatever qualifier its clause writes: the
`inherited through <Name>` mark names the step, so a row reached through a same-named type can be checked. Same-name
noise is removed only by the store's refutation: the noise is the price of a list with nothing missing, and the
store is its remedy.
A walked row's clause writes another name, so its line stays in `used by`.

**A `typealias` gets a usage verdict of its own, never the type's it names.** A `typealias` declares no
members, is never extended in its own right and has no conformers, so it is not a type declaration for the
section above, and its own deletion question was answered by the old plain `references to …` block — the
shape misread as "nothing uses this" one name over, on the name an agent has in hand more often than the
type's, since that is what the call sites spell. It gets the same section, in the same words, on its own
USR (`used by Lib.Crate: …`), asked one hop sideways: its exclusions are the aliases *of* it, and not the
declaration and extension-header exclusion, which does not carry across — a definition records no
reference to itself, and the only lines that rule could take are a use on the declaration's own line and
an `extension Crate` header, both of which stop compiling when the alias goes, the second having to be
rewritten to name the underlying type, so they count. **An alias of the alias folds in as an alias of the
type does**: `typealias Box = Crate` is discovered as an alias declaration covering one of `Crate`'s own
reference hits, and `Box`'s use sites fold into `Crate`'s verdict. It never looks through to the type:
`where Crate` does not resolve `Gizmo`'s own references, and every verdict says so in one clause (count
zero or not): "counts the alias's own name, and any typealias of it, not the type it names — that type may
still be used directly, under its own name, without this alias". The type can go on being used under its
own name after every alias is gone, and a verdict that did not separate the two would let a reader trust
evidence about the wrong thing. The empty-count summaries carry the clause worded for their surface.

**A subscript is named by Swift's rule for subscripts, not a function's.** A subscript parameter has an
argument label only when one is written before its name: `subscript(slot: Int)` is called `x[3]` and is
`subscript(_:)`; `subscript(slot slot: Int)` is called `x[slot: 3]` and is `subscript(slot:)`. The index
store names subscripts that way, so the parser does too, and `where Type.subscript` and
`where Type.subscript(_:)` both resolve it. With no store there is no name-matched stand-in for a
subscript, since its uses are `x[…]`, which spells no name to scan for; `where` and `sift diff` say that,
without the disclaimer of a name-matched list, which over a subscript alone describes a match that never
ran.

**A property is read and written, never called.** The store records each use of a `var`, a `let` or a
subscript on that declaration's own USR as a read, a write, or both at once for a compound assignment,
related only to the symbol containing it (an argument to a memberwise initializer is a plain reference at
its label); the `call` goes to the getter or setter accessor, a USR of its own. So a call query finds
nothing for a property however much it is used, and "no callers" reads as dead code, which is how a live
constant gets deleted. A property's section is headed "reads and writes", one row per line marked `read`,
`write`, `read and write`, or `referenced` where only the name was recorded; its empty case is "no reads
or writes of X recorded in the store"; a query that resolves to functions and properties together
summarises each relation on its own line. **What the store never records is said beside the section, empty
or not**: code the compiler synthesizes (an `Equatable`, `Hashable` or `Codable` conformance's reads and
writes) and access by name at runtime leave no occurrence, so a field only a conformance reads lists
nothing, and deleting it changes a saved format.

- Beyond the macro copies every relation drops, a property's uses — and its references under `--refs`,
  since a sweep edits the same lines — drop an implicit one inside the accessors of the property or of
  either sibling (below): `@Observable` rewrites each property's accessors to read it, recorded as implicit
  reads at the attribute, and an internal `@State var on` gets a `$on` whose compiler-made getter reads
  `_on`; neither is a use, and neither gives a sweep a line to rename.
- **A property wrapper's siblings are asked too**: `@State var flag` handed to `Toggle(isOn: $flag)` is
  recorded on `$flag`, a declaration of its own, and `_count = State(initialValue: 3)` on `_count`, with
  nothing on the property itself. A declaration named `$name` or `_name` that the store marks implicit and
  records as a child of the property's own parent is asked with it, and nothing more; rows are marked
  `read via $flag` and `write via _count`, and `--refs` says so in its heading (`including $flag`). A
  `_name` written in code is a declaration of its own and is never folded in.
- **A use through a sibling the store does not declare is told by its spelling**: a wrapper declared in the
  property's own module, or one such as `@AppStorage`, `@FocusState` or `@Bindable`, declares no recorded
  sibling, and a use through `_amount` or `$stored` is recorded on the property itself, one byte past the
  `_` or `$`, as a read whatever it does. The byte before the name on the source line tells the spelling,
  and the row says `used via _amount`, never the read the store wrote down; `--refs` names it in its
  heading. A property with nothing recorded in its attributes has no such use, and its lines are never
  read.
- **An observer a macro moves is said to be moved**: `@Observable` moves a property's `didSet` onto the
  storage it generates, and the store records its uses at the attribute, so the row reads
  `didSet of watched (moved by a macro)`, never the generated `didSet:_watched`; the line under the section
  says what that leaves out, and `--refs` drops the attribute's line.
- `sift diff` lists a changed property's uses from the store the same way, marks a use through a sibling
  `via $flag`, and says the same of what it cannot see.

**An enum case is named, never read, and called only where a payload is built.** The store records every
use of a case (`.fast`, `Mode.fast`, `case .fast:`, `if case .fast = x`, a comparison) on the case's own
USR as a plain reference, related only to the symbol containing it; building a case with associated
values (`.value(3)`) adds a call, and matching one does not. So neither a call query nor a read-and-write
query sees a case whole. Its section is headed "uses of X", one row per line with no access mark (a
pattern and an expression are both plain references), counted in build units as a property's are; its
empty case is "no uses of X recorded in the store", with what synthesized code does beside it
(`CaseIterable`'s `allCases` and a raw value's `init(rawValue:)` reach a case with nothing recorded);
`sift diff` lists a removed or changed case's uses the same way. The store names a case with associated
values as it names a function — `case value(Int)` is `value(_:)`, `case pair(left: Int, right: Int)` is
`pair(left:right:)` — so the parser does too; `where Mode.value` and `where Mode.value(_:)` both resolve
it, and a digest's `cases (N):` line spells the same names, so the name a digest shows is the name `where`
answers to. A name written in backticks is stored as the word they escape — ``func `settle`(`in` slot: Int)``
is `settle(in:)` — and a query written with them is unwrapped by the same rule, while a raw identifier
(`` `a b` ``), which cannot be written without them, keeps them; the signature keeps the source's spelling.
An operator function is stored with its parameters' labels (`+(lhs:rhs:)`), but it is called with none,
and the compiler's store names it `+(_:_:)`, so the store is asked by that spelling. An operator
declaration (`infix operator <~>`) is recorded by no build, so it is never refused with advice to build
(nor by `affected`, whose changed-files line says once that the store does not record it):
its uses come from the scan by written name, which matches an operator where it is applied (`a <~> b`,
`-a`, `b^^`) and where it is handed on bare (`reduce(x, +)`), listed as uses rather than as a name
written with no call. The operator declaration is scanned in that shape on its own, so a built tree whose store
answers the operator function counts a bare one as `--syntactic` does, and a bare one is recorded at the
operator's column, where the store records its reference, so it is listed once. The name is cut from a symbol by its trailing run of operator characters, so `..<`
and `...` keep their dots and `Lib.Box.==` is `==`; a `.` after an identifier is the member separator.
An applied operator writes no receiver, so the scan cannot tell one type's `==` from another's: a member
operator's name line says its sites are any type's (`"==" (5576 call sites by name, any type's ==, as an
applied operator writes no receiver to tell Session's apart, in 457 files)`) and keeps every one listed,
since any may be a use, rather than reading as that type's uses or dropping the ones it cannot place.
A free operator has no owner to tell apart, so its line is unchanged.
A declaration under `#if` is listed with its condition after its range (`[#if os(macOS)]`), as `digest`
places it. The index stores an `#else` clause as the bare `#else`; `where` names an `#else` or `#elseif`
after the clauses before it in its chain (`[#else of #if os(macOS)]`, `[#elseif os(iOS) of #if os(macOS)]`,
`[#else of #if os(macOS), #elseif os(iOS)]`) only where the file as it stands still holds the clauses the
index recorded, and prints the stored text otherwise. Such a declaration that no store resolves, in a file some store has a
unit for, is refused as `no occurrence recorded in this build; the declaration is under <condition>, which
this build may not have compiled`, with no build named: the host's own configuration is never evaluated
for it, because the store may come from a build for another platform, so the answer claims only the three
facts it has (a unit for the file, no occurrence, a condition). The header counts it unresolved, as a
declaration with no unit. `affected` refuses a changed declaration of that kind in the same words.

**A refusal is not the whole answer.** Refusing to claim semantic truth from a stale store is not
negotiable, but "build the project" costs minutes on a large codebase, and test files change most and are
built least, so they refuse most, exactly where "who calls this helper" gets asked. A refused symbol also
gets **name-matched call sites scanned from the working tree** (for a property or an enum case, every
expression spelling its name, since a scan for calls answers "no call anywhere" for one used
throughout), spelled as a *different kind of claim* rather than a weaker version of the same one: it names
the string it matched, says a name is not a symbol, and states the cost both ways — same-named members of
unrelated types and same-named locals and parameters are in it, dynamically dispatched calls are not — and
reads an empty list as no call of the name found (for a property or an enum case, no use). Each site names
the declaration it is written in (a function, initializer, subscript by its labeled name, `deinit`,
property including accessors, observers and an assigned closure, an enum case's associated-value default,
or the type around them), so a call in a subscript's getter is never credited to the type that declares it.
It never moves the header's semantic axis.

**Each name-matched site carries the text of its line**, because a location is read next: in a paired
benchmark the agent followed almost every location answer with a grep or a read to see the lines it listed,
and an answer that carries the text needs no second call. Measured in `Benchmarks/RESULTS-single-call.md`,
tracing a string went from three calls to one and its raw input fell by more than half against the arm
without sift, and finding callers and conformers went from about +16k raw input per run against that arm to
about +3.5k. A file's path heads its rows once, indented, and each line is its own row,
`    :149  in SyntacticCallSite.reading(_:)  | <the line's source text>`: the line, `(×N)` where N sites
share it, the enclosing declaration with any mark the section adds, and after `  | ` the source line
trimmed, each run of whitespace one space, cut at 140 characters with `…`. A line the scan could not read
prints its row with no text. Caps, paging and every count still count sites, never rows or characters, and
no site leaves the answer to make room for text.

**A site answered from the index store carries its line's text the same way** (callers, uses, reads and
writes, overrides and implementations, `used by`, and the `--refs` sweep) while its block holds at most 40
sites (`siteTextLineCap`): a `  path (n):` heading per file, then one row per line, ascending,
`    :18  <caller>[ — <access>][  ×N units]  | <text>`, or `    :18  | <text>` under `used by`; a row the
compact form folds by caller is listed once per line instead. Above 40 a block keeps its compact form. The
text is read from the file as it stands, so a file changed or deleted since the build prints its rows without
text and keeps its staleness mark on the heading: the recorded line may have moved, and the text now on it
would be another line's. The hook's reader of a `where` answer (`ExactAnswer`) locates each such row under its
heading, and none under a heading marked changed. Why, with the one conformers list (above): in the
`sg-live10` benchmark finding conformers cost 46% more session price with sift than without, and the agent
grepped after `where` 1.9 times a run; with both changes the task is +7% and 0.3 greps a run
(`Benchmarks/RESULTS-live.md`). The cost: on the callers task, where a resolved answer was already trusted,
the text bought no saved grep, and the win shrank from -19% to -9%.

**A name whose declarations are all functions is narrowed by their argument labels.** A member's bare name
is shared across a codebase (`run`, `load`, `update`), so the fallback for one method listed every call of
the word. The question already fixes the declaration, and its parameters narrow the list without a store:
a call is kept only when its written labels could call one of the declarations of the name the query
matched (every one, not only the few semantic relations are resolved for), with a defaulted argument left
out, a variadic or parameter pack taking any count, an unlabeled trailing closure standing for any
parameter and a labeled one for its own, and a backticked label read as the name it escapes; or when its
callee is spelled with compound labels equal to one of theirs. Overloads keep what any of them could take.

- **An initializer is called through its type**, so its sites are scanned for by the type's name and listed
  as `Box.init`: the direct and `.init` forms, `self.init`/`Self.init`/`super.init`, `.init` where a
  binding's or return type is `Box`, and `@Box` wrapper attributes and `$label:` projected-value calls where
  `Box` is a property wrapper in the repository, with the arguments the attribute supplies. `Box.init` or
  `Box.init call` handed on unapplied is a site; the type written with no call is not, nor is an `@Box`
  that is no property wrapper (a result builder, a macro such as `@Entry`) or a qualifier naming another
  module. The enumerated forms and the wrapper machinery live in the scanner's doc comments and tests.
- **`Self(x)` and `Self.init(x)` are calls of the innermost type around them** (#496): inside `Box`, a
  closure in it or an extension of it, `Box.init`'s; inside `Box.Inner`, `Inner.init`'s, never `Box`'s. In
  an extension of a type its file declares as no struct, class, enum or actor (a protocol's, or one
  declared elsewhere), `Self` may be any conforming type, so the call is counted for every initializer
  asked, beside its list as an implicit `.init` is (`but Self(…) in an extension is called …`), never
  dropped; asked of the protocol's own initializer it is listed as that requirement's, as the index store
  records it. A file spelling `Self(` is parsed for an initializer sweep for this reason (7 of ~1,300
  files here). A `self.init` delegating in such an extension is not counted: common in extensions of
  types declared elsewhere, it would bury the list. With a store, declared initializers already get
  these calls from it; a memberwise initializer's sweep is name-matched even then, and it said "no call"
  of a struct built only through `Self(…)`.
  The pre-filter reads `Self`, any whitespace, then `(` (`Self (x)` compiles as a call), and `where --at`
  reads a revision's files spelling it for an initializer target, saying so on its `read:` line. A
  memberwise initializer's sweep keeps a held call or an implicit `.init` only where its labels may reach
  the struct's initializers (memberwise, decoding, protocol-lent): one none of them takes would not
  compile on it. Its count says so (`is called 4 times with those labels`), as a declared initializer's
  does; it dropped held calls by label without a word while keeping every implicit `.init`.
  An extension whose where clause pins `Self` to a type written as a plain name
  (`extension Maker where Self == Lid`, this repository's own idiom for a trait's static factory) makes
  its `Self(x)` that type's call, listed in `Lid.init`'s sweep wherever `Lid` is declared; `Self == Box<Int>`
  pins `Box`. It is never the extended protocol's: the store records it as `Lid.init`, not as `Maker`'s
  `init` requirement, so `where Maker.init` neither lists nor holds it, where it listed every pinned call
  as the requirement's. Asked of another type, the call is held for it unless the extension's file
  declares `Lid` as a struct, class, enum or actor: the name may be a typealias of the type asked (`typealias Cap = Lid`
  pins `Lid` under another name) or one declared in another file, which the scan of one file cannot
  tell apart, and a site lost there was missing from every answer. A conformance (`Self: Maker`), a
  member type or an optional pins nothing, and the call stays held.
  A stored property's no-store `--refs` sweep, which lists the calls passing its name as a label to the
  memberwise init, lists a held `Self(size: 1)` flagged and counted apart (`writing size: to Self(…) on a
  type the scan cannot tell, which may be Solo, flagged`), never as passing it: nothing tells it builds
  `Solo`. One whose labels no asked struct's memberwise init can take is not listed, but counted
  (`1 writing size: to Self(…) that no asked type's memberwise init takes, not listed`): left out unsaid,
  the site was missing from the answer while a typed call with such labels was counted.
  Held for every struct declaring the property, it is judged by each before it is said, and its flag
  names only the structs whose memberwise init may take it: judged by the first struct alone, one that
  struct could not take was left out of `where size --refs` while `where Pair.size --refs` listed it.
- With a fresh store, `where` and `diff` answer a wrapper's initializer from the store and add a
  name-matched block of the `@Box` sites the store records no call at, kept only where the store's own
  facts back them. A call is kept unjudged where a file those facts are read from was written since the
  build, and each such file is judged for the header, so the answer reads stale rather than "no callers"
  under `fresh`.
- Each site is listed once, under the one initializer its labels reach, or, reaching none or several,
  once for the type. Sites are narrowed by the labels of the initializers the index has rows for, but only
  when the query itself names labels (`where Box.init(size:)`); a site matching none of them is dropped and
  counted by name. A bare query (`where Box.init`) is asked of every declared initializer at once, so a
  site matching none stays listed: it can only be a call of an initializer the compiler wrote (a memberwise
  one, `init(rawValue:)`, a decoding `init(from:)`) or one inherited from a superclass. A call through a
  subclass or a typealias is missed either way. An `.init call` whose type the scan cannot tell is not
  listed but counted after the list, narrowed by the same labels. A type declaring no initializer is still
  answered as `Box.init`, with one line on who writes its initializers (the compiler, or the superclass),
  never as a path that does not resolve, which would list every other type's `init`.
- Where types share the name (a top-level `Inner` and `Outer.Inner`), the store's reference on a site's
  line says which one it builds, and a site it records for another is dropped from a type's list and counted
  on the name's line. Without it nothing is dropped: a site whose qualifier the index reads, through
  typealiases and supertypes, as another type's owner is kept and noted beside the count by name (`1 of them
  writes "Item" behind a qualifier the index reads as Base, which declares another "Item", so may be that
  type's rather than this struct's`), as a type's qualified use is, since Swift also sees names the scan never
  writes down (an associated type a conformance infers, a macro's types, a supertype outside the index).
- **Labels never drop a site**: a type may have initializers no name scan can see (an extension in another
  module's, literal coercion, a macro's, one inside `#if`, the memberwise one it hides), so labels none of
  the known initializers take, where another candidate's do, only credit the site to that candidate and flag
  it under this one, `(labels fit Other.T)`. The site's scope likewise only credits: a site kept for
  several types is listed under each, flagged `(builds A or B — its scope names B)` under those its scope
  does not name, as is a site qualified with a name the index cannot resolve or written inside a type whose
  superclass or protocol is outside the index. A qualified call of something else spelled like the type
  (a static function `Space.Gadget(…)`) is kept and noted as one the index reads as calling no init (`behind
  a qualifier the index reads as Space, which declares no "Gadget", so may call no Gadget.init`). `sift diff` matches a changed
  initializer on its type's name the same way, unnarrowed.
- **The receiver is judged only to keep a site.** A call that may be a method named on its type and given
  only its instance (the callee of another call, as in a curried `T.m(x)(…)`, or one unlabeled argument on
  a member of something that may be a type) is kept whatever its labels; `Self.m(x)` is kept only inside a
  type declaring the method. Otherwise the receiver drops nothing, since a written type in front of the
  call can be a subclass, a typealias or a protocol that reaches the member, and only the store resolves
  which; a label is a fact of the declaration. **Access control is the one exception, and it rests on the
  language rather than on the receiver**: a `private` or `fileprivate` member can be used only in the file
  that declares it (its type's extensions there included), so where every declaration a name's list stands
  for is one, its name-matched sites are narrowed to their declaring files, and the list's line says so and
  counts the sites dropped. `open`, `public`, `package` and `internal` members are unnarrowed. A name shared with a property, an enum case or a type, and a
  declaration whose stored signature does not parse back to its labeled name, are listed by name.
- **A qualified query narrows a property's uses by receiver as it does calls** (#487). A use carries the
  receiver it is written with: a bare name the types it sits in, `U.m` or `U(y).m` the type `U`, and `x.m`,
  a leading-dot `.m` and a key-path component none, so they are kept. A bare `m` inside a type that
  is none of `T`, its subclasses, supertypes or extensions is that type's own or a local, and is dropped and
  counted with the calls on the name's `on other types dropped` clause; one inside a type nested in `T`, or
  at top level, is kept, since it may be `T`'s static member. A type the tree gives a
  `subscript(dynamicMember:)` (in its declaration or an extension, or inherited) may hand on any member, so a
  site written on it or inside it is kept under every qualified query, calls included. One declared only
  outside the tree (SwiftUI's `Binding`, Foundation's `AttributedString`) is not seen, so a site written on a
  type the tree does not declare is kept too (#514), unless the type is on a closed list of standard library,
  Foundation and Dispatch types known to have no such subscript (`PlainFrameworkTypes`); the name's line
  counts the sites kept that way, `N on types outside the tree`, so the list never reads as proven uses.
  A written type name is another type's only where a tree declaration proves it (#537): a type in sight of the
  site (top level, under no `#if`, in the site's module, and in its file where private) whose every supertype
  the tree declares, since a dependency's supertype may carry `@dynamicMemberLookup`. A name the site's file
  binds as a value (a parameter, local, closure parameter or local function) or the tree declares as a case,
  function or property is untyped and kept; a name behind a qualifier (`SwiftUI.Binding`, `App.Orchard`) is
  kept and counted outside the tree, since the scan does not resolve the qualifier. A nested or out-of-sight
  tree type proves nothing, so a name on the closed list is still read as the framework's plain type unless
  some tree type of the name, nested or under `#if`, has a supertype outside the tree, which may be what the
  site writes and so keeps it. Swift looks a bare name up in the members of the types around it before the
  module's top level, so a name a supertype outside the tree of any type around the site may supply is kept
  and counted outside the tree: a superclass or a dependency's protocol may supply any name (`Current` a
  Kit superclass's property, `Item` its typealias), and a framework protocol only the names a closed table
  holds for it, its associated types (`Element` and `Iterator` for `Sequence`, `ID` for `Identifiable`); a
  protocol on neither that table nor the inert list (`Equatable`, `Hashable`, `Comparable`, `Codable` and its
  halves, `Sendable`, `Error`, `CustomStringConvertible`, `CustomDebugStringConvertible`, `CaseIterable`,
  `AnyObject`, `BitwiseCopyable`, `~Copyable`, `~Escapable`, which supply none) is read as a dependency's. A
  standard raw-literal type in an inheritance clause (`String`, `Character`, `Int`, `UInt` and their sized
  forms, `Float`, `Float16`, `Double`, `CGFloat`) is an enum's raw type and supplies only `RawRepresentable`'s
  `RawValue`; the same type extended, directly or through a typealias, is read as itself. A generic parameter of a type around the site (`Item` inside `extension Box<Depot>`) is kept
  as a generic parameter in the type's own body is, and so is a name a where clause around the site writes,
  an extension's or a function's own, on either side of a requirement and behind `Self.` or not (`Element`
  in `extension Array where Depot == Element`), where the type around it is one the tree does not declare
  and may own the name by the same table (`Array` its element and collection names); the concrete type on
  the other side (`Spare` in `where Element == Spare`) is not. A type around the site that the tree does not
  declare (`extension Holder`, `extension Sequence`) counts as a supertype outside the tree of its own scope,
  read by the same table, so `Array` keeps no `Spare` while `String` keeps any name; a typealias around it
  (`extension DepotBox` for `Box<Depot>`) holds the generic parameters of the types it stands for, followed
  through typealiases, and one written with sugar (`[Depot]`, `Depot?`) counts as outside the tree itself.
  A type around the site declared inside a function shows no supertype to the scan, whatever a top-level
  type of its name declares, so a site inside it is kept and counted outside the tree.
  An extension written with the bare name of a type the tree declares only inside another type (`extension
  Label` beside `enum Theme { struct Label }`) extends a type outside the tree, read by the same table; a
  site inside the nested type itself, or in `extension Theme.Label`, is read by its declaration. Any extension
  written as no tree declaration of the name in its sight is written, by path or module and path, extends a
  type outside the tree too (`extension UIKit.UILabel`; `extension Label` where the top-level `Label` is in
  another module, private to another file, or under an `#if` the extension does not share).
  An attribute on a type around the site, an extension of it or a supertype the tree declares, or on
  the receiver's type, that the language does not define and that names no tree type (a global actor) may be
  an attached macro adding a typealias or a dynamic member, so the site is kept and counted outside the
  tree. A supertype written behind a qualifier that is no module or type of the tree (`Dep.Shelf`) is
  outside the tree whatever the tree declares under that simple name. A public type another tree module
  declares is **not** used to drop a site, even where the site's file imports that module: the scan cannot
  see dependencies, so the name may resolve elsewhere, and only an index store can prove it. The ways it
  does, each pinned as a kept site in `WhereImportedTypeKeptTests`: two imports whose overloads both give
  the name (`import Dep; import Kit`, a generic `@dynamicMemberLookup` `Dep.Crate`), a scoped
  `import struct Dep.Crate`, a freestanding macro (`#aliasCrate`) at the top level or in a type body that
  declares a typealias of the name (the symbol visitor skips macro expansions), another imported tree
  module that imports this one with a peer macro generating the name, and a generic parameter of the name on
  an extended type.
- A function handed on unapplied is a site too, since it is used without a call: a compound name
  (`T.f(x:)`, `.f(x:)`, `f(x:)`) narrowed by its labels as a call is, and with no labels any name in a
  `#selector`, or `T.f` handed to a call where `T` declares the function. Bare `f` or `x.f` reads as a
  same-named local or property and is not listed; where nothing is, the answer counts and shows them, one
  row per line, after the "no call spelled" line, so a function reached only that way never reads as
  unused, in `sift diff` as in `where`. With a store, a function's callers are its `ref` occurrences, not
  only `ref|call`; one with no call is marked `referenced, not called`, and a caller folded to one row
  carries that mark only when none of its sites calls (`called and referenced` when some do).
- The name's line says what ran and what it dropped (`"run" (477 call sites by name, 16 with the labels
  (in:ceiling:namedFiles:), in 7 files — for …)`), so the by-name count the disclaimer rests on stays in
  the answer, and a list the labels emptied says so rather than reading as no call of the name.
- **What it drops that it should not**, each named in the header's narrowing sentence: a call of a
  declaration the query did not match (a call through a base class or protocol reaches an override or
  witness whose labels or defaults may differ, and a macro can generate a peer overload with labels of its
  own); a subclass's or conformer's `Self.m(x)` naming an inherited method unapplied; and a method given its
  instance through a metatype held in a lowercase name (`let meta = T.self; meta.m(x)`).

### `search <query>`

Finds declarations by **shape** rather than by name — the one axis a table of declarations cannot serve,
since "which test functions wrap a call in an unstructured `Task`" is a question about form that grep
cannot answer either, the pattern spanning nesting and line breaks. Whitespace-separated `field:value`
terms, ANDed, each negatable with `!`, over `kind` `attr` `name` `calls` `uses` `inherits` `modifier`
`effect` `has` `sig` `imports` `path` `owner`; a bare term reads as `name:`, case-insensitively, and the answer
echoes the query as parsed. `kind:` takes every kind the index holds, so an enum case (`kind:case`), often what a
rule or verdict is named by, is a result like any other: each name of `case a, b` is a declaration of its own,
named and signed as `where` and `digest` give it (whitespace-collapsed, shown cut at 200 characters), at the line the `case` is written on. **Every unusable term fails at parse time and the rejection lists the valid
fields**, because a typo that parsed returns a confident zero, and for a lint-shaped query zero reads as
"the codebase is clean". **A misspelt word of the grammar is read and noted, and a misspelt value never is
read**: a spelling has one meaning, so `in:` and `file:` are read as `path:` and `kind:function` as
`kind:func`, with a line under the header naming each reading (a refusal that follows a heal still names
it), while a value is a meaning, and a near miss read as the nearest name would be believed and wrong. A
statement keyword under `kind:` (`kind:switch`) is refused, with the reason (a statement is not a
declaration) and the terms that do find a name inside a body, `uses:` and `calls:`. `calls:foo()` is read
down to the base name (`read calls:rendered() as calls:rendered`), since only base names are stored; anything
inside the parentheses (`calls:save(to:)`) is read down the same way but carries its own sentence, since no
argument list or arity is stored and it now matches every call named `save`, whatever its labels. A
qualified callee (`Foo.bar()`) is never indexed, so it refuses naming that and suggesting the base name;
any other parenthesized shape refuses rather than matching nothing. Three properties decide what answers
mean: **it reads the working tree, not the index**, so it has no staleness axis and never refuses;
**`calls:` and `uses:` match written names, not resolved symbols**, and say so, because a shape hit is a
lead to confirm with `where`; and **a body term on a container asks about everything it holds**. Cheap
declaration terms run first, so a query of purely cheap terms never pays for a body scan. Matches page on
an offset cursor, 120 to an answer, the total always stated.

**`name:` takes a substring, any of several, or a regex.** `name:Fresh` matches a declaration whose name
contains "fresh" in any case; `name:open|close` any of its `|` alternatives, each such a substring; and
`name:/pattern/` a regex over the name, case-insensitive and unanchored, tried on a function's, initializer's
or subscript's name with and without its argument list, so a `$` can end at the base name. A value made only
of operator characters (`||`, `|=`) names an operator and stays a literal substring. A regex that does not
compile is read as the words it plainly spells (its `|` alternatives once grouping parentheses are dropped),
with a line under the header quoting the regex engine's reason; one that spells no plain words is refused in
one line quoting that reason. A repeated group (`(…)+`, `(…)*`, `(…){n}`) is refused in one line too, since
matching one can take unbounded time. Every field takes `a|b` for any of several (a repeated field prefix,
`kind:a|kind:b`, is read as `kind:a|b`), and `path:` and `sig:` take `/regex/` too, case-insensitive while a plain
`path:` or `sig:` value stays a case-sensitive substring; every other field refuses a regex, whole even when it
holds a `|`, saying what its value does match. The echo line says how each pattern was read, for every field
(`search name:open|close — name: any of open, close`; `— kind: any of struct, enum`; a regex echoes
`— path: a case-insensitive regex`), so an alternation is told apart from a literal name
holding a `|`; only a plain substring is taken as the name a rootless query is resolved by, since a pattern
spells no one declaration's name. Why: in a paired benchmark's locate-and-fix task the agent's first `search`
was an alternation or a regex in 9 runs of 10, and each was refused; with both forms read, refusals fell from
0.8 to 0.1 a run and the task went from 11% dearer in session price than the arm without sift to level (-1%,
`Benchmarks/RESULTS-live.md`).

**A pattern's whole-name matches come first.** Under an alternation or a regex, the declarations whose own
name (argument list aside) the pattern matches whole — equal to an alternative, or a regex match from start
to end — are listed ahead of those it matches only in part, each group in path-then-line order and every row
kept. Where both groups are present the summary line ends `; the <k> whose whole name matches come first`, a clause that is the same on every page and under `--count`; no line marks the boundary, since
the clause's count already places it, and where only one group is present the answer is the plain one. A plain
single word keeps path-then-line order. Why (#525): short alternatives turn up inside many longer names, so
`name:key|save` over this repository listed 229 declarations in path order with the 32 named `key` or `save`
scattered through them, the two the caller wanted at rows 130 and 131, past the first page; whole-first puts
all 32 on rows 1–32. Over seven alternations and regexes from the usage log the whole matches moved from
scattered through the answer to its leading rows, with no row gained or lost, and the #475 benchmark queries
kept every row. Returning only whole matches was measured and rejected: one of those benchmark queries, a
three-word regex with `kind:func`, matches 35 declarations in the benchmark app, none of them whole, so it would
answer nothing,
and ordering already puts every whole match on the first page in each query measured.

**`owner:` names the type a member is declared in.** `owner:StructuralQuery` matches a declaration whose
innermost enclosing type or extension is `StructuralQuery`: a member written in its body and one written in
any `extension StructuralQuery` alike, so `kind:func modifier:static owner:StructuralQuery` is its static
functions, wherever they were written. The value is matched exactly, case-sensitively, against the owner's
name or its qualified path (enclosing type names joined with `.`, generic arguments dropped), so a member of
`Outer.Inner`, nested in the body or in `extension Outer.Inner`, answers to `owner:Inner` and
`owner:Outer.Inner` and not to `owner:Outer`. A top-level declaration has no owner, so `!owner:X` includes
it. `in:` is not this field: it was already read as `path:`. Why: in a nine-task run an agent asked for "the
static functions of a type" with `inherits:`, the only type-shaped field there was, and spent three more calls
reaching the answer by hand (#485).

**A miss names the term that emptied it.** Where no declaration matches, the verdict line keeps its form and
adds which term removed the last candidates and how many: `no declarations match — scanned 12 file(s);
inherits:DepotStore removed the last 3 declaration(s)`, or `…; kind:actor removed all 412 declaration(s)`
where no other term removed any. The terms are applied in the order the scan applies them —
declaration terms in query order, then body terms in query order — so the term named is the one that took
the last survivors in that order, not necessarily the last term written. Where no declaration reached the
terms at all (no file passed the `path:` or `imports:` gate, or the files declare nothing) the line stays
bare. `--count` carries the same line. Why: a bare "no declarations match" left the caller to drop terms one
call at a time to find the wrong one (#485).

**`--count`** answers the header, the summary line, and — when the matches span more than one module — a
per-module breakdown, and stops there: no per-match listing. Both numbers agree with the full answer for
the same query. It is the CLI's `--count` flag and the MCP `search` tool's `count` argument.

### `similar <Type.member | Module.Type.member | File.swift:12-40>`

Shows the helper that already exists, before another one is written. The complement of `search calls:…`:
that query is the question when all you have is the one call a helper cannot do without, and this one is
the question when you already hold something shaped like it. The evidence is in this repository: the
temp-file-and-`rename` atomic write was written three times, by three builders none of whom looked. Ranks
every declaration in the working tree by how close its **syntactic shape** is to the target's, with
`path:line-endLine`, the qualified name, the signature, the rarity-weighted callee overlap that gated it,
and the shared callees that earned it — the number beside each hit is the gate's own number, not the
composite score it is ranked by. CLI only, on `affected`'s and `run`'s reasoning. No source bodies: serving
them would cost what reading the files costs, which is the thing it replaces.

Four properties decide what an answer means. **Rarity-weighted callee overlap is the gate, and the only
gate** — inverse document frequency over the tree actually scanned, so a common name like `append` or
`map` counts for a fraction of what a rare one like `rename` does (on this repository's own scan: `map`
weighs 1.66, `append` 2.24, `rename` 6.68, a singleton callee 8.76), while the control-flow skeleton and
the written parameter and return types order what is already through and can put nothing on the list.
Several common callees can still add up to one rare one, which is why `shares:` lists what earned the hit.
Floored on the composite score instead, two one-expression bodies collect a quarter of a point for the
same trivial skeleton, and a one-line `split`-and-`map` outranked the three atomic writes. **It reads the
working tree, not the index**, like `search`, so it has no staleness axis and never refuses. **It matches
written names**, so two unrelated types' `save` are one name here and a hit is a lead to confirm with
`digest Type.member`. And **the list is a lower bound, never a verdict**: a helper built on a different
call, or behind a macro, is shape this scan cannot see, so an empty answer means nothing close by callee or
shape, never that there is nothing to reuse.

Three refusals rather than a degraded ranking. A **target whose body makes fewer than three calls is
answered as too thin to compare**, and named the `search` recipe instead: one shared common name is enough
to top a list built on one piece of evidence. An **overloaded or otherwise ambiguous target lists its
labeled candidates**, as a digest of the same name does. A target **nothing with a body answers to says so
and says what a candidate is** (funcs, inits, subscripts and computed vars with a body; a protocol
requirement, a stored property and a type itself have none), because an empty ranking would read as "there
is nothing like this". Candidates exclude the target itself, ties break by path then line, and ten hits are
listed with the total above them.

**No syntax tree survives its file**, though the whole tree's shapes are held at once to rank them: each
declaration's fingerprint (callee set, control-flow token sequence, written type names) is extracted inside
the per-file call and the tree dropped there.

A test's own declarations are in the candidate pool and in the rarity population, deliberately: a test
helper is reusable too, so excluding `Tests/` would hide the near-duplicate a fixture-builder was about to
write for the third time.

### `dupes [path …]`

`similar`'s comparison run as an audit: every group of near-duplicate bodies across the working tree, or
across the files under the repo-relative paths given, with no target to anchor it. CLI only, on
`similar`'s reasoning. Same fingerprints, rarity weighting and score as `similar`, and the same population
rule: declarations whose bodies make fewer than two calls are left out. Three things are its own.
**Candidate pairs come from an inverted index of callee to declarations**, so the cost follows the pairs
that share a call rather than the square of the tree, and a callee more than 40 declarations name proposes
no pair on its own. **A pair is kept on two gates**: 0.50 rarity-weighted callee overlap (above
`similar`'s 0.35, because an audit has no target to anchor it) and shared callees that weigh at least what
2.5 names no other declaration calls would. The second gate exists because the overlap is a fraction: two
one-line bodies that make the same two calls score 1.00 on nothing, and on overlap alone this repository's
`Sources/` answered 646 pairs, most of them one-liners; 2.5 units took it to 82, most of them real. Both
numbers were picked from this repository's own tree; `--min <overlap>` moves the first (0 to 1). A body
nested inside another is never paired with it, and a declaration spanning fewer than 4 lines, signature and
braces included, is not compared at all and is counted on the census line.

**Test and preview code** is a test function, a SwiftUI `body` or `previews` property, or a file under a
path component (a directory or the file's own name) ending in `Test(s)`, `Mock(s)`, `Fixture(s)`,
`Stub(s)`, `Preview(s)` or `Generated`, starting with `Mock`, `Fixture`, `Stub`, `Preview` or `Generated`,
or ending in `.generated` — read from the path and the parse, never from imports. It is counted twice where
production code is concerned: a pair of production declarations is proposed by a callee that at most 40
*production* declarations name and priced against production code's own rarity, and any other pair against
everything compared (#453: on this repository the tests pushed `contentsOfDirectory` and `fileExists` past
the bound, and a planted copy of a production helper was never compared with its original, though
`dupes Sources` paired them at 1.00).

**Groups are built by complete linkage** (#453): every two members of a group cleared both gates. Pairs are
taken closest first (ties by index), and two groups join only where every pair across them was kept;
union-find, which read `A~B, B~C` as one group of three, chained 42 declarations whose bodies were barely
alike (difflib min 0.02) into one group here. Two members sharing one control-flow skeleton of at least two
tokens and one non-empty set of written types — what a copy keeps through renamed locals — are *copies*, and
the group's header says whether all or some of its members are. A declaration with a kept pair
that ends in no group is counted on its own line, pointing at `similar`. Each group shows its closest pair's
overlap and, at three or more members, its weakest pair's.

**Ranking** (#453): before, all ten listed groups scored 1.00 and the order was a tie-break. Now groups
holding copies come first; within that and below it, groups rank by the lines folding one into a single body
would save (every member's span but the longest) times the square of its weakest pair's full score; groups
made only of test and preview code come after every other unless `--tests` ranks them together, and
`--no-tests` leaves that code out of the comparison (counted). Judged from two probes of this tree: two
copies of `ShardLedger` helpers with renamed locals (overlap 1.00 and 0.72) land 8th and 6th of 560 groups;
a third, 20-line body calling the same six names in another control flow joins the 1.00 pair (every pair
clears the floor) and that group still holds the first page, 10th. Ten groups are listed per page on the
`--offset` cursor, `truncated: N more groups — pass --offset M`, with the total on the summary line.

**A lower bound, never a verdict**, and the caveat says why: the same callees do not mean the same
behaviour, a body that inlines what another calls shares nothing with it here, and a pair that shares only
callees many declarations name is never compared. Where nothing clears the floors the answer says so in one
line, with the floors and the numbers it was read against.

### `strings <text-or-key>`

Traces display text to its localization key and back, across `.xcstrings` and legacy `.strings` catalogs,
then lists where each matched key is **spelled as a string literal** in Swift source. Values match
case-insensitively in any language, keys exactly or by substring; catalogs are few and small, so this
reads the working tree and has no staleness axis. The echo line (`strings "<query>"`) and a catalog
value or key write each backslash as `\\` and each control character as an escape (`\n`, `\r`, `\t`, `\0`, else `\u{…}`), and the echo and a value write `"` as `\"`, as a Swift literal spells them, and so does a key on the literal-occurrence and accessor lines, where it sits between quotes, so neither can split its line or end its quotes early, and a backslash-n in the text never reads as a newline. A key holding format specifiers (`%@`, `%lld`, `%1$@`, `%.2f`) is also **spelled by an interpolated
literal** whose text between interpolations is the key's text between specifiers, one interpolation per
specifier (`"Hello \(name)"` for `Hello %@`), and that literal's `file:line` is listed like a plain spelling;
the match is by position and text, since an interpolation's type is not known to a syntactic read, and the
text is the text the literal prints, so `"Say \"\(x)\""` and the raw `#"Say "\#(x)""#` both spell `Say "%@"`.
A file is read for these only where it may hold such a literal: it writes an interpolation (`\(` or a raw
literal's `\#`), and each run of the key's text free of the characters an escape can stand for (quotes,
backslashes, control characters) appears in it, unless it writes a `\u{…}` escape, which can stand for any. A `%%` in a key is one literal `%` of that text (`%lld%% done` is spelled `"\(n)% done"`), and a `%` before a space is text, so `50% off` is a plain key. A key made only of specifiers (`%@`, Xcode's key for `Text("\(x)")`) has no text to match, so no interpolated literal is its call site. A key referenced only through a generated accessor has
no literal spelling, so **the answer follows the accessor** rather than letting an empty site list read as
"unused" or handing the gap back as advice, for the reason `where`'s sites carry their text: a trace that
took `strings`, `where` and a read is one call. The key's last dot-separated component, where it is a Swift
identifier, is taken as the accessor's name, and under the key the answer lists that name's declarations
(`declared: <kind> <qualified name> — path:line`, at most 5) and the lines writing it
(`path:line in <enclosing declaration>: <source text>`, whitespace collapsed and cut at 140 characters, at
most 12), each cap with a `+N more` line naming the `where` query that lists them all, under a heading that
says they are matched by written name, so a same-named symbol elsewhere may be among them. Both lists are
read from the working tree, each file parsed once, never from the index. At most 3 keys are followed per
answer; a key past them, or whose last component is no identifier, keeps the one-line advice to look the
generated symbol up, and a name nothing declares or writes is said so on the key's line. Every query also scans the working tree's Swift files for **string literals whose text holds the
query** — the whole answer in a CLI or tool repo with no catalog — each named by the declaration enclosing
it (from a fresh parse, never the index's stored ranges) and its `file:line`, capped at 20 sites.
Production sites are listed and test sites (a file importing a test framework, the split `where` makes)
are counted per file on one `in tests:` line, so fixtures never spend the cap; a query matching only test
sites lists them. Only text inside a literal counts, comments excluded, and an interpolated expression's
source is never read as wording — though a query may cover the place an interpolation stands, below.
Wording a `+` builds — `"the build did " +` on one line, `"not complete"` on the next — is held by no
literal, so a **run of plain literals joined by `+`** (closed, with no interpolation, across lines, any
comment between them skipped) is read as the text it prints. A run holding the query that no piece of it
holds alone is a plain site at the line of the first piece the match touches, shown as the touched pieces
as written with ` + ` between them (`"the build did " + "not complete"`) and windowed on the match; a
piece holding the query is already its own site, so the run is not listed again. Any other code between
two pieces, an operator longer than `+` (`+=`), a `#` directive, a `"""` block or an interpolated piece
ends the run, and the lines of a `"""` block are never joined.
Wording that a program assembles — `"truncated: \(remaining) more \(unit)"` prints "more member lines" —
spans an interpolation, so no segment holds it: a literal no segment matches is matched **around its
interpolations** instead, against the text its segments print, each `\(…)` read as a wildcard for some of
the query's text, or none. Such a match crosses at least one interpolation. A wildcard may be empty, since
an interpolation can print nothing; a non-empty one starts and ends on a non-space; each ends on a word
boundary of the query and starts on one unless it continues a word the literal text before it began — so
`key\(s)` matches "key" and "keys", the commonest interpolation in CLI wording, while `\(verb)ing` matches
only a query that does not cut through that word. A digit followed by a letter is a place a wildcard may
end too, since a number printed against its unit is one query word: `\(n)ms elapsed` matches "42ms
elapsed". This is the one way two pieces of literal text can hold parts of one query word (`v\(n)ms`
against "v42ms"); each piece is weighed on its own below. Some piece of literal text matched must hold a word of
three or more letters or digits, so interpolations, spacing and short words ("of", "is") never match alone.
**A match is listed only when the literal text it matched holds part of at least two words of the query**:
one word is what a query shares with most literals of the tree around their interpolations (`"\(n) lines"`
against "more member lines"), and listing those buried the real site past the cap. A piece holds part of a
word only when it holds at least three of its characters, or the whole of a shorter word ("in", "of"): a
letter glued to an interpolation (`P\(index).swift` against "Package.swift") is not part of the query's
word, so it never makes the second word a match lists on. A literal is credited to every query word some
one-word alignment of it matches (`"mike \(i) zzz \(j) oscar"` matches "mike foo oscar" on "mike" one way
and on "oscar" another), each word's alignment kept with its own window, so a rare word is never hidden
behind a common one the same literal also matches. The rest are counted on
one line, tests included, with each word and its count in query order — `36 lines match it on only one
word of literal text, tests included, not listed — "more" 6, "lines" 30; add a word to narrow` — so the
answer accounts for what it omits; a line credited to two words counts under both. **When that leaves
nothing listed** — no catalog entry, no plain production site and no two-word match — the one-word
matches on the query's rarest words are listed after all, at most `fallbackSiteLimit` (8) production lines
in all: words are taken rarest first, words on equally many lines together or not at all, while the lines
they hold stay within the limit, so five words of five lines each list nothing rather than whichever came
first. Stop words (the, a, an, to, of, at, in, on, is, it, and, or, that, this, for, with, be, compared
case-insensitively) are never taken, so a query that shares only "the" with the tree lists nothing and
keeps its `no Swift string literal contains it either` line. The sites are production only, in path
order, each shown on the rarest word taken that it holds, under a heading that says they matched on one
word that matched this way on at most 8 production lines (the count is of these one-word matches, not of
every line that holds the word): a word that rare is the query's distinctive one, where a common word
("lines", "file") still names too many sites to list. The limit is a threshold, not a ranking; measured
under an earlier rule, a limit of 8 per word rather than in all, on 240 queries drawn from this tree's
literals it listed the target in 92% of them against 79% for the two-word floor alone, with 1.6 other
production sites on average and none over the cap. These rules were set from probes of this tree (#338).
Within a literal, the search prefers an alignment that lists, tries the longest run of literal text first,
and remembers the states that failed, so a long pasted query against a literal of many interpolations stays
polynomial; the query is prepared once, not per literal. Listed sites appear in path order, under their own
heading, `literals with interpolations, matched around them`, with the literal as written and windowed on
the longest piece of literal text matched, the same production/test split and their own cap of 20, so the
answer says it matched through an interpolation and never spends the plain section's cap. The window is
found in the written text of the segment that piece came from, never elsewhere in the literal, so a word
that also appears in an interpolated expression's source (`catalog\(catalogs == 1 ? "" : "s")`) does not
move it: the whole piece first, then, since the literal is shown as written and an escape spells some
characters differently (`\"`, `\n`, `\u{2014}`), its runs free of quotes, backslashes, control characters
and any character the written segment lacks, longest first. When no run is found there the literal is
shown from its start, truncated at the display cap. **When the section would list nothing
it has no heading** (an empty heading is not an answer): the count alone is one line saying the matches
were around interpolations, `36 lines match it around interpolations on only one word of literal text,
…`, so an answer the plain section already gets right gains one line, not two; and `no Swift string
literal contains it either` still precedes it whenever no catalog entry, plain literal or listed match
answered. The plain section is unchanged by any of this.

### `run -- <command>`

Wraps a toolchain command and prints what failed instead of what happened — the other context sink, where
a verify loop emits hundreds to thousands of progress lines, every one of them paid for. CLI only: agents
reach it through a shell, where the command they already run gains a prefix. Nine things are
load-bearing. **The exit code passes through exactly**, a signalled child included, with two exceptions,
both for a run whose argv names its tests (`swift test --filter …`, `xcodebuild -only-testing:…`), and
exit 4 for one more: an unfiltered `swift test` of a package whose manifest declares test targets that exits 0
with every closing count at 0 (#458) answers `✘ … nothing ran: no test executed, though the package declares
N test targets`, is reconciled against the inventory, and is never recorded as proved.
Exit **4**: the run exits 0 and shows no test executed, so it answers `✘ … nothing ran: no test matched
<selector>`; both tools report that as a success, which a negative gate would read as "passes without the
fix". So does a run of several `--filter`s where one matched none of the tests the others ran: it answers
`✘ … no test matched --filter <pattern> — N of M filters`, its totals line the same, judged against every
test function id the run's Swift Testing event stream declared, its `/File.swift:line:column` included
(a pattern can match it), and each XCTest the console named as `Module.Class/method` — never a suite's id
or a class alone, which no pattern runs a test by. It is judged only where the run exited 0, showed a test
ran, was not `--parallel`, has that stream for any Swift Testing test it ran, and printed every XCTest
with its module (an `@objc`-renamed class prints without one, under a name SwiftPM does not match). Where a refused
`--filter` is a bare identifier the index declares as a type or top-level function, the answer adds one line under the
totals naming where it is declared and up to five suites that reach it, nearest first (`affected`'s walk, seeded
from the declaration), `--filter` spelled, with `+N more`; only a suite naming it is said to reference it, and the
rest are said to reach it through other code: a `--filter` names a suite, not the source type a change touched.
It is left out when the name is undeclared or nothing references it, when the checkout has no index (never built
for this), and when the lookup outlasts its 2 s budget; it reads the stored index as it stands (never freshened or written, so the note may be stale but is never slow); it never changes the refusal, its first line or the exit code. Exit **5**: the run's build failed before any test process started (nonzero exit, no test opened,
started or failed, a compiler error at a file and line, the linker's own, or a compiler crash), so it
answers `✘ … did not build — no test ran`; passed through it is `swift test`'s 1 or `xcodebuild`'s 65, the codes of a failed
test, and a gate would read a compile error as its proof. Neither is a code either tool uses (1; 65 and the
sysexits range), because a gate that expects its command to fail must not read "nothing ran" or "did not
build" as "the test failed". A run that names no test passes a build failure's exit code through. An
`-only-testing` identifier below a bundle that ends without `()` adds the hint that a Swift Testing
function is matched only with it. Such a run is never recorded as proved. "Shows" means positive evidence
of zero, under an action that executes tests; a log merely silent about its tests (`xcodebuild -quiet`, a
`--parallel` run's progress lines, a log cut short before any banner) or a `build-for-testing` keeps the
answer and exit it would otherwise have. **A selected run proves only what it shows**: one whose log
carries no test outcome and no closing count above 0 is never recorded as proved either, so a quiet
selected pass still exits 0 and a later gate runs it again rather than skip on it. **Recognition is by
argv, never by output**, since a filter chosen from the output would change its mind mid-build. **An
unrecognised command runs untouched** — fail open, always. **A failure the filter cannot explain serves
the raw log whole**, because a short "no errors" over a nonzero exit is the one answer this must never
give, and a summary line is a verdict rather than an explanation; a compiler crash *is* an explanation,
answered compactly (pass, function, `Error!` line) and never by the raw log. No line of any answer, the
raw log served whole included, runs past the line cap (`RunFailureCensus.listingBudget`, 8 KB): a longer
line is cut, and its marker names the log that keeps it whole. **Lossy with a receipt**: the raw output
streams to a per-run file under `.sift/runs/`, and the answer names it and states "N lines in, M out", M
measured on the rendered answer — one file per run, since parallel sessions are the norm, renamed at close
so pruning cannot unlink a log still being written. The newest five are kept; a selected run that did not
build is the exception, since its log is the only record of what failed, and it moves out of that count
into a pool of its own, also five, apart from the logs that explain a sharded run's lost results, before
the answer names it — either run of a `--without` proof included. **Every count is the tool's own**, summary lines
verbatim, and a run that printed none says so — with one derived number, the `totals:` sum below, stated
only where every addend is a line the tool printed. **Silence is never success**: one verdict per answer or
an explicit none, derived from the *action* in argv, so an action argv leaves in doubt yields none at all.
**Every line is read with its colour gone before anything else looks at it**: Swift 6.4's SwiftPM colours a
compiler diagnostic even where stdout is a pipe, so every ANSI CSI and OSC sequence is stripped before any
reader anchors on a line; the `.sift/runs/` log keeps the raw bytes. `xcodebuild` colours nothing piped, so
the child's environment is left alone.

**A linter is wrapped on the same terms, and which executables count is configuration.** A linter prints
one diagnostic per violation in the compiler's own `file:line:col: severity: message` shape and no closing
verdict line, so its verdict comes from the exit code alone and its violations group by rule through the
signature census a build's errors already use — the case the filter exists for is one rule firing four
hundred times. `swiftlint` is built in. Any other is named in `.sift.json` under `linters`, as executable
names only (`"linters": ["depot-lint"]`), because the tool that lints a repository is that repository's
business and no in-house name belongs in this binary. Recognition still reads argv alone: the names are
read once, at the launch, and a config that cannot be read adds no name rather than refusing the run. A
nonzero exit explained only by warning-severity violations is still a usable answer, since a strict linter
run fails the exit code over a warning without ever spelling it `error:`.

**A build's or test's warnings are listed in log order, capped at 20, and a warning that repeats one
signature is listed once with its count.** Under `warnings (N):` (N always every warning the log carried)
each signature prints its first occurrence in the compiler's own form, followed by `  ×K` where K > 1, the
multiplier the errors sample uses. The cap counts printed lines, and `+M more warnings — see the raw log`
counts the warnings those withheld lines stand for. Where nothing repeats, every line is one warning, so
the listing reads exactly as a flat one. The case is a release build passing `-ffile-prefix-map`: 73
unlocated `warning: <dir>/<Module>-<hash>.pcm: No such file or directory`, each one different text, that
say one thing. The signature is narrower than the census errors and failures use, deliberately:
- **A warning located at a line is grouped on its message verbatim.** Warnings at distinct `file:line`
  sites are separate things to fix, so no two whose text differs are ever merged. A run of
  `unused value 19`, `unused value 20` stays one line each, where `RunFailureSignature`, which elides
  digits and string literals, would fold them. The same text at several sites does fold, listed at its
  first site with the count: `×K` there says K sites, and the raw log names the rest.
- **An unlocated warning is grouped on its message with each absolute path elided whole.** The path is
  a token opening on `/` at the message's start or after whitespace, a quote, `(` or `[`, and running to
  the next whitespace, less trailing punctuation. With no line, the path inside the message is the only
  thing that differs between two reports of the same fault. The hash is in the path, so it goes with it,
  and so does the directory (the capture names two). A bare hash outside a path is left alone: no capture
  shows one, and a rule tuned on nothing would be guessing. Relative and `@rpath/` paths stay, so
  `linking with dylib '@rpath/XCTest…'` and a second `'@rpath/…'` dylib stay two lines.
- **Nothing else is elided.** Two messages differing in any word or number stay apart, and a located
  warning never groups with an unlocated one. An unlocated warning reported against a file (xcodebuild's
  `<path>/Widget.xcodeproj: warning: …`) groups only with another against that same file, since that path
  is all the listing prints of where it came from.

`RunErrorShape` and `RunFailureCensus` are not reused. Their census adds an `N warnings · M signatures · F files`
heading and a five-signature sample, and that would change the listing of warnings that never repeat.
The grouping (`RunWarningSignature`) only decides which lines print once.

**An `xcodebuild -quiet` run's silence can be read as a pass once the exit code is in hand — the one
exception to *silence is never success*, and bounded to it.** `-quiet` suppresses every action's
`** … SUCCEEDED **` stamp on a clean run. Where argv carries `-quiet` as a flag (read with the option table
the action is read with), the exit code is `0`, and nothing in the log reads as a failure, the silence is
read as success from the exit code alone, worded as that (`✔ xcodebuild — no verdict printed under -quiet;
read as passed from exit 0, with no errors or test failures logged`), never claiming the strength of a
line the tool did not print. **What it cannot see is said, not hidden**: a `-quiet` run cut short that
still exited 0 reads the same, is filed in `run.jsonl` with an empty failure list, and the line says the
pass rests on the exit code alone. **Without `-quiet` nothing is inferred**: `xcodebuild` prints its banner
whenever it finishes and `swift build` prints `Build complete!`, so a silent log from either is one that
stopped early, answered `⚠ … no verdict in the log` whatever the exit code — a truncated capture arrives
with exit 0. The reading never overrides a `FAILED` or `INTERRUPTED` banner the log carries, and never
reaches `swift test`: the run tally stays the one signal a `swift test` verdict is read from, and an exit
code never stands in for a tally the log never printed. **A selection with no `@Test` in it is heard from
on XCTest's count alone**: SwiftPM starts no Swift Testing process for a `--filter` matching only
`XCTestCase` tests, so where no Swift Testing process opened and every XCTest process that opened closed
on a count naming no failure, with no failing test or error in the log, the run passed on that printed
count. Bare driver-wrapper errors (`error: … command failed with exit code N but produced no further
output`, `error: Build failed`, `error: fatalError`, `SwiftCompile … failed with a nonzero exit code`) are
build-system noise and are dropped as errors. **Under `swift build` the first two are its closing line**
(#448): a failed build's log ends on `error: Build failed` (or `error: fatalError`, or both), read as the
build's own failed verdict and quoted as its summary, so the answer never says the log has no closing line
when it has one. A log that ends on neither keeps that note. Under `swift test` the closing line stays the
run tally, and an unread contract takes neither literal as a verdict.

**A test process that dies is a crash, never a pass** (#447). Under `swift test`, SwiftPM's `error: Process '…' exited
with unexpected signal code N` is claimed out of the errors and read with the runtime's `File.swift:N: Fatal error: …`
(or `Precondition failed`, `Assertion failed`) line as `RunTestCrash`: the verdict is failed, the headline says
`test process crashed`, the totals word is `crashed`, the answer quotes the trap, names the tests started and never
ended, and counts the selected tests that never started (XCTest's echoed `-XCTest` list, Swift Testing's event-stream
declarations). Trap text with no signal line is no crash, and neither is a signal line in a run that exited 0 (a
process that died fails `swift test`, so there it is a test's printed text). Such a run names no failure list for
`flakes` (`nil`). A trap printed straight after a Swift Testing issue's `↳` lines ends that note and is read as the
trap. **`crashed` joins the totals vocabulary**: a consumer matching `totals: ✘ failed` must match `totals: ✘
crashed` too, or anchor on `^totals: ✘`. The `inventory:` line of a crashed run never takes its clean form: it carries
`test process crashed`, how many tests started and never ended, and how many selected tests never started (or that
the log does not say), because the tests a dead process never reached report nothing and the counts can agree over
them.

**A test process that ends with no signal line is still read** (#467). SwiftPM prints no signal line for a process
that calls `exit(N)` or takes a `SIGKILL`. Where `swift test` exited 1 to 127, a test process opened and never closed
(a Swift Testing run with no summary, or an XCTest process that never ended its outermost suite) and a test in it
started and never finished, the crash carries `unsignalledExit` and the answer reads `test process ended without a
result (exit N / no signal line); started and never finished: …` under the same headline, totals word and failed
verdict. It quotes no trap line, since a trap ends its process on a signal SwiftPM reports, and counts no selected
tests that never started. An exit of 128 or more is `swift test` itself taking a signal, and is not read this way.
A trap belongs to the crash only where it follows a crashed test's start inside the same process's output (the
processes counted by their `Test Suite 'All tests'`/`'Selected tests' started` and `Test run started.` lines); trap
text from outside that span is dropped. The start line and the runtime's trap message share the test process's
standard error, relayed in write order, so the real trap is never dropped. Inside the span every trap is kept, each
process's last listed first, and that order is **unranked** in every run mode: a test running beside the crashed one
can `print` the same text to standard output, which reaches the log out of step with the standard error the console
and the trap share, so it lands before or after the trap and even after its own test's ending line; and the event stream records no printed text, so no test id
says whose line it is (#523, measured on a probe package: of 60 runs the look-alike landed after the real trap in 34
and after its own test ended in 2).
Traps are ranked on one piece of evidence, the event stream's. The stream records no printed text and nothing at the crash (no
issue, no ending: the crashed test's last record is its `testStarted`), but it records where each test is declared
(`sourceLocation`: `fileID`, `filePath`, line) and which tests started and never ended. A trap whose `File.swift:N`
names, in either spelling, a line from such a test's declaration up to the next test or suite the stream declares in
that file is listed first; several such keep the unranked order among themselves. The stretch is an upper bound, since the stream records no end: a helper written below a
test falls in that test's. Every other trap inside the span follows, unranked as above, which covers the usual
crash, a trap raised in library code or the standard library, whose location names no test's source, and every run
with no stream (XCTest). (#523, on a probe package whose crashed test calls `fatalError` in its own body while three
tests print look-alikes beside it: the real trap led in 7 of 16 runs before and 8 of 8 after; with the trap raised in
library code instead, 6 of 16 before and 2 of 8 after, unranked as before.)
Where no crashed test's start is in the log, every trap is kept in log order.
A Swift Testing process's never-started count is its own bundle's: SwiftPM writes every bundle's stream into the one
file, so the declarations counted are those whose target is the bundle the signal line's `--test-bundle-path` names,
and none is counted where no declared target matches it. **Known limit:** an unfiltered XCTest run echoes no `-XCTest
a,b,c` list on its signal line, so the log does not say what that process was handed and its line carries no
never-started count; nothing is guessed in its place.

**A package is judged by all its bundles, not by whichever one the log happens to close on.** `swift
test` runs one process per test bundle, each closing with its own Swift Testing tally. A package whose
bundles all report `passed` is a success; one where any bundle reports `failed` is a failure, and the
verdict names that bundle's own closing sentence rather than a count no tool printed.

**A `swift test` answer closes its content on one line a gate can name — last of the answer's own lines,
above the receipt that closes every answer.** Every line before it varies in count and shape, so nothing
above it is a token a gate can grep for and always find. `totals:` is that token: lowercase, stable across
every shape below, and never a prefix a per-bundle line prints. **Anchored — `grep '^totals:'`, never a
bare `grep totals:`**: a listed failure's own message can quote the token (a real run in the
`RunOutput` fixtures does), and an unanchored gate reads the quotation as the verdict. The line is present
for every run under `Contract.runTally`, one whose tests never started included — a gate cannot tell a
missing line from a binary older than the line. When nothing is left to display it says `nothing to
display`, and the reason after `since` is read off the run, because different facts reach it. Where no
test process announced itself, the evidence picks the words (#382): `since no test process started` only
over a build that failed first (a compiler or linker error, a nonzero exit and no test line; nothing opened
to go missing), `since no test ran` for a selector that matched nothing (exit `4`: SwiftPM may have
launched the test binary to find nothing to run, so "started" is not the log's to deny), and otherwise
`since no test process announced that it started`, which is all the log shows. Where processes opened: `since a process died
before printing anything worth showing` (opened, never closed), `since every closing count printed was
vestigial` (openings match closings). Only the process-died shape can appear beside the reachability clause,
which prints solely where a closing is owed and missing. A `swift build` or `xcodebuild` answer carries no
`totals:` line at all.

**Its word is the verdict's, and both frameworks are counted under their own names.** The word after the
glyph is the run verdict's — never a tally's own `passed`, which speaks only for Swift Testing's half of
one process: a package whose `XCTestCase` failed while its `@Test` passed closes on `Test run with 1 test
in 1 suite passed`, and a word taken from that tally reads green on a red run, the one answer this command
must never give. The word is stated once, at the front, and no clause after it carries `passed` or `failed`
of its own (an anomaly says `reports a pass`). Both closing counts are read — Swift Testing's `Test run
with N tests in M suites` and XCTest's `Executed N tests, with M failures`, one of each per test *product*
— because reading the first alone omits every `XCTestCase` the run executed: `totals: ✘ failed · XCTest 1
test, 1 failure · Swift Testing 1 test in 1 suite`. Each is labelled with the framework that printed it,
because the denominators differ (XCTest states no suite count). Under `--parallel` neither counter is
complete — see below.

**Counts are summed within a framework, named for the bundles they are over, and never across the two.**
Two lines of the same shape are two processes, hence two bundles; the bundles are disjoint (measured on
this repository, the two tallies add to exactly what `swift test --list-tests` enumerates), so the sum is
the run's real total, stated as one: `totals: ✔ passed · Swift Testing 2698 tests in 228 suites across 2
bundles`. It is the one number no tool printed, allowed because every addend is a line the tool printed.
**A skipped test is named on it, never read as one that ran** (#468): each framework's count includes its
skips, so XCTest's carries its counter's `with N tests skipped` as `, N skipped`, and Swift Testing's carries
how many tests the run's own lines last reported skipped (a `.disabled` test, a cancelled one), `Swift Testing
2 tests in 1 suite, 1 skipped`, in every mode and with no index involved. The skip is named, not failed: the
word, the exit code and the proof are untouched, so a filter that selected only a skipped test still reads
`✔ passed`, with its one test named skipped.
**Under a plain `✔ passed` or `✘ failed` with every count summed, the lines it was summed from are
dropped**, since the raw log the receipt names keeps them; wherever anything is off (an anomaly, a count
left unsummed, a verdict that is not the invoked command's, `--parallel`) they are all printed, as the
evidence the reader checks the answer against. A line that will not parse stops the sum rather than being
dropped from it — a total missing an addend nobody can see is worse than no total — and the answer states
each count in order, with how many there were: `Swift Testing 2 tallies, not summed — 29 tests in 4
suites; tally 2 unreadable`. The *verdict* is never a sum: the bundles' own words reconcile into one pass
or fail, because `passed` is a judgement rather than a count to add.

**A process that opened and printed no closing count is named — and `swift test` runs two processes per
test product, not one.** The XCTest harness opens on `Test Suite 'All tests' started at`; the separate
`swiftpm-testing-helper`, which carries every `@Test`, opens on `Test run started.` (a crash probe killing
one leaves the other completing). So processes owed a closing count are the sum of both openings, and
processes heard from are the sum of both closings — never the greater of the two, which let a bundle that
opened, crashed and printed nothing pass silently. A bundle that crashed, hit a `fatalError` or timed out
leaves its opening and no count, and the answer says so: `totals: ⚠ exit code disagrees — 1 of 2 test
processes printed a closing count; every count this answer read reports a pass but the command exited 1`.
Where every count reads as a pass over a nonzero exit and nothing is missing, that second clause stands
alone; where a count is missing over exit 0, the word is `incomplete`.

**A bundle that never launched is named from the package, because no log can state it.** A test target
that failed to compile announces nothing, so every clause above is satisfied while every line that printed
still says `passed`. The expected count comes from the package's own manifest: `swift test` builds one
test bundle per `.testTarget`, so a run that reported fewer counts than the manifest declares says which —
`totals: ⚠ incomplete — 1 of 2 test bundles the package declares printed a count; …` — and the clause names
*the package* as that denominator's source. The log cannot supply it: a run where nothing needed rebuilding
prints no progress lines (five of eight recorded runs of this repository have none). **Where the manifest
cannot answer the clause is simply absent**: any command but `swift test`, a `--package-path` pointed at
another package, no readable `Package.swift`, or test targets computed rather than written as literals (the
manifest reader is deliberately syntactic, so a computed name reads as *nobody said*, never as a count of
none).

**`swift test --parallel` says so rather than reading a Swift Testing tally of zero as the whole run.**
Under the flag SwiftPM prints no XCTest opening or closing count for the tests it runs in parallel — only
`[k/N] Testing <name>` progress lines — and reruns any failing test alone. The verdict stays right but the
count would be wrong, so the line names the limitation from the invocation itself: `totals: ⚠ … — run with
--parallel, whose own per-test progress lines are not counted here · Swift Testing 0 tests in 0 suites`.

**A plain `swift test` is also set against the tests the index declares, in one line under `totals:`.**
None of the clauses above can see a test that never reported inside a process that did close. So an
unfiltered, serial `swift test` of the package at the repository's root has its own parsed outcomes
reconciled against the inventory (the join `test --analyse --against` makes), and the answer carries
`inventory: 3411 declared, 3411 reported` when the two agree, or `inventory: 3 declared to run, 2 reported
— 1 never reported: …` naming up to five tests that never reported and any that reported more than once.
**It is a note and never a verdict: the exit code stays the wrapped command's either way** (a run that
executed no test exits 4 for its zero, not for this line). That run, its every closing count at 0, is
reconciled as zero reported, `inventory: 3 declared, 0 reported — 3 never reported: …`, rather than refused
as a log carrying no test line; only `--against` handed a file with no test line refuses it. A run of any
other set prints nothing (filtered, skipped, `--parallel`, a nested package, `xcodebuild`). A run in scope
that could not be checked prints `inventory: not checked — …` with the reason: no index (a run never builds
one), an unreadable inventory, every declared test lifted out of the counts, or more than 20 s to bring the
index up to date and reconcile. That budget is a guard, not the expected cost.

**A `swift test` is read with its event stream beside its console.** SwiftPM relays
`swiftpm-testing-helper`'s output, and under load whole `✔ Test … passed` and `✘ Test …` lines go missing
on the way; the event stream is written by the testing library itself and keeps every ending. So `sift run`
asks a `swift test` that executes tests for it (the option that command's own `--help-hidden` names, asked in
the run's directory with its environment rather than of `PATH`'s `swift`; a file under `.sift/run-events/`
removed once read, and by a later run a day on where a killed run left it) and, where the stream recorded more Swift Testing endings than the
console relayed, records the missing endings from it and names each failing test the console relayed no
line of; one line under `totals:` gives both counts. The console is still what every message is read from,
and the verdict and exit code are untouched. Where the two agree the answer carries nothing about the
stream, and nor does it for a repeated run (`--maximum-repetitions`, `--repeat-until`), whose console prints
one ending per test however many iterations the stream ended it in. Nothing is asked for where the stream cannot be had: `swift test list`, a caller who named a stream
of their own, a toolchain that offers no option; and an XCTest-only run's stream declares no test, so its
answer is the console's alone.

**A test whose own result line was lost is not called unreported.** One green run of this repository's
suite printed a `started.` line and no result line for 90 tests, while each of their suites printed its
pass line and both closing summaries passed; the lines never reached the pipe. A test is judged inside the
Swift Testing run its start line sits in (one per test target, from its `Test run started.` to its
summary), and counts apart from a missing one only when all hold: it printed a start line and no ending;
that run printed the suite's pass line (matched by the innermost suite name, which is all Swift Testing
prints for a nested suite); that run's summary passed; and no other line names it that is neither its
start nor an ending the reader knows (a cancelled test counts as skipped, a recorded known issue is no such
line). A run that printed no summary crashed and vouches for nothing, and neither does one with more
distinct first-iteration start lines than the `N tests` its summary counts, or a summary with no count. A
wrapped command that exited non-zero leaves no test lost. The note reads `— 90 result lines lost, the tests
passing by their suite and run summaries: …`; a group reconciled by count alone is judged the same way and
reads `N of these M lost their result lines, by count alone`. Such a test is neither reported nor missing
and does not make a reconciliation red: the green headline counts it beside the tests that passed, never
among them (`3 tests passed and 1 more by their suite and run summaries`). Anything else stays never
reported: no start line, a suite that failed or never finished, a run whose summary failed or was never
printed, a test logged under a display name.

**Failures are served as a shape when a shape is honest, and as a listing otherwise** — a shape when they
are chiefly repetition and only while the sample can illustrate every kind, otherwise a listing, while it
fits one byte budget threaded across both sections and charged against the log, so the wrapper never prints
more lines than it stood in for. Each example carries the declaration its location resolves to, parsed
fresh from disk, and marked `(syntactic)` on every line it qualifies — containment, never a claim about
what the failing line *called*. The exception is a failure inside the very test named beside it: that
heading carries the resolved path and the body's range, `name() — Tests/…/File.swift:10 (body :8-12)`, with
no `in …` line and no tag. A lone failure is listed with no `N failures · N signatures` line above it.

**Where that section leaves a failing test unnamed, one more block lists them all.** A sample names the lead
of each signature it illustrates and a few others beneath it, so the tests it counts but never names are the
ones a fix round needs by name and file. When the section leaves any failing test unnamed, or names one
without its file (a failure the framework gave no location), it ends on `failing tests by file:` and one
line per file, `File.swift (n): name, name, …`: files by failing-test count descending then name, each file's
tests in the order they first failed, and the tests with no location under `(no location)` last. A test is
written as the runner names it (a Swift Testing function as printed, an XCTest method as `Class.method`) and
counted once per file it failed in; Swift Testing prints no suite name, so two suites in one file that each
have a failing test of one name are one entry. A test that crashed recorded no failure, so it is not in the
block: the crash line names the tests that were running. The block holds 60 names in all; the rest are one line,
`+N more failing tests in M files`, where M counts the files that have a test left out. It is built from the
failures the filter recorded, never from a text search of the log, so a test name quoted inside an
expectation's argument is never read as a test. Where every failing test is already named with its file, as
in a full listing, there is no block, and it is also left out where the log has too few lines to leave room
for it, since the answer may not run longer than the log it stands for. CLI output only: no hook answer,
MCP tool or `tools/list` entry changes.

**A run that failed for one reason leads with that reason, and states it as a consistency rather than
as a cause.** Where more than half a run's failures read one and the same expanded value (an empty string,
an empty array, the same timeout sentence) the answer names that value and its count above the signatures,
which a census of signatures structurally cannot see, since a signature elides every literal. If five
further markers all hold — the value empty, read as the *subject* of most failures sharing it, by an
expression naming an accessibility read, on a simulator this run's own restore found the preference
switched off on, spread over more files than the block illustrates, and landing in nothing the working tree
has changed — the line adds that the empty reads are **consistent with** that preference having been off,
and says the preference was read only *after* the tests finished, so a session teardown switching it off at
the end reads identically. It may not say the flag is why, and may not deny the code: nearly every wrapped
simulator run ends with that teardown, and a genuine regression on a clean tree satisfies every marker.
What follows is only what the reader has left to do. **A device this run never reached gets no clause**:
only the two states that actually *read* the preference off (restored, failed to restore) admit it, since
a claim over a reading never taken is unsupportable; covering that run would need a *pre-run* read.

**A wrapped simulator test run leaves the device fit for the next suite.** When a UI-test session ends,
the test manager's teardown stores `AccessibilityEnabled` and `ApplicationAccessibilityEnabled` in
`com.apple.Accessibility` as off on that device, within milliseconds of `xcodebuild` returning, and a
hosted view consults the first before it builds accessibility elements at all. So the next package run on
that simulator fails every test that reads one, looking exactly like a code defect: measured in a
consuming project, 466 failures in 3068 tests straight after the UI suite, and 3068 passing once the
preference was re-armed. After every wrapped `xcodebuild` whose action is `test` or `test-without-building`
(read with the verdict's option table) and whose `-destination` names a simulator, `sift run` switches the
preference back on, **whatever the exit code**. **The devices are the ones argv names, every one, in
order**: `id=<udid>` outright, or a `name=` (narrowed by `OS=`) resolved through `xcrun simctl list
devices available -j`, preferring a booted device; several or none is not an answer, and the answer says
the device could not be determined rather than writing into a device this run never used. A macOS or
physical-device destination does nothing and prints nothing; a bare `id=` with no `platform=` counts as a
simulator only where the identifier is UUID-shaped (`8-4-4-4-12` hex), which no device udid is.

**No `-destination` at all is not the same as no simulator.** Xcode resolves a default destination whose
session tears down as a named one does, so a command line naming none is read from the run's own
transcript: `export PLATFORM_NAME\=<platform>` in the verbose build settings, `iphonesimulator` and its
siblings for a simulator. Argv settles the question wherever it carries a `-destination`; the log is read
only where argv names none, and only for whether the platform was a simulator — a match answers `.unnamed`.
Nothing naming a simulator platform means no write and nothing printed, unless the failures already read
as empty accessibility trees.

**Read and written through the runtime's own `defaults`, never `/usr/bin/defaults`**: `simctl spawn` runs
an absolute path from the host, so the absolute spelling is the host's tool looking for a domain the
simulator keeps in its own preference daemon — it writes nowhere the simulator reads, and says nothing
about having failed. **A write is only made over a preference seen off**, which bounds the cost: a key
reading `0` is written back on, confirmed 2.5 s later, and rewritten for up to 10 s if a late teardown
undoes it; a key reading `1` is polled for at most two seconds and left alone, so an ordinary simulator
package run pays those two seconds and no write. That case prints **nothing** unless the failures have the
shape of an empty accessibility tree: it is the reading of nearly every simulator run, and a line printed
on all of them was one every reader filtered out. Where they do, the line says only what was seen and
carries the manual command, never a claim that the device is fit, since a teardown landing after the poll
is one this did not see. **A read that fails is answered as whichever of three it is**, from the tools'
standard error: a domain missing (no session has ever run on the device, the commonest failing run) says
nothing and qualifies nothing; a device `simctl` cannot reach says so in one line and qualifies nothing;
anything else is the unknown it has always been. **Every spawn is bounded at five seconds of wall clock**
and then ended (`SIGTERM`, `SIGKILL` a quarter-second later), reported as a failed read or write; without
the bound a wedged `CoreSimulator` blocks `sift run` forever *after* the wrapped command has exited. The
bound is on the wait, not on what a spawn started, which belongs to CoreSimulator and is out of reach of
any signal sent from here. The worst case is **about 35 seconds for a device whose every spawn wedges**,
and that again per further device. One short line per device that owes one says which happened —
`accessibility: read off on <udid> after the run; sift switched it back on` for the ordinary restore, with
no command — and, where a write may be owed, the two `defaults write`s joined by `&&`, printed once. The
lines sit under the receipt, except where the failures read empty trees: there they lead the failure
block. A device left off or unconfirmed also qualifies the verdict line, the worst where there are several.
The two launches of `run --without` are not covered: they have a launch path and an answer of their own.

#### Live progress: `.sift/progress/`

A wrapped run's answer arrives when the run ends; a person watching a ten-minute `xcodebuild test` wants to
see it move. **`sift run` keeps a small JSON file of its own current while it runs**, for a pane, a script or an
editor plug-in to poll. The format is a contract of its own, in [ProgressContract.md](ProgressContract.md):
a JSON Schema (draft 2020-12), an example, and what a consumer may rely on. Only the Stop gate reads the file
back (below), it changes no answer, and `run` stays CLI only: there is no MCP build or test tool, and this adds none. A
consumer recognises a run by a Bash command starting `sift run` (the PreToolUse hook rewrites a bare
`swift test` or `xcodebuild` into that form) and finds the files beside the run logs.

- **One file per run.** `<repo>/.sift/progress/run-<runId>.json`, in the repository's cache directory
  beside `.sift/runs/`, so already ignored by git. Parallel runs in one checkout (agents sharing a
  worktree) never touch each other's file; a consumer lists the directory and picks by `repoRoot`, `pid`
  liveness and `updatedAt`. `runId` is time-sortable (the start, UTC to the millisecond, then eight random
  hex digits), so a name sort is a start-time sort. The directory is `RunProgressPaths` over the same seam
  the run log takes: a run whose writes are scoped (`writesUnder`, as a test or a probe sets it) writes
  under that directory instead. `repoRoot` is the repository root with symlinks resolved, so two spellings
  of one checkout compare equal. `logPath` is absolute, because the log can fall back to the temporary
  directory outside the repository; it names the `….log.part` file while the run is going and the
  published `….log` once it is over, where the answer's `raw:` line names it.
- **Whole or not at all.** Every write is a temporary file in the same directory renamed into place
  (`DurableFile`, without `fsync`: the file is a view of a live process, and a crash makes it stale either
  way). The temporary is a dot-file ending `.tmp` (`.run-<runId>.json.<pid>.tmp`), so a lister matching
  `run-*.json` never sees it. A reader sees the previous snapshot or the next, never part of one.
- **Cadence.** At most one write per 500 ms, through `RunProgressWriter`'s throttle; a phase change, the
  start and the finish always write at once. A change held back by the throttle is flushed by the writer's
  own timer once the window passes, so the final counts are never lost to it, and the same timer rewrites
  an unchanged live snapshot every 2 s so that `updatedAt` stays fresh through a silent link step or a
  quiet test. The timer is the writer's, not the caller's: the reader of a child's output can sit blocked
  in a read for minutes.
- **Phases.** `idle` from the start until a build or test line is recognised (and for the whole of a
  command that does neither, a linter), `building`, `testing` (once: a compile after the first test line is not
  tracked as building again), then exactly one of `done` (sift's own verdict passed: it exits 0) or `failed`
  (anything else: a nonzero exit, a compile failure, a cancel, a run abandoned without one). `phaseStartedAt`
  is when the current phase began, so a display's "Testing 02:28" is that phase's elapsed time. `summary` is
  null until the run ends; then it carries the time spent in each phase and the whole run's, which the writer
  measures itself from its phase changes.
- **Ending.** `finish` writes the terminal phase with `exitCode`, which is **sift's own exit code**, not the
  wrapped command's: a selected run that executed no test ends `failed` with 4, one that did not build `failed`
  with 5. So `RunCommand`, the one layer that knows that code, ends the run, once the code is settled and the
  log has moved to where the answer names it (a run that did not build moves its log into a pool of its own),
  so `logPath` names a file that exists; the launcher only reads the output's last line. The first call wins, so a signal
  path racing the ordinary path cannot overwrite the outcome either recorded. A cancelled run
  (`SIGINT`, `SIGTERM`, `SIGHUP`) calls it from its signal source's handler, which runs on a dispatch
  queue; the writer takes a lock and is safe there or on any thread, but it is not async-signal-safe and is
  never called from a raw `sigaction` handler. `reset()` is the cleanup that needs no answer to hand: after
  `finish` it does nothing; for a run still in flight it writes `failed` with a null `exitCode`; it is
  idempotent.
- **The tree.** `tree` is the `TreeKey` value `RunCommand` already takes before the command starts (the key the
  run is recorded under when it ends), written into the file from the first snapshot, so a reader can tell a run
  of the content it is judging from a run of content since edited. It is null for a command that neither builds
  nor tests, for a plain build with the ledger off, where the key could not be taken, and for a run that builds
  another repository than the one the file sits in (`--package-path ../C`): that tree is not this checkout's.
  `tree` was the one key added to version 1 before the public release, when no released reader existed; the
  decoder reads a file without it as null, so a file an older sift wrote still decodes and the prune never
  takes it for unreadable. From the public release on, adding a key bumps `schemaVersion`
  (`Docs/ProgressContract.md` §2).
- **Crashes.** A `SIGKILL` cannot clear the file, so a live phase can outlive its process. **A consumer
  reads a live phase (`idle`, `building` or `testing`: a run can die before its first build line) with an
  `updatedAt` more than 5 s old as stale** (the heartbeat makes 5 s safe), and may also check `pid`.
- **Kept, then pruned.** An ended run's file stays, so a consumer can read the final summary after the
  process has gone. `begin` prunes the directory to the newest five run files
  (`RunProgressWriter.prune(in:keeping:)`), oldest first by name, and never removes a file whose `pid` is
  alive and whose `updatedAt` is under 10 s old: a slow run started long ago is still somebody's live run.

#### Live progress: the planned count and the closing reconcile

`tests.planned` is the denominator a display shows a run against ("212 of 3411"). **A wrong one is worse
than none**: a bar that passes 100%, or stops short of it on a green run, teaches the reader to ignore it. So
`planned` is filled only where the run's selection is known exactly before its tests start, and is `null`
everywhere else. Filling a key that no writer has ever set is not a change of meaning, so `schemaVersion`
stays 1.

**The unit is the live counts' own.** `passed`, `failed` and `skipped` count one ending per test function or
`XCTestCase` method, by how it last ended, so `planned` counts the same thing. Measured on a probe package
mixing both frameworks (Swift 6.4, Xcode 27): `swift test list`, the run's closing counts, the enumeration
below and the `.xcresult`'s top-level counts all gave 13, where two parameterised functions ran 7 cases
between them and an inherited `XCTestCase` method ran once per subclass. A `.disabled` test,
`.enabled(if: false)` and `XCTSkip` each end as skipped, so each is in `planned`. A test the run never
starts (`-skip-testing`, a plan's own exclusions) prints nothing and is not.

**Where it comes from, per command kind:**

| Run | `planned` | From |
|---|---|---|
| `swift test`, unfiltered, serial, root package, nothing declared outside the run's scope | the inventory's declared count, where it is certain | the sift index, off the run's thread |
| `swift test --filter`/`--skip`/`--parallel`, `-l`/`--list-tests` (executes nothing), another package | `null` | — |
| `xcodebuild test-without-building -xctestrun F`, one Mac destination | the enumeration's enabled tests | `-enumerate-tests` beside the run |
| `xcodebuild test` (builds first), a simulator or device, several destinations | `null` | — |
| any repetition flag (`-test-iterations`, `--maximum-repetitions`, `--repeat-until`), a plan with more than one configuration | `null` | — |

- **`swift test`: the inventory, on the runs `inventory:` already bounds.** The scope is
  `RunInventoryCheck.applies`'s, read from argv alone before the run starts (that check runs over a parsed
  report; this needs an argv-only form). The count is the reconciliation population's expected set — the
  number the `inventory: N declared` line prints for the same run — taken only when the population is
  certain, and **nothing is declared outside the run's scope**: an out-of-scope declaration (the
  inventory's `N outside this run's scope`) or an `XCTest ending no declared test claims` anywhere in the
  root package's own targets makes it unsure, because the live counts will include it and the denominator
  will not. Measured on a probe where a non-test target declared an `XCTestCase` with a test method:
  `inventory: 13 declared, 13 reported (… 1 outside this run's scope · 1 more XCTest ending no declared
  test claims)`, live total 14. That is decided **before the run starts** from the declared inventory
  (an out-of-scope count above 0 gives `null`); the ending-no-declaration case can only be seen after the
  run and is handled by the closing rule below. The population is also certain only with: no conditional member (a test under an `#if` the host cannot decide), no compiled-out one, none
  excluded, no `.testTarget` inside an `#if`, no guessed module, and an index that exists (a run never
  builds one). The work is the inventory check's own freshen-and-read, on a detached task started at
  `begin` under the same 20 s guard; `planned` is written when it lands, and nothing waits for it. The
  probe's inherited method was in the 13.
- **Filtered `swift test` is `null`, by measurement.** `swift test list` ignores `--filter` (the probe's
  filtered list printed all 13 tests), and it takes the `.build` lock the running command holds. The event
  stream does honour `--filter` and `--skip`, but it declares one bundle's Swift Testing tests as that
  bundle's process starts, so the whole count is known only once the last bundle has started, and it
  declares no `XCTestCase` at all. Matching the patterns against the index would re-implement two
  tools' regex semantics over a spelling that carries the declaration's `/File.swift:line:column`. None of
  those is exact before the tests start.
- **`xcodebuild`: the enumeration, where it cannot touch the run's device.** `-enumerate-tests` against the
  run's own `.xctestrun` honours `-only-testing:`, and moves a `-skip-testing:` test into `disabledTests`,
  so `planned` is the count of `enabledTests` in its single `values` entry. Unlike the sharded run's
  enumeration (`TestInvocation.enumerationArguments`, which passes only `-only-testing:` and
  `-skip-testing:` through because it asks what the project contains), this one carries the run's whole
  selection: `-only-testing:`, `-skip-testing:`, `-testPlan`, `-only-test-configuration`,
  `-skip-test-configuration`, since it asks what *this* run will run. It took
  0.9 to 2.2 s on the probe and ran beside a live macOS test run with both counts unchanged. **On a
  simulator it is `null`**: against a generic destination the enumeration refuses (`Tests must be run on a
  concrete device`), and against the run's concrete device it is a second test session on that device in
  the middle of the run's own, whose teardown is the kind that switches accessibility off (*A wrapped
  simulator test run leaves the device fit*). An `xcodebuild test` has no `.xctestrun` until its build ends
  and finding one costs a `-showBuildSettings`, so it is `null` too. A document with an error, more than
  one `values` entry, or an `.xctestrun` with more than one `TestConfigurations` entry is `null`: the
  enumeration does not see the configurations (a probe's two-configuration plan gave one `values` entry of
  15 enabled tests, live counts reached 30 and the `.xcresult` had 2 `devicesAndConfigurations`), so the
  configuration count is read from the `.xctestrun` itself before the enumeration is trusted. The effect of
  a Mac enumeration on an app-hosted test bundle running alongside is **unmeasured**; the probe's was a
  package-style bundle. xcodebuild's
  `-resultStreamPath` was measured as a source and declares nothing ahead: its counts arrive with
  `actionFinished`.
- **Set at most once while live.** `planned` goes from `null` to a number once and does not move while the
  run is live; it **never becomes non-null mid-run** and is never filled at the end from what ran, which
  would turn a shortfall into a match. It only goes back to `null`, at the end, by the rules below.

**At the end, the run's own record replaces the live counts.** A live count is read off console lines, and
lines are lost (SwiftPM's relay drops whole result lines under load) or garbled (xcodebuild interleaves
other output into a Swift Testing line). The terminal snapshot — written once, by `RunCommand`, after the
exit code is settled — takes `passed`, `failed` and `skipped` from the best record the run left:

- **`xcodebuild` test actions: the `.xcresult`.** The bundle is argv's `-resultBundlePath` (the one
  `run --coverage` adds included, read before it is removed), or the path xcodebuild prints under
  `Test session results, code coverage, and logs:` in this run's log; with neither, nothing is read.
  `xcrun xcresulttool get test-results summary --compact` gives the counts: 0.09 s on the probe and 0.24 s
  on a 3072-test bundle, bounded at 5 s of wall clock and then ended, which keeps the live counts. **Only
  the top-level counts**, which are per function; each `devicesAndConfigurations` entry counts
  parameterised cases (the probe's 10 passed read 15 there), and a summary with more than one such entry
  is not read. `passedTests + expectedFailures` is `passed`, since a known issue is a pass in the live
  count (`totalTestCount` was exactly the four fields' sum on the 3072-test bundle). A cancelled run, or a
  summary that will not parse, keeps the live counts.
- **`swift test`: the outcomes the answer reads**, the console's endings with the event stream's recorded
  beside them, each test once by its last ending. A test with no ending in either is not counted; it shows
  as `planned` minus the finished counts.

**When the record and the plan disagree.** The plan is what was declared and is never corrected from
what ran. A record **below** `planned` keeps it, since the gap is the news: tests that never reported. A
record that shows the plan was **wrong** — `passed + failed + skipped` above `planned` (for
xcodebuild and `swift test` alike, so a multi-configuration plan the argv checks missed still ends
`null`), `totalTestCount` above `planned`, or a reported `swift test` outcome the population does not claim
(the reconciliation's unclaimed or out-of-scope endings) — writes `planned` as `null` in the terminal
snapshot. That is the one way `planned` leaves a number, and only at
the end. The progress file still changes no answer: none of this reaches the printed answer, the exit
code or `run.jsonl`.

**Build plan.** One builder per item, in order; each gate is a narrow run in the item's own worktree,
`sift run -- swift test --filter '<the item's suites>|CommentHistoryTests|ExampleNamesTests'`, and each
fixture uses permit-list names.

1. **The writer and the contract.** (a) `RunProgressWriter` takes `planned` once while live (a second value
   is ignored) and a terminal `tests` replacement plus retraction through `finish`; (b) `RunProgress`
   exposes both; (c) `RunProgressContractTests` pins set-once, never-filled-at-the-end and
   null-only-retraction. Gate: `RunProgressWriterTests|RunProgressContractTests`.
2. **`swift test` planned from the inventory.** **First deliverable, a gate of its own:** measure whether an
   out-of-scope declaration or an ending no declared test claims nulls `planned` on this repository's own
   `swift test` runs (unmeasured; report the inventory line), since that decides how often the number
   appears. (a) An argv-only form of `RunInventoryCheck.applies`, which also excludes list mode
   (`-l`/`--list-tests`, not in `narrowingOptions`), `--maximum-repetitions` and `--repeat-until`;
   (b) a certain-population count from `RunReconciler`'s population (no conditional, compiled-out or excluded
   member, no out-of-scope declaration, no conditional target, no guessed module), `nil` otherwise; (c) a detached task at `begin`,
   under `freshenBudget`, writing it. Tests: the count equals the `inventory: N declared` line's on the same
   fixture run; each unsure shape gives `nil`; a filtered, list-mode or repeated argv gives `nil`;
   a fixture with an out-of-scope declaration gives `nil`. Gate: the new suite plus
   `RunInventoryNoteTests`, and the median of 5 release-build `sift run -- swift test` runs of the same
   suite with and without the change, differing by under 3% or 0.3 s, whichever is larger (measured
   before and after, not guessed).
3. **The `.xcresult` reader.** (a) A summary reader over `xcresulttool get test-results summary`
   (top-level counts, one configuration, `expectedFailures` as passed, 5 s bound); (b) the bundle path from
   argv or the log's `Test session results` line; (c) `RunCommand`'s terminal write uses it for xcodebuild
   test actions. Tests over recorded summary JSON (one configuration, several, unparseable) and over log
   lines, including a fixture whose top-level and per-configuration counts differ (the probe's 8 passed
   against 10), so a reader at the wrong level fails. Gate: the new suites plus `RunProgressWiringTests`.
4. **`swift test` terminal counts and retraction.** (Item 4(c) depends on item 5, which supplies the
   xcodebuild `planned`; do 5 first or leave 4(c) until it lands.) (a) The terminal counts from the answer's merged
   outcomes; (b) `planned` retracted on an unclaimed or out-of-scope ending; (c) the general retraction on
   `passed + failed + skipped` above `planned` (and xcodebuild's on `totalTestCount`). Tests: a fixture log missing result lines that the event stream has,
   a fixture with an ending outside the plan. Gate: the new suites plus `RunReconciliationTests`.
5. **The Mac `test-without-building` enumeration.** (a) Recognition: `test-without-building`,
   `-xctestrun`, exactly one `platform=macOS` destination, no repetition flag, and exactly one `TestConfigurations` entry in the `.xctestrun` (else `nil`); (b) the enumeration with the
   run's selection flags, started beside the run, ended by its pid at `finish`, read through
   `TestEnumeration.read`; (c) tests over argv shapes (simulator, two destinations, `-test-iterations`,
   build-and-test all `nil`) and over `.xctestrun` and enumeration documents (errors, two plans, two
   `TestConfigurations`). Gate: the new suite plus
   `TestEnumerationTests`, and one probe run on a scratch package under `~/Library/Caches` showing `planned`
   equal to the `.xcresult`'s `totalTestCount`.

### `run --proved -- <command>`

Asks whether this command has already passed on this working tree's exact content, and runs nothing. It
exists for one measured waste: a verify loop ends in `swift test`, and the `pre-push` hook then runs the
same suite over bytes that have not moved since — at 70–110 seconds a tally, six times in one session. The
wall clock is the smaller half: a second execution of a suite with a known race is a second roll of the
dice and doubles machine contention, so the redundant run is most likely to fail precisely when several
agents are pushing at once.

**The key is content, never `HEAD`.** A commit that only rewords a message leaves the tree identical, and a
tree can be edited with `HEAD` standing still — so the identity is git's own tree object over a *scratch*
index under `.sift/`, seeded from the repository's (so git's stat cache re-hashes nothing untouched) and
refreshed with `git add --all`: everything tracked at its working-tree content, plus everything untracked
the ignore rules do not exclude (the enumeration `reconcile` walks, §6.4). The caller's index is never
written. A key git will not produce is a refusal, both when recording and when asking.

**One ledger for every worktree of the repository.** Identical content in two worktrees is one tree, so the
ledger lives under the git directory every worktree shares (`<git-common-dir>/sift/proved-runs.json`): a
suite proved green in an agent's worktree stands for the same tree pushed from the primary checkout, where a
ledger per checkout ran the three-minute suite again at every merge. Each record names the checkout the run
happened in. Two worktrees finishing green runs at the same instant can lose one record, since the file is
rewritten whole; that costs the loser one suite run, the direction every failure here takes.

**Only a green run records, and green is the answer's own `✔ passed` with no clause beside it.** A nonzero
exit, a named failure, a diagnostic, a verdict that is not `succeeded`, a pass inferred from a `-quiet`
exit code, a test process that opened and never closed, a bundle the manifest declares that reported
nothing, and a run under `--parallel` each record nothing, and an absent record runs the suite. **The
tree is keyed twice**, before the command launches and again when it returns, and a run whose tree moved
underneath it records nothing.

**A later red run on the same content revokes the proof.** A run of tests that ends anything but green —
the wrapped command's nonzero exit, sift's own 4 and 5, or an exit 0 that the rules above refuse to record
as a proof — on a tree that did not move is filed in a
sibling file, `failed-runs.json`, beside the ledger, keyed as a green record is. `--proved` refuses a green
record when a red one of the same tree, command, toolchain and working directory finished no earlier than
it (`✘ not proved — a later run of swift test on this tree's content failed 3m ago (run <log>)`, exit 1):
the environment can make two runs of one tree differ, but the newest evidence on those bytes is a failure,
and `--proved` is the pre-push gate. **Filing a red also deletes the green records it contradicts** (same
tree, command, toolchain and working directory) from `proved-runs.json`, so `--proved` then reads the red
itself and answers the same later-run-failed reason, naming its log, when a red of that run is on file and
`no green run of … is recorded for this tree's content` only when none is: `failed-runs.json` keeps 60 records and is shared by every worktree, so 60 reds on other trees
inside the hour would otherwise push this tree's red out while its green still stood. Deleting adds no field,
so an older sift reads the ledger unchanged; the later-red check stays, for a sift from before the shared
lock. A green run in a later second proves the tree again and drops the matching
red record. **Both files take one lock, held across both of a run's writes**, and a green is not
filed at all where a red of the same run on file is dated to the green's own whole second or later:
holding the lock orders the writes, not the runs, and a green that finished first but reached the lock
second would otherwise delete the red and stand. Records are dated to the second, so a red stored as the
green's second may have finished after it; the green is compared by its second, not its fraction, and a
red followed by a green inside one second is refused like the race it cannot be told from, at the cost of
one more suite run. **A sibling file, never a field on the green records**: a sift from before red runs
were filed rewrites the ledger whole on its next green run and drops any field it does not know, which
would turn a red record into a proof. (#463) **A green an older sift wrote proves nothing.** During a
deploy a sift still running the older code files its green under its own lock and clears every red of
that run whatever its date, so a green that finished before a red can delete it. A deletion leaves nothing
to read, so every record carries `writerFormat`, the stamp of the sift that wrote it, and `--proved` reads
a green without the current stamp as absent. The same field-dropping as above does the work: an older
sift's synthesized coding writes no stamp on its own record and strips it from every record it rewrites.
This field may sit on the records where a red may not because losing it turns a proof into a refusal,
never the reverse; the cost is one suite run per tree after the deploy that introduces a stamp. **What
it leaves open**: an older sift answering `--proved` itself still trusts every green; and a red the older
sift cleared, or lost by rewriting `failed-runs.json` under its own lock, is gone for good, so a green from
this sift that finished before that red but reached the lock after the clear is filed stamped and proves.
Both need an older process still running across the install. (#513) **`SIFT_RUN_LEDGER=0` stops the green writes, never the
red ones**: the switch is read per process, so a red run with it off that filed nothing would leave a green
filed with it on answering the next `--proved` that has it on. A red can only refuse. (#494)

**What the key cannot see is what bounds the record's life.** A tree hash does not cover the toolchain, the
build directory, this tool's own state, an environment variable a suite branches on, or the machine. The
toolchain is folded in (`swift --version`, resolved through `PATH`, and a record from another one is
refused). The rest are deliberately **not**: a key over the build directory would change on every build and
prove nothing, and an environment allowlist would be a guess. What covers them is the window: **a record
stands for one hour and no longer.** The saving exists for a gap measured in minutes (verify, commit, push)
and the longest real gap is a review round of tens of minutes; a day would buy no case anybody has and
would leave a toolchain switch live overnight.

**One hazard the window does not bound, so the key refuses instead.** `assume-unchanged` and
`skip-worktree` make git trust the index over the file, so an edited tree hashes to the same value as the
clean one a run was proved on — a red tree let through, which nothing else here can do. Those changes are
deliberate and an hour covers them; this bit is set once and applies silently to every later run. So a tree
whose index hides any entry answers no key at all: nothing records against it and nothing recorded is
trusted for it.

**The answer is an answer** (Docs/AnswerContract.md): its header names the tree's content key and the
command, and a trusted line names the run it stands on, when it happened, what it cost, and everything the
key does not cover. **A skip is never silent**: the line the gate prints is this answer.

**A tree with no record is measured against the newest green run of the same command from the same
directory**, whatever tree it ran on: `last green run 6m ago on a tree that differs in 2 files:
CHANGELOG.md, Sources/X.swift` (ten names, then `+N more`), or `no green run of swift test recorded on this
repository`. Naming the files tells an edit made after the run (a changelog line, a lint follow-up, a patch
put back after a negative gate) from a change that needs the suite again. Nothing new is recorded: the key
is a tree object in the shared object store, so the difference is `git diff-tree -r --name-only`. A tree
git no longer holds is said as `files unknown`, never as nothing changed. The `pre-push` hook prints this
under its refusal of an unproved tree (Docs/Contributing.md).

**Exit 0 is proved, and anything else is not, in one of two exit codes a gate reads apart.** Exit 1 is a
tree with no record of a passing run (a changed or untracked file, a different toolchain, an aged record):
*I could not tell* means *run it*. Exit 2 is the question unable to be put at all — no repository, a tree
git will not hash, no toolchain that will name itself, or `SIFT_RUN_LEDGER=0` switching proving and asking
off. Running the command again cannot fix those, so a gate that refuses on exit 2 as on exit 1 refuses
forever with advice that cannot help; it runs the command instead.

`sift test --shards` keeps no record of its own: its greenness is reconciled across shard result bundles,
a second judgement to keep agreeing with this one, and no gate asks it the question.

### `run --coverage [--from <rev>] -- swift test … | xcodebuild test …`, and `diff --coverage`

Answers the one coverage question an agent has — *is the code I just changed tested?* — rather than
serving a coverage report, which is large and almost all about code the caller did not touch. Measured on
this repository after one filtered suite, `llvm-cov export` wrote 95 MB, SwiftPM's own exported JSON 90 MB,
and `llvm-cov report`'s table 407 KB; the answer for a one-function change is a few hundred bytes.

**It runs the command as `run` does, with coverage on, then adds a section after the answer.** `--coverage`
adds `--enable-code-coverage` where argv does not carry it; the run's own answer, receipt, proof and exit
code are exactly those of the same argv without the flag. The section names each changed declaration — the
same pairing `diff` does, working tree against `HEAD` (`--from <rev>`: against that commit), untracked
files included — with the lines it answers for, how many of its executable lines ran, and the ranges that
did not; one total line closes it. A type whose header changed does not also count the members that answer
for themselves, and a declaration with no executable line says so rather than reading as covered. A changed
file no test bundle compiled is named as not measured; one that holds no executable code (protocols, type
aliases) reads "no code to run". Untouched files get nothing. Only the after side is measured, so a removed
declaration has nothing to report.

**The profile is read from the objects, not from SwiftPM's JSON.** SwiftPM (6.4) exports coverage for the
first test bundle only: on a package with four test targets its JSON named the first bundle's twenty files
and none of the others. The section runs `llvm-cov export` itself over the merged `default.profdata` beside
the path `swift test --show-codecov-path` prints, with the `.xctest` bundles the package's manifest
declares as objects — never every bundle in the products directory, because `llvm-cov` keeps the first
object's copy of each function's line map and a stale bundle of a removed test target would supply old line
positions against a fresh profile. A declared bundle that is missing, or a manifest that cannot name its
test targets (computed, `#if`-guarded, `--package-path`), is a `coverage: refused —` line. The export is
restricted to the changed files and the Swift files beside them, and line counts follow `llvm-cov`'s own
rule for turning region segments into lines, so the numbers agree with `llvm-cov report`'s.

**Coverage from a build of another tree is refused, never shown.** The tree's content key is taken before
the command starts and again after it ends, and the profile must have been written after it started. A tree
that moved during the run, a key git would not produce, and a profile older than the run each answer
`coverage: refused —` with the reason, not a number.

**An `xcodebuild test` run is read from its result bundle.** `--coverage` adds `-enableCodeCoverage YES`
and, where argv names no `-resultBundlePath`, `-resultBundlePath .sift/coverage.xcresult`, removed before
each run because `xcodebuild` will not write over a bundle. The section asks `xccov view --archive
--file-list` once and `--file <path>` for each changed file only, so it reads a few kilobytes per changed
file whatever the project's size: on a 736-file package the whole `--report --json` was 3.0 MB and one
52-line file's lines 2.6 kB. The freshness rule is the same, with the bundle's `Info.plist` as the profile;
an earlier bundle, or none, is `coverage: refused —`. `test-without-building`, `-xctestrun` and
`-enableCodeCoverage NO` are refused beside `--coverage`, as `--skip-build` is.

**`diff --coverage` shows the last measured numbers only for the tree they measured.** Each measured run
replaces one record, `.sift/coverage.json`: the tree's content key, the command, and the line counts of the
changed files only. `diff --coverage` pairs the working tree's change against `HEAD` afresh and renders it
with the recorded counts where the content key is the recorded one — line counts describe file content, so
the key alone decides. A different key is `coverage: stale —` naming both trees, no record is `coverage:
none recorded`, and a changed file the record never looked at makes the whole record stale: never an old
number. It takes no range and no `--member`.

`--coverage` is refused before anything runs on a command other than `swift test` or `xcodebuild`, beside
`--disable-code-coverage` and `--skip-build` (coverage of binaries this run did not build cannot be tied to
this tree), and beside `--without`, `--without-line`, `--restore` or `--proved`; `--from` is refused without
`--coverage`, and a `--from` that names no commit is refused too.

### `run --without <pathspec>… [--since <rev>] -- <tests>`

The proof a fix owes — a test that fails without it — in one call. The named tests run with every
uncommitted change under the pathspec set aside; the changes are put back and checked; the tests run
again; and the answer is one line per test. The flag repeats, one pathspec per flag, and everything the
flags name is set aside as one unit; a second pathspec written beside the first rather than behind a flag
is read as the command to run and refused as the mistake it is, with the corrected command spelled out.
Proving it by hand costs a patch, a revert, a filtered run and a re-apply, often split across turns, with
every file the revert touched re-read as changed on disk. One property overrides every other — it never
loses anyone's uncommitted work, on any path, including being killed and including other processes writing
the tree — and eight things carry it.

**Set aside means the pathspec reads exactly as HEAD has it, in the index as well as the files**, since a
test that lists what git tracks reads the index, and HEAD's files over a staged change is a state no commit
ever had. Every change git reports under the pathspec goes (staged and unstaged edits, untracked files,
deletions, renames as the deletion and addition they are, mode changes, links) and nothing outside it
moves; an intent-to-add entry keeps its place. What cannot be handed back exactly is refused before
anything is copied: an unmerged path, a submodule, a directory where git records a file, two paths that
differ only in case on a volume that cannot hold them apart, a path on another volume than `.sift/`, the
directory the command runs in. So is a pathspec with nothing uncommitted under it. A change under `.sift/`
itself is never moved (the store and the lock live there) and never skipped silently: the answer lists it
as left in place.

**`--since <rev>` sets aside a change that is already committed.** By the time a gate is re-run by a
reviewer, the fix is usually a commit, not a working-tree edit. What leaves the tree is what the commits
since that revision changed under the pathspec: every recorded path reads as `<rev>` has it, and a path
`<rev>` does not have (a file the fix added) is removed, so the tests fail to compile rather than fail an
assertion. Everything after the capture is the uncommitted case exactly. One revision applies to every
pathspec. It is refused, with a named reason and before anything is recorded or the lock taken: with
anything uncommitted under the pathspecs (the two sources are never set aside together); with no
`--without`; for a revision git cannot resolve; for a revision HEAD is not a descendant of, because `git
diff <rev> HEAD` is a two-point diff and a non-ancestor would set aside the reverse of what the commits
since it changed (`--since origin/main` after a fetch still works, since HEAD descends from it); and for a
revision nothing changed under since. The revision is resolved to an object name before the capture, so a
branch that moves while the tests run cannot change what was set aside.

**`--without-line <file>:<line>` sets aside one line instead of a change.** A fix that is a new file, or
adds API a test names, can only answer "did not build" when set aside whole, which proves nothing about what
the test pins; the proof it owes is a guarding line neutralised. That one line of a Swift file is commented
out in the file's own place (`// ` after its indentation, every other byte as it was), so the run without it
compiles and the test has to fail an assertion. That holds only for a line nothing after it depends on: a
`guard let` or `let` whose name a later line uses, a `guard … else {` opening a block, or the `return`/`throw` inside one (a guard body must not fall through), does not
compile commented out, and commenting is the only mutation but the one rewrite below — no condition is rewritten to `true` — so the
limit is stated in `sift run --help` and the Guide rather than worked around (#394). One line is rewritten
rather than commented out: a single assignment of a bare identifier (`settings = updated`, read with the
parser, so a call, a member access, an operator or a declaration never qualifies) is set aside as `_ = updated`,
which removes the store and keeps a reader for the binding, so a package that builds warnings as errors does
not stop on an unused value (#620); the receipt says which form was used. When the run without the line stops
on nothing but unused-value errors for names the line read (a form that could not be rewritten), the answer
names the hand form `_ = name`, or `--without` on the fix's file. A one-line guard that is the last reader of
a local above it leaves that local unused when commented out, which a package that builds warnings as errors
refuses, so the help text says to route such a guard through a helper whose parameters carry the inputs; the
run does not pre-check for it. Whenever the run without the change did not build (`swift test` stopped on a
compiler error, not an assertion), the answer quotes the first compiler error under its headline, and the tests
that passed with the change are one count line, `<n> tests pass with it and did not run without <path>, which
did not build`, rather than a line apiece saying only that nothing ran; a test that failed with the change, or passed
with it only on a retry, stays listed by name. Everything else is the pathspec case: the record holds a
byte-for-byte copy of the file, the watcher, lock, `sift run --restore` and exit codes are the same, and the
index is never written. The receipt quotes the line (`set aside: <file>:<n> — "<text>" (commented out for
the run without the change)`, or `set aside as \`_ = <name>\`` for the rewritten form) and names the second run `with <file>:<n> back`. A file that is not `.swift`,
a path outside the repository, a missing or non-regular file, a line number out of range, a blank line, and
a line that already opens with `//` or `/*` are refused with exit `2`; a malformed value or the flag beside
`--without`, `--since`, `--restore` or `--proved` is a usage error, exit `64`.

**Never check, then write.** Every step that could replace or remove something at a user's path — setting
aside and restoring alike — goes through an operation that cannot do it silently: an exclusive rename
(`RENAME_EXCL`), or a swap (`RENAME_SWAP`) after which what came out is looked at. Nothing in the tree is
ever unlinked: what has to go is moved into the store first and looked at there, and whatever came out that
is not this tool's is kept beside its path (`.sift-kept-<id>`) and said. So a path written between being
copied and being set aside is found rather than replaced: the set-aside stops, whatever had been set aside
goes back and is checked, the changed path is left as its writer left it, and nothing runs. Somebody's
bytes that cannot be kept beside their path stop the run with the record kept, the answer naming where in
the store they are, and exit `3`. HEAD's version of every path is prepared in the store first, through the
repository's smudge filters and line-ending rules, and put in place by this process, never by a git child
that could outlive it.

**The record comes first, and it is the recovery.** Before the tree is touched, `.sift/set-aside/` holds a
flushed record — each path, and what HEAD, the index and the tree held for it — beside a byte-for-byte copy
of every file and every staged object, so an object pruned while the index no longer names it costs
nothing. It also holds what the set-aside will leave at each path, so a restore can tell its own work from
anybody else's. While the record exists every `sift run` and `sift reset` refuses and names `sift run
--restore`, which puts the tree back from it; the refusal names whoever holds the tree from what the holder
writes into the lock file.

**Restored on every exit path, and only once nothing the run started is alive.** A restore that begins
while a git child is still writing the index or a test's background writer is still asleep can be undone
behind it, and none of those dies with a run killed outright. So every child the run starts starts
suspended in a session of its own, is announced to the watcher and written into `.sift/set-aside/sessions`
with its leader's start time, and only then runs. The run ends that session before it restores; the first
`SIGINT`, `SIGTERM` or `SIGHUP` is passed on to the tests, their session ended, the tree put back through
the same gate, and the process exits `128 + signal` (a second signal kills outright). What no handler sees
(`SIGKILL`, a crash) is a watcher's: a second `sift`, in a session of its own, told of its owner's death by
a pipe closing rather than by a pid. It takes the lock, ends every session it knows of (`SIGTERM`, a grace,
`SIGKILL`), waits for them to empty, and restores the record it was started for and no other. Who may
restore is decided by `flock` on `.sift/set-aside.lock`, which the kernel releases however its holder dies,
and the run holds it until its second pass is over, so another `run --without` or a `sift reset` cannot act
under it. `sift run --restore` ends whatever the store says the run left running, checked against each
leader's start time so a reused pid is never signalled. A restore that fails is never forgotten: every later
finish reports it again, and the watcher is kept to try once more. A watcher that died while the changes
were out is learned of at the next byte written to it, and the answer says so.

**Restored means the bytes and the index entries, checked by content.** Files come back from their copies
with their permission bits, index entries from their recorded modes and objects; then each file's SHA-256
and each path's index entry are checked against the record, and the record goes only when both agree.
Neither side of the check is a status field that changes with HEAD, so a branch switched or a commit made
while the tests ran is not mistaken for lost work: the bytes come back on top of the new HEAD, what the
switch wrote into a recorded path is kept beside it, and the answer says HEAD moved. Timestamps are new on
purpose: a build that saw an old one could keep what it compiled without the change. A restore never
destroys bytes it did not write: each file is built whole in the store and put in place by an exclusive
rename or a swap (on a volume that cannot swap, HFS+ among them, what stands there is moved into the store
first), and just before the record goes, everything the store holds that came out of the tree is looked at
once more, and whatever is neither what was recorded nor this tool's own is kept beside its path. Every
failure while the work is out of the tree says in plain words that it is not back, that nothing was
deleted, where the copies are, and the command that puts them back. When `sift run --restore` itself cannot
reconcile a path, it keeps everything and names the manual step: moving `.sift/set-aside/` aside by hand
releases the tree and deletes nothing, and `record.json` in it names the path each copy belongs to.

**The run without the change builds in a directory of its own.** An incremental build trusts what it last
recorded, not what it last wrote: ending a build with `SIGINT` mid-compile left stale objects in files the
set-aside never touched, and (inferred, not reproduced) once the changes are back, byte for byte what that
directory last recorded, the next build links those stale objects against the restored tree — a struct
copied at the size it had without the change would be a `SIGBUS` in the next test run. So the first run is
handed `--scratch-path` (SwiftPM) or `-derivedDataPath` (`xcodebuild`) under `.sift/without-build/`, in
place of any the command named, and the second run builds exactly where the caller's builds do. The
`xcodebuild` build settings that name where products or intermediates land (`SYMROOT`, `OBJROOT`,
`BUILD_DIR`, `MODULE_CACHE_DIR`, and the rest of that family, with or without a `[condition]`) are refused
on the command line for the same reason, and so is a file of settings that can set any of them: `-xcconfig`,
or `XCODE_XCCONFIG_FILE`, which `xcodebuild` honours and `swift build` does not (both observed). **That
directory is removed when the run ends, by default**, once the changes are back — a proof, a test that
passes either way, a build that failed, a refusal after the set-aside — and before the run with them, and the
receipt says so in one clause (`built without the change in a scratch build (1.95 GB, removed)`), which it
leaves out when nothing was built. It is as large as a build of the repository, and only a second proof in
the same checkout ever reads it, which a gate never makes. **Nothing is removed while the changes may be out
of the tree**: a run that exits saying they are not back leaves the build, unmarked, says so, and the next
run clears it — the restore comes first, not a 2 GB removal. Only that one directory and its mark go, and
nothing is removed or built through a symbolic link: `prepare` and `discard` remove through one guard, which
refuses while `.sift`, `.sift/without-build` or the directory itself is a link, asked of each item rather
than of a resolved path, since a path not yet built has nothing to resolve. A link there is left whole, the
receipt then names it and how to remove it, and the next run refuses before setting anything aside, naming
the link. An interrupted run leaves it for the next run, which clears it. `--keep-without-build` keeps it,
for iterating on one proof: it is then built on again only after a first run for the same package,
project, workspace and scheme, from the same directory, that reached its tests with nothing it started
left running, and the receipt names it with `remove it any time with rm -rf …`. A build directory is
laid out by package and target name, not by path, so a run for anything else clears it rather than trusting
another package's build, as does a run after any other, so a proof never rests on what a stopped build left.
The first `run --without` in a checkout, the first after one whose tests did not compile, and the first for
another package or scheme build from nothing. A compile failure in a file that imports a test framework is
read as the tests needing the change — except in an `xcodebuild` run without the change, when every such
failure says a module could not be found (`no such module`, or the dependency scanner's `Unable to
resolve/find module dependency`). That run builds in derived data of its own, where a module only ever
built elsewhere is missing, so the answer names the module and counts it neither way; it says it read the
module as missing from that directory where no path set aside is a build definition or named for the
module, and that the change may provide it otherwise. Only the paths are read, and the wording claims no
more. **A SwiftPM run is never read that way**: SwiftPM builds the package's whole graph into the scratch
path it is handed, so a module `swift test` cannot find is one the package, as set aside, does not provide,
and it is evidence the tests need the change like any other compile error in a test file. The run with the
change builds where the caller's builds do, so a module it cannot find is the tests not compiling.

**Both runs are given the repository's own URL rewrites, and the same environment.** A clone made into a
build directory of its own runs a git that never finds the repository, so it never reads `.git/config`: a
package fetched by way of a `url.<base>.insteadof` there resolves in the caller's build directory and fails
in `.sift/without-build/`. So the repository's own `insteadof` rewrites (its config file with the files it
includes, never the user's or the system's) are carried into the command's environment as
`GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_<n>` and `GIT_CONFIG_VALUE_<n>`, and the run with the change is given
exactly that environment too, so the change stays the only difference between the runs. **A run without
the change that could not fetch its dependencies is answered in one line and ends there**: it ran no test,
so nothing was proven, and the run with the change would add nothing — `✘ could not build without
<pathspec>: dependency resolution failed — nothing was proven (…)`, exit 1, and the build directory (a
partial fetch) is removed. Only a run that exited non-zero and reached no test is read this way.

**What remains, said rather than promised.**
- *The index, between reading it and writing it.* An index write landing between a set-aside's or restore's
  read and its `update-index` (a `git add` of a recorded path) is overwritten: its staging is undone, while
  the file stays in the tree. Git's plumbing has no compare-and-swap for index entries, and taking git's
  lock by hand would wedge every git if this process died holding it.
- *A write through a descriptor, after the last look,* into a file this tool put in place goes with the store.
- *Processes outside the run's process tree* (started through a service manager, or that called `setsid`)
  are never ended; what they write into a recorded path before the restore is kept, what they write after
  lands in the restored tree.
- *A watcher that died,* then the run killed outright: nothing restores the tree until `sift run --restore`.
- *Empty directories.* One a set-aside emptied is removed; it holds no bytes.
- *Builds this tool does not start, and products a project's own settings send elsewhere.* An IDE building
  while the changes are out can leave the same stale objects in its own directory; an `xcodebuild` whose
  *project* sets a location setting puts the first run's products where that says; a location setting not
  refused by name (such as `DWARF_DSYM_FOLDER_PATH`) passes through.
- *A missing module in other words,* or one in a folder not named for it: a link error or downstream `cannot
  find type` still reads as the tests needing the change, and under `xcodebuild` an emptied module whose
  folder is not named for it reads as missing from the build directory, counted neither way.
- *One set-aside lock serializes every `run --without` in a repository,* however unrelated, and *one build
  directory per tool kind holds one build at a time*: switching package, scheme or directory clears it.

**The headline counts assertions, and says everything else apart.** `✔ 3 of 3 fail without Sources/ and
pass with it`, then one line per test with the exceptions first: a test that passes without the change pins
nothing, one that fails both ways carries its failure with the change, and tests that print one name and
disagree are said rather than folded. **A test the change did not write, passing both ways, is the expected
case rather than a finding, and is counted instead of named**, so a filter naming a whole suite shows the
tests the change wrote rather than burying them. Which tests it wrote is decided per test declaration: a
function the change adds or edits, and every test under a suite it adds whole, never one merely moved, so a
test whose own body is unchanged folds even when the change edited a helper it calls. Every Swift file the
change touched is read, whatever it imports (a test file skipped for `@preconcurrency import Testing` would
fold its written tests away). The change is the working tree against `<rev>` — what `--since` names, and
without it the branch's merge-base with the default branch (`origin/HEAD`, else a local `main` or `master`)
— read *before* anything is set aside, since a pathspec covering the tests would make the working tree lie
about them. **Not `HEAD`**: the usual negative gate commits the test and leaves the fix uncommitted, and
read against `HEAD` that committed test would fold away as untouched. On the default branch the merge-base
is `HEAD`, so it is the uncommitted change; where none resolves (no default branch, no shared history, a
shallow clone) it is the working tree against `HEAD` too, which can fold a committed test that pins
nothing: name the base with `--since`. The same fold reaches a branch already fast-forwarded into the
default branch, and there the fold line says no branch range was found and names `--since <base>`. Where
the change cannot be read at all, or a test's printed name holds no declaration to match (a `@Test("…")`
display name), nothing is folded: the listing is never quieter than the evidence behind it. **The headline
and the exit code count the tests left after the fold**: a written test that pins beside 25 untouched ones
is `✔ 1 of 1` and exit `0`, not `✘ 1 of 26`. Where every test folds, the headline says `⚠ no test the change
wrote ran under this filter — 3 untouched pass both ways; nothing was proven`, exit `1`. A suite that did
not compile without the change is evidence it needs the change and not a failing assertion, and gets a
headline of its own over the errors, claimed only where a compiler error lands in a file that imports XCTest
or Testing. **Its tests carry that weaker claim on their own lines, and never a tick**: one whose suite did
not build without the change passed with it and was never run without it, which a test that pins the
behaviour and one that merely names the new type are equally consistent with, so it reads `◇ … passes with
it; without Sources/ it did not compile — needed, not pinned`. Where the change adds a file HEAD does not
have, the answer also says that setting it aside *removed* the file (a target's sources are globbed, so a
file that goes takes its declarations with it), names up to three such paths, and says what is left
unanswered: whether a test pins what the file *does* rather than merely naming it. It names no command,
because every way to make the file's own behaviour wrong needs it committed first, and setting *that* edit
aside would prove the edit rather than the fix; a mutation-shaped proof is a separate command. The same
removal is said on stderr before the first run. Any other error before a test ran is the command failing
before it ran tests, with its first error. Outcomes are read from each framework's own start and finish
lines, anchored so a quoted one is never read as real; under `-retry-tests-on-failure` a test is one test,
counted by its last attempt, with the failed attempts said beside it. Only the second run is filed in
`run.jsonl`: the first ran a tree the caller does not have, and its expected failures would read in `flakes`
as tests failing one run in two.

**The exit code is the answer's, for a script to act on**, not the second run's: `sift run --without … &&
…` has to tell a proof from a test that merely passed, and work that is not back from either.

| Code | Means |
| ---- | ----- |
| `0` | Proven: every named test failed without the change and passed with it, both runs on one commit, counted over the tests left after the fold. |
| `1` | Not proven: a test pins nothing, fails both ways or breaks with the change; no test was reported; every test folded as untouched; the tests did not compile; the command failed before its tests; HEAD moved. |
| `2` | Refused or stopped before any test ran, with nothing out of the tree: nothing uncommitted, another run holds the tree, the tree changed while it was being set aside and is back. |
| `3` | Somebody's changes are NOT back in the working tree — a restore that could not finish, or bytes that could not be kept beside their path; the record and every copy are kept, and `sift run --restore` puts them back. |
| `64` | A usage error, said before anything moves: the command cannot prove anything run twice (below), a `--since` revision git cannot resolve or HEAD does not descend from, a command that builds a checkout other than the one set aside from, or flags that do not go together. |
| `128 + n` | Interrupted by signal *n*, with the tree back and checked (`3` if it could not be put back). |

`run --restore` answers `0` for a tree put back or nothing to put back, `2` while another process holds the
tree, and `3` while the work is still out. `sift reset` refuses while any of them holds the tree.

**Only a named test run that builds first, with one outcome per test.** `swift test --filter …` or
`xcodebuild test -only-testing:…`, since unnamed every test in the suite would be reported as pinning
nothing; `--skip-build` and `test-without-building` are refused, because they run what was built with the
change in it. `--parallel` and `--num-workers` are refused because SwiftPM prints no line for an XCTest that
passed in parallel, `-parallel-testing-enabled YES` because xcodebuild then reports each test from a clone
of the runner in lines not read as outcomes, and `-test-iterations` without `-retry-tests-on-failure`, or
`-run-tests-until-failure`, because they keep several outcomes for one test. A scheme can turn parallel
testing on with no flag, so a run whose only test lines are in that shape says so and names
`-parallel-testing-enabled NO`. The tests run with `/dev/null` for their input.

### `test --scheme <Scheme> --device <Device> [--shards N] …`

    sift test --scheme <Scheme> --device "<Device name>" [--os <version>] [--plan <TestPlan>]
              [--only <id>]… [--skip <id>]… [--shards N] [--project <path> | --workspace <path>]
              [-- <anything else, handed to xcodebuild untouched>]
    sift test --sweep

One iOS test suite run across several simulators sift owns for the length of the run, and **one answer
that is reconciled against an inventory rather than read off the last tally a runner printed**. A
sharded run has no closing line worth believing: `xcodebuild` prints one tally per bundle per process, and
a crash restarts the runner and the relaunch's tally stands alone and reads green (measured: five tests and
`0 failures` printed over a run that lost two to a `fatalError`). So the counts in the answer are this
tool's own, taken against the set of tests `xcodebuild` itself enumerated before anything ran. CLI only, as
`run` is.

**sift supplies `xcodebuild` and the action; the caller supplies what every run needs and nothing else**:
the scheme, device, OS, plan, inclusions and exclusions as short flags, and a pass-through after `--` for
the rest, so this command never chases `xcodebuild`'s option list (`sift test --help` documents the flags).
**A pass-through word that names something a flag already names is refused with a sentence, before anything
is launched**, because two spellings of one thing is how they come to disagree: an action, a
`-destination`, `-only-testing:`/`-skip-testing:`, `-testPlan`, `-scheme`, `-project`, `-workspace`,
`-xctestrun`, `-resultBundlePath`, and `-parallel-testing-enabled YES`. **A refused word standing as another
option's value is not a refusal** (`-derivedDataPath build` names a directory), and telling the two apart
is the option table `RunVerdict.Contract` already reads an action with, whose direction is the safety
property: an option this tool has never heard of is assumed to take a value.

**`-parallel-testing-enabled YES` is refused and `NO` is passed on every shard.** Xcode distributes by
XCTest class and hands every Swift Testing suite in a bundle one placeholder identifier, so there is
nothing for it to distribute, its console carries no per-test line this tool can read, and on a large
Swift Testing bundle the worker handoff hangs. The sharding here is the answer to the same want, done where
the tests can still be counted.

**`-collect-test-diagnostics never` is passed on every shard too, and that flag is worth the whole feature
on its own.** Measured on Xcode 27.0: every *failing* run waits `Timed out after 600.0 seconds while
waiting for a response from the invoked process` before it finishes — 610 s of wall clock over 0.2 s of
tests; the same run with the flag took 7 s. A red shard is the common case, so without it every red sharded
run would cost ten minutes per shard.

**The run, in order.** *Sweep* first (every ledger under `.sift/shards/` whose owner and watcher are both
gone has its recorded devices deleted, which covers a reboot). *Build once* with `build-for-testing` for
the named device type and runtime, through the existing launcher and filter. *Find the plan's
`.xctestrun`*: one build emits **one file per plan**, its name embeds the simulator OS and architecture, so
it is matched by plan name (`*_<Plan>_*.xctestrun`; with no `--plan`, the single one written since the
build began) and never composed; none, or several without `--plan`, is a refusal that lists what it found.
*Enumerate* **against that file** (`-xctestrun <file> -enumerate-tests -test-enumeration-style flat
-test-enumeration-format json`), because enumeration needs a built plan; it takes about 7 s and starts
nothing. `enabledTests` is the **expected set**, and the `.xctestrun` carries the plan's own skip lists into
every shard. **One plan per run, and shards never mix plans**: a combination of targets on one device that no
serial run ever exercised is how flakiness gets in. *Plan* from it, wait for the devices, then run, merge,
clean up.

**The enumeration and the plan run while the devices boot, and provisioning is joined only when the shards
are about to launch**: the enumeration names the build's destination (device type and runtime) rather than
one of the run's devices, so it needs none booted. An error anywhere between the build and the plan still
waits provisioning out before it is answered, so the teardown never deletes devices a create or a boot is
still working on. **The build and the enumeration write their result bundles into the run's own
directory** (`.sift/shards/<runid>/`), because without a path `xcodebuild` writes them into DerivedData,
where nothing removes them (38 folders and 7 MB after one day of gates).

**The partition is static — one `xcodebuild` per shard, decided before anything starts.** Longest
processing time first into N bins by the median duration in `.sift/test-durations.json`, ties broken by
identifier so a plan is deterministic, a test with no history charged its own target's median, else the
plan's overall median, else 1 s. Every invocation pays a fixed launch, session and bundle-load cost (about
7 s for a unit bundle, 39 s for a UI bundle), so the planner charges each shard that overhead and **lowers N
while another shard would not pay for itself, saying so in the answer**. A count is never lowered on
estimates alone: untimed UI tests charged the 0 s median of the unit tests beside them once planned a
three-shard run as one. N is clamped to the number of tests; `--shards 1` splits nothing and answers in the
same shape. `--shards` defaults to `max(1, min(performance cores / 2, RAM GB / 4, 3))`, low on purpose:
three booted simulators beside three `xcodebuild`s is 6–12 GB, and host contention fails tight-timeout
tests that pass alone.

**Fresh devices, of the device type and runtime the build was made for, always.** Products built for one
destination are accepted by any device of the same type and runtime, which lets provisioning overlap the
build; a *different* simulator OS invalidates every asset catalog and turns a one-file change into a minute
of rebuild. Each shard gets `simctl create`, `boot`, a bounded `bootstatus`, and the accessibility keys
`SimulatorAccessibility` already arms. Never a clone of a seeded device (gigabytes to delete again), and
the default device set only, since `simctl --set` devices are invisible to `xcodebuild`. Each shard runs
`test-without-building -xctestrun … -destination id=<udid> -parallel-testing-enabled NO
-collect-test-diagnostics never -only-testing:<id>… -resultBundlePath <absolute>`, streaming to its own
`.sift/runs/` log through the existing filter, and a shard that fails does not stop the others.

**Every shard is bounded on wall clock, and one that passes its bound is ended rather than waited on**
(`SIGTERM` then `SIGKILL` over its session), since an unattended run whose answer waits on a wedged
simulator is no answer at all. The bound is three times the shard's predicted seconds with a ten-minute
floor: three shards under load are slower than any alone, and a short shard's proportional bound would fire
on a healthy run. An ended shard is answered for with whatever its log already held, and the merge adds one
note naming it, because its unreported tests are missing by the ordinary rule and a reader not told why
reads them as crashes. A shard whose command could not be started carries the error's own sentence into the
same notes. Nothing about the counts changes: **missing is missing**. `--shard-timeout <seconds>` lowers
the floor for a caller who has measured that a suite never needs it, refused under 30 seconds (it would
fire before `xcodebuild` has launched); the note names the bound where the flag moved it.

**The counts are a reconciliation, and every line of it is named:**

    expected · ran · passed · failed · skipped · missing · duplicated

*missing* is a test the plan assigned to a shard that never reported an ending; *duplicated* is a test that
ended twice **within one iteration, or in two shards**. Either one makes the run **not green whatever
`xcodebuild` printed**, names the tests, and names the shard, so a crash is located rather than merely
noticed. The exit code is the first non-zero shard's, else `1` when the reconciliation alone failed, else `0`.

**One normaliser stands between the three spellings of a test.** Enumeration says `Target/Type/function()`
for both frameworks (`Target/Type/name(_:)` for a parameterised one); XCTest's log says `-[Module.Type
testX]` — the *module* being the target's name with every character a Swift identifier cannot hold turned
into `_` (`Demo Spaced Tests` logs as `Demo_Spaced_Tests`), so a target is matched under both spellings; a
custom `PRODUCT_MODULE_NAME` is not measured and reads as missing; Swift Testing's says `function()` with no
suite at all, possibly a quoted display name, possibly behind a zero-width space. XCTest is matched by
identity. **Swift Testing is matched by function name where that name is unique among the tests the shard
was given, and where it is not, that shard's Swift Testing tests are reconciled by count and the answer says
so**, since a suite the log never names cannot be told from another declaring the same function, and a
merge that guessed would report the wrong test as missing.

**Counting inside such a group is not the pairing refused below**: both sides are closed and named by the
same function, so the arithmetic is over one set. Fewer endings than tests is a shortfall (*missing*, no
name to give); more is a surplus (*duplicated*, no name to give). The endings are spent worst first, so the
verdict does not turn on whether the failure printed before or after the passes, and a later iteration's
endings displace the worst standing before them (the retry rule below, for a group of any size). What the
count cannot see is a test that ran twice while another never ran, which is what "reconciled by count"
says out loud.

**An ending naming no test the shard was given is stated, never spent on one.** It is counted as
unattributed and said in the notes, and every test the shard reported nothing for stays missing. Pairing
*those* two by count, on any restriction of either side, is exactly how a crash is covered up: two open sets
related by nothing but their size, where a count-only group is one name's tests against that same name's
endings. The test that never ran would leave *missing* on the strength of an ending that was never its, and
the run reads green.

**The one ending a shard can attribute without guessing is a quoted one, and the plan carries what it
takes.** A display name is the one thing an identifier does not carry, so a test declaring `@Test("…")` logs
under a literal its shard's plan cannot recognise, and the merge reported a passed test as missing on every
run. So the plan carries the inventory's literals beside its shards, and the merge spends a quoted ending
on the test that declares it, narrowed to the tests this shard was given and is still waiting on. Where the
literal names no test this shard is still missing, or the run had no inventory, the ending stays
unattributed and the test stays missing, the direction a false red belongs in. **Reading that inventory
never refuses a run and never builds an index**: the index database is read where one is already sitting and
skipped where there is none; a stale index costs a test reported missing as before.

**Retries are attempts, not duplicates.** A plan with `testRepetitionMode: retryOnFailure` re-runs under
`Iteration N` — XCTest re-runs the one failing test and counts *attempts* in its own tally (`Executed 10
tests` over 9 methods), and Swift Testing re-runs the whole bundle. The merge deduplicates by identity
across iterations, takes the **last** attempt as the outcome, and reports `iterations` per shard beside the
timings.

**Wall clock stands beside summed execution, per shard.** Summed per-test seconds cannot see launch,
session start, bundle load or retries, and when wall exceeds the sum by more than 2× the answer says so:
that gap, not the tests, is then the thing to fix. The answer also carries the five slowest tests, the log
paths, a devices line (`3 simulators created, 3 deleted`), and — **when tests are missing — the `xctest-*.ips`
and app crash reports under `~/Library/Logs/DiagnosticReports/` dated inside the run**, because a missing
test is nearly always a crash somebody can read. **On failures it carries the `sift test` command that
re-runs just those tests on one simulator**, since a failure under three-way load is not yet a failure.

**One line under the shard lines times the run itself, phase by phase** — `build 12s · enumerate 7s ·
devices ready +30s · shards 200s · teardown 6s` — because the per-shard lines cannot say whether more
shards, a faster build or fewer boots is the lever. The phases are in order and add up to the wall clock
from the build's start; *devices ready* is what the run waited on after the build and enumeration (`+0s`
when the devices were ready first).

**Durations are recorded only from a shard that had nothing to hide.** `.sift/test-durations.json` keeps,
per identifier, the last five observations with their dates, and the planner uses their median (whichever
test runs first in a bundle is charged the bundle's load). **Only first-iteration observations, and only
from a run or shard with no retries and no missing tests**: a timing taken while something failed measures
the retry. Skips count, because a skip can be expensive. Entries unseen for 90 days are dropped. It is
updated after every sharded run *and* every wrapped `sift run -- xcodebuild test` that printed the lines, so
the serial run people already do seeds the first sharded one — but only with target-qualified XCTest names,
the only shape a plain run's log carries an identifier this store can key by; Swift Testing's names carry
no target or suite, and arrive only once a sharded run has one to reconcile them against.

**Cleanup — the invariant. A device sift created is deleted by the UDID sift recorded, by whichever of
three actors is still alive: the owner, its watcher, or the next run's sweep.** The ledger
`.sift/shards/<runid>/ledger.json` carries the owner's and the watcher's pid and start time, and per shard
an *intent* (the name) written **before** `simctl create` and the UDID written the moment create prints it,
atomically at each change. The watcher is a detached `sift` on the same primitives the set-aside guardian
runs on (`WatcherProcess`), learning of its owner's death from a close-on-exec pipe reaching end-of-file; an
end-of-file without the owner's explicit `r` is a death, and it then ends the shard sessions the owner
recorded before it deletes anything, because an `xcodebuild` still driving a device that is being deleted
wedges CoreSimulator. The owner handles `SIGINT`/`SIGTERM`/`SIGHUP` through the same teardown and exits `128
+ signal`, and every ordinary exit path (a build failure after provisioning began, a boot timeout, a thrown
error) goes through that one path too.

**Names make an orphan findable with no record of it at all.** Each `.sift/` holds a `device-prefix`, six
hex characters minted once per checkout, and every device is named `sift-<prefix>-<runid>-<k>`. The sweep
lists the devices whose name starts `sift-<prefix>-` and asks of each whether run `<runid>` is still alive
(its ledger present, its owner or watcher running). If so the device is left alone, UDID recorded or not,
which keeps a parallel session's run in the same checkout safe during its own create window. If not, it is
an orphan and is deleted by the UDID the listing gave. **The name only finds candidates; deletion is always
by UDID, and a name without this checkout's prefix is never looked at.** A delete that fails or times out
is stated in the answer by UDID with the command to run, and its ledger is kept for the next sweep to
retry — never reported as clean. **`sift test --sweep` is that sweep and nothing else**: it answers with
each device deleted by name and UDID, exits 0 (1 when a delete failed), and refuses every flag that
describes a run.

#### In a SwiftPM package

`sift test [--shards N]` in a directory holding a `Package.swift` runs the package's tests across N
concurrent `swift test` processes (default: `max(1, min(performance cores / 4, 4))`) and answers with the
same reconciliation a simulator run gets.

- **One build, then shards past the lock.** SwiftPM locks `.build` for every command, so two `swift test`
  processes on one package wait on each other. The run builds once (`swift build --build-tests`), and every
  shard is `swift test --skip-build --ignore-lock`: it builds nothing, so the lock guards nothing it does.
- **The expected set is what `swift test list --skip-build` prints** over that build, the way a simulator
  run's is what `xcodebuild` enumerates. Every line it prints is a test the run owes (a nested suite's
  `Module.Outer/Inner/f()` is read as `Module/Outer.Inner/f()`; a file-scope `@Test` is given the type
  `(file scope)`), because a test the listing names and the partition drops would leave the answer without
  trace. The listing is read from standard output alone, and **a non-blank line that names no test refuses
  the run**, naming the line: SwiftPM writes its wait on another process's `.build` lock to standard error
  with no newline, and read together with the listing it glued itself onto the first test's line, which
  then ran nowhere under a green answer. The listing keeps the lock, since it runs the test bundle.
- **The partition unit is the outermost suite**, never the test: a suite is what one short anchored
  `--filter` names, what `.serialized` orders and what shares fixture state. A nested suite travels with
  the suite around it; a file-scope test is a unit of its own with its own anchored filter.
- **Cost data.** Each suite is charged its observed wall-clock span in the Swift Testing event stream each
  shard writes (the option's name is found with `swift test --help-hidden`, since it was renamed between
  toolchains). **Spans do not add up**: a shard's suites all start together, so each span counts the time
  spent beside every other suite, and summing them predicted 3,770 s for shards that ran 84–147 s. Every
  charge is in wall seconds instead. A shard is predicted to run until the later of its longest span and
  the sum of its suites' *shares*, where a share divides each second of a span among the suites still
  running then, so a long `.serialized` suite is charged its whole span and no heavy suite is put behind
  it while a lighter shard is open. A suite with no span is charged by its framework, which the listing
  tells apart (XCTest lists its methods without parentheses). An XCTest suite (which writes nothing to the
  stream) runs one test at a time, so its tests' summed durations are wall time and are charged on top,
  capped at the longest span where one exists. A Swift Testing suite with no span (its stream was never
  read) is charged the longest of its tests' clocks as its span, never their sum: under in-process
  parallelism each clock counts the time its test waited, and in this repository's own store the clocks
  summed to 152,000 s where the suites' spans came to 20,000. One with neither is charged the median of
  the others. Every shard also pays a fixed launch charge.
- **The event stream is the record for Swift Testing; the console is for XCTest and for messages.** Under
  load whole `✔ Test … passed` lines go missing inside SwiftPM's relay (one lossy shard printed 603
  `passed` lines where its stream held 699 `testEnded` records; no sift involved). So a shard's Swift
  Testing tests are settled from the stream: a test ran where the stream has its `testEnded` (or
  `testSkipped`), and failed where an `issueRecorded` for it in that iteration says `isFailure`, which a
  known issue and a warning do not. A test the stream declares and never ends is missing. The console is
  still read for XCTest and for failure messages; a failed test whose message the console lost is named
  under `failed with no failure recorded`, beneath the messages, so every failed test is named once, short
  of the failure block's cap: past it the rest are counted, not named (`+N more failures under the signatures
  above, not named here — see the raw log`). A shard with no usable stream is read from its console as
  before, and the answer says so where that console shows Swift Testing ran. **The listing goes through the
  same relay**, so a listed line can vanish and its test then be expected by no shard; a test that ends in a
  stream and that no shard was given is named under `ran but was not listed` and the run is red. A suite
  the listing lost whole (a file-scope test is a one-test suite) is in no filter and no stream, so the
  listing is also set against the index: a test the index declares, in a module the listing named, whose
  file still spells its name, and that no listed line named, is a candidate. Where one remains the package
  is listed again: a line is lost only now and then, but a test compiled out (a file the target excludes, a
  name the index holds from before a rename) is missing from every listing. Up to three confirming listings
  run (the second, and two more), and one is repeated only when it falls short of the first, naming fewer
  than everything the first named, an empty one included. A candidate that any confirming listing names
  counts as compiled and stays owed; only one missing from every listing, with at least one of them
  complete, is dropped. A listing that fails (a non-zero exit, or output that cannot be read) stops the
  confirming and leaves every candidate owed. Where candidates stay owed because confirming failed or never
  completed, a line under the never-listed names gives the reason and the kept log. An owed test that a
  stream ended, or a console ending names (an XCTest method its class's filter still ran), is named under
  `ran but was not listed`; the rest are named under `declared but never listed`. Either way the run is
  red.
- **A lost test is diagnosed, not just counted.** A shard that reported fewer tests than it was given is
  named with its exit code (and the signal, where the code is 128 + one), whether its log closes on Swift
  Testing's `Test run with …` line (one for every `Test run started.`), and its log, which is kept out of
  the next runs' pruning. A shard that exits non-zero where the headline names no other cause (a crash
  after its last ending, say) is named in the headline, its log on its shard line, so a red verdict never
  stands without a cause; where the headline already gives one, the shard is named on its own shard line only.
- **The pre-push hook is not pointed at it.** `sift run --proved` reads only a green record of `sift run --
  swift test`, and a sharded run writes none: its proof would be a second contract to keep in step.

### `test --analyse [--plan <name>] [--enumerate] …` — `--enumerate` specified, not built

**How many tests are *supposed* to run.** A tally is a count of what reported, and nothing in any runner's
output is a count of what exists: a crash loses the tests that never started, a retry counts attempts, a
plan's exclusion leaves no trace, and a whole test target named by no plan is mentioned by nothing a run
produces. So the count a reader needs comes from somewhere other than the run, and the index is the only
thing that holds it.

**A target no plan names is not thereby unrun, and the answer says which of the two it read.** A scheme
that names no test plans runs the targets its `TestAction <Testables>` block lists, and `swift test` reads
no plan at all. So the `.xcscheme` files are read too (shared, and per-user under `xcuserdata`, of an
`.xcodeproj` or `.xcworkspace`), and a target is reported three ways: **run by a scheme's `TestAction`**
with no plan involved, **run by nothing** where no plan names it and no scheme read whose container holds
it names it either, or, where no scheme covering it was read at all, named by no plan and nothing further.
Only the middle one marks the verdict glyph, and only it says *nothing under this repository runs this*:
both halves of that sentence are then something the command read. A per-user scheme is labelled
`[per-user]`, because what it runs is true of one machine rather than every checkout. A scheme that names
test plans has those plans read while its `Testables` block is reported as superseded (Xcode's exclusivity
there is documented rather than measured, so a target named only in such a block is claimed neither to run
nor not to). A `TestPlanReference` also says which plans are wired to a scheme, so an orphan `.xctestplan`
stops reading like a plan something invokes; a plan no scheme read names may be wired to a scheme the
repository does not commit, and the answer says that too. A plan's `containerPath` confines its judgement
to the directory that holds that container, and a target declared outside every such directory is reported
as that rather than counted as a target some plan declined. `--analyse` builds nothing, boots nothing and
runs nothing: it reads the index and the `.xctestplan` files off disk.

**Three sets, and the answer is the gaps between them.**

| set | source | answers |
|---|---|---|
| **declared** | the index — `@Test` functions, and `test…()` instance methods on a type whose written inheritance reaches `XCTestCase`, by the shape rule `TestSymbolReader` already applies for `affected` | what exists in source |
| **planned** | each `.xctestplan`'s own JSON — its `testTargets`, their `enabled` flag, `skippedTests`/`selectedTests`, `defaultOptions` — and, with `--enumerate`, `xcodebuild … -enumerate-tests` against the plan's built `.xctestrun` | what a plan is supposed to run |
| **ran** | the logs, reconciled by `ShardMerge` — already built, under `test --shards` | what did |

`planned − ran` is the sharded run's existing reconciliation. What only the static side can see is
`declared − planned`: **a test, or a whole target, that is in no plan**. Enumeration knows what a plan
includes and can never know what it leaves out.

**Test plans and schemes are read live from disk, never indexed**: small JSON and XML, so a file edited a
minute ago is answered on, with nothing stored to go stale. Every `.xctestplan` under the repository is
read (`--plan <name>` narrows the answer to one) and the header says how many were found, where, and which
scheme names each. **A plan no scheme names here is not thereby an orphan**: a generated project may not
commit its `.xcodeproj`, so the answer says the plan was named by no scheme *read here*, never that nothing
is wired to it.

**Four static dispositions, and each is a different promise about the run.** A declared test is `runs`, or
one of:

- **disabled** — `@Test(.disabled(…))`, or a `@Suite(.disabled(…))` on the type that owns it. Enumeration
  lists it as *enabled*, because it is a runtime skip rather than an exclusion, and the run reports `➜ Test
  x() skipped: "not ready"`. So it is in every expected count and never exercises a line of code, which is
  the shape a reader mistakes for coverage.
- **conditional** — `@Test(.enabled(if: …))`, or an XCTest body opening `try XCTSkipIf(…)` /
  `XCTSkipUnless(…)`. Decided at runtime, so it is reported as undecidable rather than counted either way,
  since a count that guessed would be wrong in one direction silently.
- **skips** — an XCTest body whose first statement is `throw XCTSkip(…)`. It reports as skipped and keeps
  the run green with no tool's help: the only self-announcing exclusion of the four.
- **excluded by `XCTFail`** — an XCTest body whose first statement is `XCTFail(…)`, the convention these
  repositories use to switch a test off in source. It reports as an ordinary **failure** on every surface,
  so **nothing but a static read can tell it from a real one**.

The first statement of the body is the rule, not a search of the whole body: a test that calls `XCTFail`
after twenty lines of setup is a test that failed, and folding the two would hide real failures behind a
convention.

**What the answer reports, beyond the counts.** Only the residue, so a repository with none of these
prints none of these sections:

- **tests, and whole targets, named by no plan**, by what the schemes read say about them (only *nothing
  under this repository runs it* marks the verdict glyph);
- **a scheme that would not parse**, named with the file;
- **plan exclusions that have no effect** — a Swift Testing identifier in a plan's `skippedTests` was
  ignored in every shape tried and the test ran, while the XCTest entry beside it held (only with
  parentheses in the identifier), so each such entry is named as having no effect;
- **plan exclusions that work but are invisible** — an honoured XCTest entry, a whole class included, leaves
  no line, no `.xcresult` node and a tally smaller by one, so each is named with the advice to move the
  exclusion into the test, where every report shows it as skipped with its reason (measured on Xcode 27.0);
- **what a retry setting costs** — `testRepetitionMode: retryOnFailure` makes XCTest count attempts rather
  than tests in its own tally;
- **a plan naming a target the index sees no tests in**, and **a test file whose module attribution was
  guessed**, because a count assembled from a guess can be wrong about which bundle a test is in.

**`--enumerate` — specified, not built.** It adds the runner's own answer and reconciles the two both ways:
a test the index declares that the plan does not enumerate is a test in no target (the silent loss, stated
as a fact), and a test the enumeration lists that the index did not declare is **a gap in this tool's own
recognition**, reported as such, because an inventory that quietly under-counts is worse than none. It is
left unbuilt because enumeration needs a `build-for-testing` against a concrete destination, and a command
whose point is that it builds nothing should not grow a `--device` flag before the static answer has been
used in anger.

**A package with no plans is answered, not refused.** SwiftPM has no test plans and `swift test` runs every
test in every test target, so there `declared` *is* the expected set and the answer says so in place of the
plan sections. This is the repository shape the tool itself has.

CLI only, as the rest of `test` is. The counts are per test *function* — a `@Test(arguments:)` function is
one test, measured under both runners — which is the unit every tally already uses.

#### `--against <log>` — the other end of the same join

`--analyse` says what is supposed to run. `--against <log>` reads a run that already happened (the file
`swift test` wrote, or a log kept under `.sift/runs/`) and sets it against that same declared inventory, in
the seven words the sharded reconciliation prints. It builds nothing and boots nothing. **Its rules are the
sharded reconciliation's, above, except where stated here**: the quoted-ending join, the count-only groups
(spent worst first, surplus duplicated, no pairing by count in either direction), the retry rule, and the
per-shard reading of a literal split across shards are the same rules, with a group of conditional tests
owed only what ended and every member named undecided where its endings do not reach all of them.

**The expected set is bounded by the package manifest's test targets, not by the whole index.** `swift
test` runs this package and nothing else, so reconciling its run against every test the index holds would
report every test of a sibling project missing. Only the targets the manifest declares are judged, and
every other target the index declares tests in is named as outside this run's container with how many tests
it holds. A `.testTarget` inside an `#if` makes that list one configuration's rather than the package's,
and the answer says so.

**A test declared at file scope is reconciled like a suite's, under the type `(file scope)`** (the
sharded path's spelling). Swift Testing logs a free `@Test func f()` as `Test f() started`, by its literal
(`Test "…" started`) where it wrote one, by its raw-identifier words likewise, and a parameterised one by
its function with per-case lines beneath (measured on Swift Testing 2084, 1 Oct 2026), so it is counted as
declared and its ending as expected, and one that never reported is named
`Target/(file scope)/f()`. Lifting them out read a trapped process as nearly complete, since file scope
is the commonest Swift Testing shape (#456). No suite's pass line vouches for a file-scope test, so one
that started and never ended is never reported, not a lost result line.

**A test inside an `#if` is judged by what the host this runs on can prove about the clause** (#457). The
index records every clause, so the inventory parses a file again (and discards the tree) only where a test
sits inside one, and evaluates each clause in order: `os(…)`, `arch(…)`, `targetEnvironment(simulator)`,
`canImport(…)` of a module macOS always or never has, the literals, `!`, `&&` and `||`; an `#elseif` or
`#else` after an active clause is inactive. A test in a clause the host proves inactive (`#if os(Linux)` on
macOS) is never compiled here, so it is lifted out of both counts and named: `inventory: 18 declared, 18
reported (1 more sits under an #if this platform does not compile, not run here: GizmoTests/PalletTests/testTwo())`,
and its own section under `--against`. Anything the host cannot decide (a flag such as `DEBUG`, a version
check) is never read as false: such a test is owed only what it reports, as a conditional test is, and one
that reported nothing is named, by identifier, in the `conditional test reported nothing` clause, so the line never reads as
plain `N declared, N reported` over it. **A start line no ending followed proves the clause compiled**, so
such a test that started and never ended is owed its ending and never reported, red: a process that crashed
in an `#if DEBUG` test otherwise read green. The same holds for a test the host judged compiled out: any line
under its name that no compiled test claims (a Linux log read here, `swift test --arch x86_64`, Rosetta)
proves its clause compiled, so it is owed as a compiled test is and only one that printed nothing is named
apart. A test in an active clause is owed like any other, so a missing
one there is still never reported. The host is the machine sift runs on, which is the run's own for `sift run`;
an `--against` log from another platform is judged by this one's clauses.

**Missing or duplicated makes the run not green, whatever its own summary said**, and is a red verdict with
exit 1. *Missing* is a test the inventory declares in scope that reported no ending at all, the case the
join exists for; *duplicated* is a test that ended twice **within one iteration**, which no retry setting
explains. Everything else is stated rather than counted: a test whose body opens `XCTFail(…)` is lifted out
of the arithmetic and named with whatever the run made of it; a conditional test the run reported nothing
for is counted in neither direction; and an ending that claimed no test in scope is reported without
failing the run. A group reconciled by count says `N of these M never reported` rather than naming which. A
test whose result line was lost, on the terms the run inventory note states, is neither missing nor
reported: it is listed under a heading of its own, counted as `lines lost`, and does not make the run red.

**A reconciliation that expected nothing is not green.** Nothing expected means nothing checked, and a run
this answer checked nothing of is otherwise indistinguishable from one it checked entirely, so the command
exits 1. The headline says which of the two ways the expected set came to be empty, because they send the
reader to opposite places: a container the index declares no test in at all (a log from another repository,
or targets holding none of what it declares), or a container whose every declared test was lifted out of
the counts (switched off in source, or conditional and never reported).

**An iteration that ended fewer tests than the one before it is stated.** Every count stands on each test's
last attempt, so a later iteration that stopped part-way leaves the tests it never reached counted by an
earlier iteration's ending. Nothing in the log tells that from a retry that re-ran only what failed, so the
answer says the asymmetry is there rather than resolving it silently.

### `build --analyse [--top N]` — which code is slow to compile

The compiler already answers the question, one line per function body and per type-checked expression,
under `-Xfrontend -debug-time-function-bodies` and `-Xfrontend -debug-time-expression-type-checking`.
Nobody reads it, because it means editing a manifest, building clean and digging through a noisy log.
This command builds a SwiftPM package clean into a scratch path of its own inside the tree's gitignored
`.build/` (`--scratch-path .build/sift-timing`, so the developer's own products are untouched), passes
the two flags on the command line (the manifest is never edited), and answers with the ranked residue.
Unlike `test --analyse`, which builds nothing, this one *builds*. SwiftPM only for now: an `xcodebuild`
project is refused in one line. Left for later: a threshold mode, `xcodebuild`, `-stats-output-dir`.

**The line shapes the parser rests on, measured** (Swift 6.4, swiftlang-6.4.0.34.1, macOS 27.0; the
capture is `Tests/SiftCoreTests/Fixtures/RunOutput/swift-build-debug-time.txt`):

```
3.22ms	/Users/dev/Widget/Sources/Widget/Slow.swift:5:19
7.42ms	/Users/dev/Widget/Sources/Widget/Slow.swift:4:10	instance method Widget.(file).Ledger.total()@/Users/dev/Widget/Sources/Widget/Slow.swift:4:10
```

An expression is `<ms>ms`, a tab, and `<absolute path>:<line>:<column>` at the expression's first byte.
A function body adds a tab and the compiler's description of the declaration, `<kind> <Module>.…@<location>`,
and its location is the declaration's name. Three more facts from the same capture shape the analysis:

- **A body's time includes its expressions'.** `total()` took 7.42 ms, and the literal chain inside it
  3.22 ms of that. The two totals are therefore stated side by side and never added.
- **One site can be timed more than once.** The stored property `rates` has its initializer checked in
  each of the three frontend jobs that needed its type (emitting the module, and once per file), and its
  synthesized getter, setter and `_modify` accessor are three body lines at one location. Lines are
  folded by site into one row with a count; for a body, the site is its declaration.
- **Closures are not timed on their own**: a closure's time is inside the expression and body holding it.

**The default build system prints none of these lines on a successful build**, and under `-v` prints them
glued to the end of an echoed command, where no line reader can find their start. `--build-system native`
prints them one per line, so that is what the build runs; a build that succeeds and prints no timing
line at all is refused as such rather than answered as "nothing is slow". `--build-system native` is
deprecated by SwiftPM, but on Swift 6.4 it is the only build system that prints these lines at all, so a
future toolchain that removes it will need a different flag here.

**Expression shapes are read off an operator-folded tree.** `SwiftOperators` groups a parsed expression by
real precedence before a shape is judged, so a long chain of `+` is told apart from SwiftSyntax's raw,
left-associative parse.

**Declarations come from a fresh parse of each listed file**, by the parser the index uses, for the reason
`run`'s failure sites give: the build just compiled the bytes on disk, and a stored line range is the one
thing about a just-edited file that can be out of date. Only files holding a listed row are parsed. Sites
outside the package's own sources — dependencies under its `.build/` — are counted in a line of their own
and never ranked. That line states the bodies and the expressions in no body apart, never an expression
inside a body twice: a fresh parse of the dependency file says which an expression is, and where the file cannot
be read it counts only when it printed no body line. A nested local function's body is left out as it is from
the totals. A line in a macro expansion's generated buffer is printed with a bare `@__swiftmacro_….swift` for
its path, which resolved against the working directory reads as a file at the package's root, so it is
recognised by that name first and counted on a `macro expansions:` line of its own, bodies and expressions
apart, never ranked (#503). The buffer is not attributed to the file that expanded it: the output names that
file only inside the mangled buffer name, and only for a freestanding macro (an attached one's names its
declaration), and the expanding expression already has a timing line of its own in the source file. A line
inside a `deinit` is named `Type.deinit`, found
from the same parse, because the index records no declaration for a `deinit` and the enclosing one is the type.

**The command.** `sift build --analyse [--top N] [--root <package>]` (`BuildCommand`) refuses a root
with no `Package.swift` in one line — naming the SwiftPM-only scope where an `.xcodeproj` or
`.xcworkspace` stands there instead — then *deletes* `.build/sift-timing` rather than asking
`swift package clean`, so a second run into the same scratch path is as clean as the first, and runs the
build through `RunLauncher`, so its transcript is kept under `.sift/runs/` like any `sift run`. A failed
build is answered by `RunReportRenderer`, as `sift run` answers it, and exits with the build's code; a
green one with no timing line is refused. The answer (`BuildTimingRenderer`) opens on the build it ran —
`✔ sift build --analyse — clean build, 42.3s, 1,204 timing lines over 87 files` — then the slowest N
bodies and the slowest N expressions, each `file:line · N ms · <enclosing declaration> (×count)`, the N
files holding the most body time, the totals line (`bodies 12.4s of which the 10 listed are 61% ·
expressions 3.1s, listed 74%`, the two never added), a line for time outside the package where there was
any, a line saying the ranking covers the compiled targets only where the build left out test targets the
manifest declares (`swift build` does not compile them; `--build-tests` adds them to the build, and the line
is then absent, as it is for a package with no test target), and the receipt naming the raw log. The help topic is `build-output`, since a topic named for a
subcommand would hide that subcommand's own usage.

### `flakes`

For every test that has **both failed and passed** across the recorded runs: how many named it, how many
runs that is out of, and the day one last did. **It is a measurement and it never names a cause** — "named
in 3 of 20 runs" is a fact about a log, and 3 in 20 is equally what a real regression looks like when the
change behind it was present for exactly those three runs. **The denominator is stated**, and it is not
"runs of this test": nothing records which tests a run executed, only which it reported failing, so the
population is runs of the same *command* — tool **and** action, since folding runs that execute a test
bundle together with runs that execute none turns a hard regression into something that reads as a flake.
Test names are code identifiers, so they render redacted by default.

**Outcomes are keyed by the tree's content and the command line, in two tiers.** A deliberate red — a
negative gate, a failing test written before its fix — is a test failing on one tree and passing on another,
and counted as runs of one command it reads exactly like a flake and buries the real ones. Neither `HEAD` nor
"dirty or not" separates them: a fix is usually uncommitted, and a set-aside and its fix are both dirty.
Content does: deliberate reds change bytes, a genuine flake does not. So `run` records, at the start of every
run that executes tests (`swift test`, `xcodebuild test` / `test-without-building` — never a build, a linter
or a passthrough), `tree` = SHA-256 over `HEAD`, the bytes of `git diff-index -p --binary HEAD`, and each
untracked, unignored path with its `git hash-object --no-filters` (no `-w`, and no clean filter or LFS
hook run). It is **read-only** — no `git add`, no `write-tree`, no object written, no index touched. The
diff is the plumbing `diff-index`, not porcelain `git diff`: porcelain refreshes the index for a file whose
stat moved and whose bytes did not, `GIT_OPTIONAL_LOCKS=0` does not stop it, and that write takes
`index.lock` under a parallel session's commit; plumbing prints nothing for such a file, so a `touch`
changes neither the index nor the key. It is **bounded**: a diff over 32 MiB, more than 2,000 untracked
files (the listing is read only that far) or 64 MiB of them, an index entry hidden from git's stat walk
(`assume-unchanged`, `skip-worktree`), a submodule with uncommitted content (`-dirty` in the diff, asked for
with `--ignore-submodules=none`; a submodule moved to another commit is hashed by that commit), an untracked
nested repository, git not answering within 5 seconds across all its calls, or any git failure records no
tree rather than a key that might equate two different trees. `sift test` records none.

Beside it goes `invocation` = SHA-256 of the directory the run was started in, relative to the repository
root, and its argv. **The log keeps the tests that failed, not the tests that ran**, so a narrower run —
`swift test --filter steady` after a red full suite on the same tree — would otherwise read as a pass of a
test it never reached, and the red test would be served as a same-tree flake. Outcomes on one tree are
therefore compared only between runs given the identical command line in the same place; a line that
recorded a tree and no invocation is unknown. The report then lists, per population, first **the same-tree
tier** — a test that both failed and passed on identical bytes under one command line, stated as
`2 of 9 on one tree` over only those runs — then **the tests that failed only on trees, or under command
lines, they never passed on**, under a caveat that a change of bytes or of command line sits between every
failure and every pass there, and that a narrower command may not have run the test at all: what a
deliberate red, a regression and its fix all look like. A run recorded without a tree — every line written
before the field existed — is **unknown**, never either tier: its tests are listed apart under the old
single-tier reading, and the runs are counted out loud the way runs that recorded no failures are. An inline
note on a red `sift run` saying the same test passed on this tree before is a follow-on, not part of this.

**`--root` covers every worktree of the repository it names.** A failure recorded in an agent's worktree
and a pass in the primary checkout are one test's history, but a linked worktree sits wherever it was cut —
often outside the checkout — so scoping by path alone drops one half. Every line `run` and `test` write from
inside a repository therefore carries `repo`: the first 16 hex digits of SHA-256 over the canonical path of
`git rev-parse --git-common-dir`, which every worktree of one repository shares. It adds no path beyond the
`root` the line already records, and no failure text. `flakes --root` takes the runs in the directory it
names and beneath it, then every run whose `repo` matches one of theirs or the named root's own, wherever
it ran. A line without `repo` — every one written before the field existed — is scoped by path alone, as it
always was. Only `flakes` widens: `usage` and `report` scope `usage.jsonl` and `run.jsonl` with one resolved
argument, and a lookup line carries no `repo`, so widening their runs would put two populations under one
header.

### `affected [--from <rev> [--to <rev>]] [--depth N] [--reached <name>]...`

The test targets and test symbols that reference the symbols a diff changed, plus the exact runner
arguments a caller could pass — a full gate on a large app is thousands of tests and minutes of wall
clock, and an agent that changed one file runs all of them. **It reports; it does not run, and it never
decides what to skip**: "your tests pass" from a run that quietly omitted the failing one is the worst
answer this tool could produce. CLI only, on `run`'s reasoning. Six things bound it. **It states what it
could not determine, above the list** — reflection, selectors, string-keyed lookup, dynamic member lookup,
an override reached through its base, resources loaded by name, anything behind a macro, comments and
string literals — closing on *a green run of only these tests is not a green suite*, and saying of an
empty result that finding no reference is not evidence that nothing is affected. **A changed file resolves
to every declaration in it**, since hunk line numbers refer to the old file for a deletion and a deleted
method has no extent to intersect; erring wide costs a longer list, erring narrow costs a test that should
have run. **The walk is bounded and says so**, two hops by default, because one under-counts every
codebase with a test-helper layer and three reaches most of a suite. A reference landing in a suite's own
helper or property names that suite whole and is followed on as well, in both walks, since a test in another
suite calling the helper reaches the change through it; a test function and the suite's type are where a walk
stops (#579). The bound is per changed file, not only per walk: a changed file outside the test files none of
whose declarations reaches a test within it is walked on, through resolved references only, to the first hop
that reaches one, and the answer says so beside the cap notes, naming the file and that hop, or that it reached
none; the limits block's depth line and `diff`'s tests section, which both state the bound, name the exception. A file deep in a pipeline otherwise lists nothing at the default depth (measured on this repository: a
scope reader behind `where` sits five hops from its first test), while walking every file on would reach most
of a suite; the walk-on is under the same expansion cap, which makes a capped answer not a strict superset of the one before the walk-on existed (a helper expanded early spends cap a later ordinary row would have used), and it never feeds the name-matched fallback, which past
the bound would match far more than it narrows. **The freshness contract applies in
full**, through the same machinery `where` uses, and a name written in more than 40 files is dropped from
the fallback and named as dropped. A name match in a file whose module cannot load the module declaring the
name is set aside, since Swift lets no code name a declaration from a module it never loads: a module loads
itself and every tree module an import in any of its files names, followed transitively (the module-wide
union, not the file's own imports, because a member can leak between one module's files). It never sets
aside where either module was guessed from a path, where no import in the tree names the declaring module (a
build that renames its module would otherwise drop every importer), or, from a module importing something the
tree does not declare, a tree module no import names that holds no test file, or from a test module importing no tree module at all (an Xcode target can compile a file shared with another target and need no import for it, and the index records that file under one target only). Measured on this repository
with no store, a change to the MCP or CLI module listed a fifth to two fifths of its tests from the core
module's test target, which cannot import either. The set-aside tests are counted and their targets named under
the fallback's note, so a reach the imports rule out reads differently from no match. **A test is recognised by shape, from indexed rows**, not from a
manifest, which would cover one of three build systems. And **both runners' spellings, never a truncated
flag list**: a target with more affected tests than the list prints is named whole, because a partial flag
list looks complete when pasted. Under it the answer lists that target's affected suites, built from every
affected test in the target rather than the printed ones, each with its test count and the `--filter` that
selects it, so a narrower run can be assembled without a second lookup. The list stops at 40 suites and
counts the rest, and never folds into one pasteable line, which past the cap would be the partial flag list
again; tests declared outside any suite, and tests in a nested XCTest case, have no suite filter, so they are
left out of it and counted. It carries no `-only-testing:` spelling, as no per-test line does. An XCTest test is named under every case `run`'s inventory declares as
running it — each subclass inheriting it, never a generic base. A test in a nested XCTest case, which on macOS
no `swift test` filter selects, is left out of that filter, counted, and said to be selectable only by an
unfiltered run; its `-only-testing:` argument names the case by its mangled runtime class name
(`_TtCO8LibTests10ChoreTasks9LampTests`), the one spelling `xcodebuild` ran it by on macOS, and leaves it out,
counted too, where an enclosing type is declared by an extension or is private, since then that name cannot be spelt.
A Swift Testing test is spelt as `swift test list` prints it, measured with SwiftPM 6.4 and `xcodebuild` on
macOS: a file-scope `@Test` is `Module.f()` to `swift test` (a slash ran nothing and exited 0) and
`Module/f()` to `-only-testing:`, and a nested suite is slash-separated in both, `Module.Outer/Inner/f()`
and `Module/Outer/Inner/f()`, since the dotted `Outer.Inner` ran nothing in either.

A lone `--from X` reads `X..HEAD`, the way `git diff X` does, and so differs from `sift diff X`, which reads that
commit's own change against its parent; the help names both and gives `--from X~1 --to X` as the spelling of the
second. Each target's count, like the headline's, is the sum of what its rows stand for, a whole suite being every
test the inventory declares in it, of either style: the inventory is read whenever a whole suite is reached, not
only for an XCTest case. A Swift Testing suite also stands for the suites nested in it, whose ids its filter and
`-only-testing:` path prefix, so their tests count toward it and a nested test or suite it runs folds into its row
rather than being listed (and counted) beside it; an XCTest case stands for its own tests only, since a case nested
in it is a class of its own. A target past the per-test cap counts that way on all three of its lines (its own,
the line naming it whole, and the truncation line, which counts what the rows past the cap stand for); the cap
itself is on rows. A changed file the index no longer holds (renamed or deleted since the range) is
listed as no longer in the working tree rather than as one that declares nothing.

The lists stop at their caps, so `--reached <name>` (CLI only, additive) reads the whole reached set instead and
answers under the list for that one name: every reached entry whose spelling contains it, with its hops and where
it was found; a member of a suite reached whole, which the list prints as the suite alone, answered from the
inventory (the tests that suite runs, nested Swift Testing suites included), matched by a fragment of either its
listed or its dotted spelling, and said to be run by that suite, and a
name under such a suite that the inventory does not list said to be no known test rather than covered; and for a name
never reached "not reached within N hops", which is not evidence that it is unaffected. Matches are capped at the
per-test cap and the rest counted. The option repeats: the answer carries one such block per name, in the order
given, and a name given twice is answered once.

### `diff [<range>] [--member <Type.member>] [--offset N]`

A structural digest of a change, for review, in place of the raw `git diff`: which declarations a range
added, removed, changed, or moved, with before → after signatures and the after-side line range on each;
what changed outside every declaration; who calls the members whose signature changed or that were removed;
the test names it added, removed, and changed; the tests reaching the changed files; and every other file it
touched, with its line counts. A reviewer's largest single read is the raw diff, and most of it is body text
the reviewer has to read anyway — the saving is in not re-deriving *which* declarations changed and *how
their signatures changed* by eye first, the same locate-then-read loop `digest` already shortens for source.

**The overriding rule: every change in the range is visible in the answer.** A review tool that says
"unchanged" about a change is worse than no tool, because its reader never looks. So every touched file
appears — a Swift file broken down, a Swift file the index never holds listed with its line counts and the
rule that keeps it out, anything else listed with its line counts — and a Swift file whose change falls
outside every declaration is listed with what changed there. A file deleted in the index but still on disk
(`git rm --cached`) is one file, listed once, with the counts of its two sides rather than git's deletion.

**The line diff is the safety net under the breakdown.** Each broken-down file's two sides are also diffed
line by line, as bytes — git's default algorithm, Myers', bounded so a pathological pair costs a hunk rather
than time — and every hunk must meet a line the answer names: a declaration's range (a type matched on both
sides answers only for its own lines, its header and its closing brace), or the lines of a named text outside
the declarations. A hunk nothing meets is named for what its bytes say — whitespace only, line endings, the
same characters in another Unicode normalization — or, failing that, listed as `other changes at lines a–b
(not broken down)`. Two cases are named by the breakdown rather than left to the net: a type whose header or
closing brace moved, so that what it holds changed, and a byte-order mark added or taken away, named once for
the file. One case is set aside: a declaration present on both sides whose lines are byte for byte the same
and whose place among its siblings did not change has not changed, whichever of two equally short alignments
a line diff happened to show it in. Nothing git sees as changed goes without a line in the answer, and "the
content is unchanged" is decided on the bytes, never on decoded text.

**`<range>` is a single commit, `A..B`, `A...B`, or omitted.** A single commit (or `X^!`, git's own spelling
of the same thing) is read as *that commit's own change*, against its first parent — "review this commit" is
what a bare commit argument means to a reviewer, not "diff it against my dirty working tree". For a merge
that is the change the merge brought to the branch it landed on, which is not the combined diff `git show`
prints for one, and the answer says so. A root commit has no parent to name, so it compares against git's
own empty-tree object: every declaration in it reads as added. `A..B` compares the two revisions named, in
that order. `A...B` means what it means to git: `B` against the merge-base of the two, so a branch is
reviewed for what *it* did, never for what the other side did since they parted — the `diff:` line names
the merge-base it used. **Omitted, it reads exactly as `affected`'s own omitted range does — the working
tree against `HEAD`, untracked files included** — so a bare `sift diff` and a bare `sift affected` agree on
what "the change" is. Anything else is refused in this tool's own words, naming a spelling that works: a
range with an empty side (`HEAD~1..`, `..feature` — git would fill in `HEAD`, which is a guess about what
was meant) and a name that resolves to no commit. Handing either to git would fail with its whole usage text,
or name an object the caller never typed — and never suggests a spelling that would compare a commit with
itself, which is what filling in `HEAD` gives when the other side is `HEAD` too. A refusal exits nonzero, so a
script can tell it from an empty change, and is decided before the index is brought up to date: it reads
nothing stored, so it does not pay for refreshing it, and its header names the tree and nothing else.

**Parsing never touches the persisted index.** The index holds one snapshot of the current working tree,
which cannot answer for an arbitrary historical revision; instead each side of each touched file is read
directly — every blob of a batch of files through one `git cat-file --batch`, or the file on disk when the
near side is the working tree — and parsed with the same visitor the indexer uses, one file at a time, its
tree discarded before the next and its sources discarded once the two sides are compared. The
carved-in-stone rule holds here exactly as it holds for the stored index. Only Swift files the index would
hold are broken down; a manifest, a vendored or hidden path, and a file this repository's own `.sift.json`
narrows away are listed, not parsed.

**Declarations are paired by name and kind at each nesting level, strongest evidence first.** An extension's
key is its whole header — conformances and `where` clause — since two `extension Array` blocks with
different clauses are different containers that happen to share a name. Within one key, identical text pairs
first, then an identical signature, then (for a container) the most members in common, then the same `#if`
branch, and only then source order — with, at every step, the candidate whose first line the line diff kept
winning a tie, so of two identical `var size = 0` the one that was there before is the one paired: pairing by
position alone is how an extension inserted above two same-named ones turns an untouched member into a
removal, and an overload that lost its sibling into a claimed change from one to the other. A type left with
exactly one unpaired extension on each side had that extension's header edited — `extension W` becoming
`public extension W` — and the two pair as one header change, its members compared rather than hidden inside
a removal and an addition; a member whose effective access level moved says so. A container present on both
sides recurses — its own line is a change only when its signature or its `#if` condition differs, or where it
opens or closes moved, and its members are diffed independently and grouped under its path (an extension's
heading always says it is one, with its clause); a container present on only one side is one
`added`/`removed` entry, not its members enumerated one by one, because "a new type showed up" is the fact
that matters here and `sift digest` already answers "what does it hold". Two sides sharing a name but not a
kind read as a removal plus an addition, never as a claimed change between two different things. A pair
whose place among its siblings changed and whose text did not reads as *moved* — the elements of one
`case a, b` or `let a = 1, b = 2` ordered by their place in it, since they share a line and a column — and
"text unchanged" is said of a move only when its whole lines, every descendant of a moved type included, are
byte for byte what they were. This is a different
resolution rule from `affected`'s own "a changed file resolves to every declaration in it": that policy
exists because under-counting a reference walk drops a test that should have run, where here the whole point
is precision.

**A declaration is compared by its own text** — first token to last, as the parser read it, with no doc
comment above it and no comment trailing its closing brace; for one binding of several (`let a = 1, b = 2`)
or one case of several, only its own part. Text is compared as bytes, the way git compares it — Swift's own
string equality calls a composed and a decomposed `é` the same — with one fold: `\r\n` and `\n` compare
equal, so a line-ending conversion is named once, as that, rather than as every multi-line body changing.
Signatures are compared whole and cut only for display — an edit past the cut shows both sides from shortly
before the first difference — and a protocol requirement's accessors (`{ get }` becoming `{ get set }`) are
part of its signature. An edit anywhere in that text reports the declaration as changed, with the note that
its signature did not move rather than an arrow to itself. **Everything else is sorted by what a reviewer
would call it**, in an `outside declarations` block under the file: imports (named by module, so an
attribute gained reads as one edit), `#if`/`#elseif`/`#else`/`#endif` lines, comments and doc comments — the
ones in front of a type or an extension included: its doc comment, a licence header, a `// MARK:` — top-level
code, a `deinit` (by its type), a freestanding macro such as `#Preview` (by its name), and any text nothing
else claims. Which of them changed is read off the line diff, with every line they span, so a comment edit
is named at the lines git shows it at and a moved one as removed there and added here. Whitespace, line
endings and the rest the net names sit under `line changes`. Every line is listed, adjacent ones merged into
ranges, and never cut to a count — a line the answer does not print is a change the reader cannot find.
Same-named declarations under different `#if` branches each carry their condition, and a condition that
changed around an untouched declaration is that declaration's change (Docs/AnswerContract.md §6).

**One member's before and after body is `--member <Type.member>`**, addressed the same way `digest`
addresses one, rather than a second positional next to the range — a bare `sift diff <member>` with no
range would otherwise be unable to tell "the member" from "the range" when both are just strings. It
answers only from what the range actually changed; naming something the range left untouched refuses rather
than guessing which of its unchanged sides to show. A label several changed declarations share is refused
with each one's exact address — `<path>#<Type.member>:<line>`, or `…:before:<line>` for a removed one — and
the heading it sits under where that is an extension, since two extensions of one type share a dotted path;
every address listed is accepted back as written, so the refusal is retryable (§5 of the contract). While the
range is compared, only the bodies of the declarations the argument names are kept — never every body in it.

**Test names are shape-only, and say so.** A file importing `Testing` or `XCTest` is a test file; a
function carrying `@Test`, or named `test…` in an XCTest file, is a test — the same shape `where`/
`affected` use, minus their cross-file walk to a base class declared elsewhere, since this parses only the
two revisions of the files the range itself touches. A wholly added or removed test file or suite still
names its individual tests here, even though the declarations section reports it as one line.

**Two sections answer "what might this break", each named for exactly what it holds.** *Callers* are listed
for each member whose signature or effective access changed or that was removed, through the machinery
`where` uses: resolved by the index store where the store can answer for the declaration today — among
overloads sharing a labeled name, the one at the declaration's own line, never simply the first —
name-matched over the working tree otherwise, and every member says which, and why. A removed member is
always name-matched: it has no declaration left to resolve, and what still spells its name is what the
removal may have broken. Both read
the working tree as it stands, and the heading says whether that is the range's after side. *Tests reaching
the changed files* come from `affected` over the same change set — every declaration in each changed file,
not only the changed lines — listed briefly, with a pointer to the `sift affected` invocation whose answer
carries its limits and the runner arguments, rather than embedding that answer whole: its fixed block would
otherwise outweigh most small changes several times over.

**Bounded, and nothing cut silently.** The declarations section pages on the codebase's own cursor —
`truncated: N more declaration entries across M files — pass --offset K` — and the lists after it (test
names, files, callers, tests) are capped with the count of what they left out. A page past the first carries
only declarations, says it is a continuation — which page of how many — and where the rest is.

**CLI only**, on `affected`'s and `run`'s reasoning — a range review is invoked from a shell, and an MCP
tool's description is paid for in every session's context whether or not that session calls it.

**The answer prices itself against the raw `git diff` for the same range**, as every other surface prices a
saving: `~N tokens saved` at four bytes a token (`TokenEstimate`, a fixed estimate), with the bytes both ways and the
ratio beside it (Docs/AnswerContract.md §4). The whole answer is counted, once, on the first page — header,
notes, the size line itself, and every later page as `--offset` will serve it — and no later page states a
saving: sixteen pages each claiming the whole saving against the whole raw diff would count it sixteen times.
In working-tree mode the baseline includes the untracked files the answer covers, counted as exactly the
added-file diff git prints for them, down to its marker for a last line with no newline. An answer larger
than the raw diff says so plainly rather than as a negative percentage: a small change's fixed cost can
outweigh its raw diff, and this command earns its keep on real changes, not trivial ones.

### `report`

One self-contained HTML file, written, named and opened, from what already accumulates: the usage log,
this machine's run records, its Claude Code transcripts — the index's share of Swift lookups is read
from those, as `audit` reads it (§4) — and a read-only probe of the known roots. Nothing is collected
for it and nothing is fetched by it — inline styles, hand-rolled bars, no script, no daemon, no network.
It leads with the conditions awaiting a person, and when nothing holds that section renders as *nothing
at all* rather than an empty heading, because a standing "all clear" panel trains the eye to skip the
place the real thing will appear. Below it, **numbers that can go down lead and counters come last**,
since a call counter only rises and reads as adoption whatever the truth is.

**The transcript sweep keeps one thing between runs: each transcript's counts**, in
`~/.sift/transcript-tallies.json` (`TranscriptTallyCache`), because a 30-day window reads about 3 GB at
the speed of a JSON parse per line (six minutes measured) and nearly all of it is the bytes the last report
read. An entry holds the transcript's tally and its per-day slices (nothing for a context that made no Swift
lookup), keyed by path, size and modification date as the snapshot read them; **the path is stored as a
hash**, so the file holds counts and dates and never the project directory or session a transcript's path
spells out. The file's header names the
format, the time zone the days were dated in, and the running binary's inode and mtime, so every install
or rebuild starts it empty: a scanner change never reads a count the old scanner made. The window is
stored as far as it reached into the file: a scan whose window opened at or before the earliest line it
judged is stored without one and stands for every such window, so a sliding `30d` re-reads only the
transcripts that straddle its start. A transcript keeps up to four such scans, one per window start, newest
kept, so alternating `7d` and `30d` reads a transcript straddling either start once, not on every switch. A
changed transcript is read again. **An entry is dropped when no later sweep should read it**: one the
window covers whose transcript the sweep did not list (the sweep lists every transcript last written inside
its window, so it is gone), and one whose transcript was last written more than **90 days** ago and before the
window's start — three times the widest window a report is usually asked for, so `30d` never misses for
want of an entry, while the file stays bounded however long Claude Code keeps transcripts. A window wider
than that keeps what it reads until a narrower one runs. Pruning costs speed only, never a number: a
dropped entry is read again. A deleted transcript outside the window is dropped once it ages out, and two
`--projects` directories sharing one cache prune each other's entries inside the window. A file that
cannot be read or decoded, or was written in an earlier format, holds nothing and is rewritten, never an
error. The file is written whole, temporary file then rename, only when something changed; two reports at
once leave one copy, never a mix. What a scan asked the disk (the floor, whether an index could answer a
name, the hook's suppression log) is held as it was answered when the transcript was first read, which is
nearer the session than a later re-read would be. `audit`, its replay and `scan-diff` never read it.
Progress goes to stderr only on a terminal or with `--progress`.

**`--root` narrows every section together, transcripts included.** A logged call is scoped by the `root`
field it was written with; a transcript carries no such field, so it is scoped by its recorded `cwd`
instead — the first `cwd` among its opening lines decides, and any later one is not consulted, because
a session is scoped by where it began rather than by everywhere it went — and counted toward the root
only when that `cwd` is the root itself or a directory beneath it,
canonically compared so a differently-cased or symlinked spelling still matches. A transcript whose
opening lines name no `cwd` cannot be placed and is left out of a scoped share. Each transcript is scoped
on its own, a subagent's included: an agent dispatched into the root from a session started outside it
counts toward the root, and its parent does not. `--projects` follows a symlinked project directory
rather than skipping it, through the filesystem's own symlink resolution rather than a hand-rolled walk,
so a symlink cycle is refused there and never becomes a loop here; and a symlinked transcript is dated
by its target, since the link's own date is when the link was made.

### `rename <old> <new>` — specified, not built

The only write tool, if it is built; no `sift rename` exists. **The freshness contract hardens here: reads
degrade gracefully, edits must not.** It refuses entirely, all or nothing, if any occurrence file is stale
against the store or dirty in the working tree, and there is **no name-matched textual fallback** when the
store is absent, because what is honest for a *listing* is reckless for an *edit*. Application is plan then
write: phase one verifies that the bytes at every resolved location spell the old name, phase two writes, and
the answer reports the **unswept remainder**, every spelling the store could not vouch for. Base identifiers
only (labels move at different token positions). **A specified-but-unbuilt feature is the worst state a
design can hold**: either it gets built, or this section is cut.

## 4. The MCP surface

The server exposes **four tools — `digest`, `where`, `search`, `strings`** — and nothing else. Lifecycle
is a human concern, write tools do not belong on a query surface, and the wrapping commands are reached
through a shell; every exposed tool costs description tokens in every session, including every session it
is not used in. **Each is marked to load with the tool list** (`_meta` `anthropic/alwaysLoad`): Claude Code
otherwise defers an MCP tool behind a `ToolSearch`, so the model holds a bare name, reads none of the
description, and pays a turn to load the schema before the first call — one step behind a `Read` already in
the list, which is the comparison the tool loses. That price is the one this section already set, about 1k
tokens of schema in every session. The mark is set only where the session-start primer would speak (at or
under an indexed root, above indexed roots, or in a repository with Swift sources, read from the server's
working directory at startup, or from an explicit `--root`), so a registration at user scope costs nothing in a session without Swift:
there the tools are deferred to their names. Deferring them in a Swift session was measured and refused (Claude
Code 2.1.286, a one-turn `-p` probe): where the session's tool list leaves out `ToolSearch` the unmarked tools
load in full anyway, and where it carries it the deferred four still cost about 750 tokens against about
1.4k loaded, a saving smaller than the turn it adds before the first `digest`. **The schema is kept to a
budget instead** (`ToolDefinitionBudgetTests`): every tool and parameter stays, each description is its
trigger and nothing the model can infer, and the serialized list must stay under 2,600 bytes. **Descriptions are load-bearing and are phrased as trigger conditions, not as features**:
a tool the model never invokes is worth nothing, and a description saying what a tool *can do* loses to
the read the caller already knows how to do. A size precondition ("before reading any file over 100
lines") is unusable too, since it cannot be checked without doing the read it exists to prevent, while an
intent trigger can be evaluated before acting. **Output is plain compact text, no JSON envelope**, because
JSON wrapping burns the tokens the tool exists to save. **Startup must be instant**: a stdio server has a
startup timeout, so the server never indexes during `initialize` — indexing happens inside the *first tool
call*, since a cold parse of even a very large tree sits far inside the tool-call timeout.

**Root resolution is per query, not per registration.** A frozen root breaks two ordinary setups: a
worktree whose session is not the checkout the server was registered in, and a session rooted above
several repositories at once. Every opened root is recorded best-effort in a per-user registry — pruned of
vanished paths, corrupt-reads-as-empty, every failure swallowed — except a root under a temporary
directory, which is scratch work by construction. It feeds two answers. A rootless query outside any
repository **picks the root itself** where the registry can settle it — the one indexed root that
declares the name, else extends it, or records the file path asked for, preferring among several the one
inside the caller's folder; failing any match, the sole indexed repository under that folder — and names
the root it picked on a line under the header. Only a tie, or nothing to go on, still refuses, and then it
**teaches the fix** by listing the roots to pass — just the tied ones, where it is a tie — instead of
refusing in a way the model can only escape by guessing. And a name miss inside one repository consults
the siblings and offers a pointer to the root that declares it — deliberately **not** a proxy answer,
because serving a sibling's digest would put another repository's content under this repository's
freshness header. Probing is read-only by construction, so a root recorded but never indexed is skipped
rather than indexed as a side effect of someone else's miss: this is routing, not indexing, and §1's
boundary holds.

**A root's identity never outlives the call that resolved it.** The same path can answer for a
different repository from one query to the next — a worktree torn down and re-created at the same
path is exactly that — so nothing about *what repository a root belongs to* is cached across calls.
Within a single call, a memo lets repeated questions about the same root spawn `git` at most once
while an answer for it is known, and a failed resolution is never one of the things remembered: a
root git cannot currently answer for is asked about again on every retry, never assumed to still be
unanswerable next time.

**Per query is only as good as the query, and the caller cannot state what it does not know.** The
resolution above runs on the `root:` a call carries, and a call that carries none falls back to the
server's own launch directory — so on its own it does not cover the worktree case above for the MCP face.
A subagent shares its parent's server, so a rootless `digest` from a worktree agent is answered with the
*parent checkout's* file, line ranges and dirty count, and nothing in the answer says so. **This is the
worst class of failure the tool has — not a missing answer, a confidently wrong one** — and it is
invisible from the content, because a worktree and its checkout share `head:` and hold the same symbol
names. The sibling self-heal never fires either: it is triggered by a symbol being *absent*, which between
a checkout and its own worktree never happens. So the discriminator has to be the path, and the only place
the caller's path appears is the `PreToolUse` payload's `cwd`. The hook fills the argument in: an index
call with no `root:` from a directory inside a repository is amended to name that repository, resolved by
`rev-parse --show-toplevel`, which in a linked worktree names the worktree and not the common directory.
**Supplied rather than refused**, which is the one departure from the Answer Contract's §5. §5 governs an
answer that cannot be given honestly and refuses instead of guessing; there is nothing to guess here,
since the caller's working directory is a fact in the payload and resolves to exactly one root. A refusal
would also have to learn the server's root from somewhere in order to know when to fire, and would end
with the caller re-sending an argument the hook could have added. A stated `root:` always wins, a `cwd`
inside no repository is left alone so the rootless self-heal above still runs, and `updatedInput` is sent
without a `permissionDecision`, so a hook that meant to add one argument does not also approve every call
it sees. Where the hook is not installed, the header is the backstop: it names the tree.

**The amendment is sent only where it can change the answer.** Claude Code's auto mode judges a rewritten
call as a new one, and on 2.1.289 refused one rootless sift call in seven for want of a verdict on the
rewrite, while no call that already named its root was refused. So the hook looks up where the server
answering its caller runs rather than inferring it. Every `sift mcp` writes a `start` line to the server
lifecycle log (`~/.sift/server.jsonl`, or the file `SIFT_SERVER_LOG` names) with its pid, the directory it
was launched in, the session in its environment and its `parent`, the process that spawned it. The harness
that spawned the server also runs the hook, so that parent is one of the hook's own ancestors: Claude Code's
server is a child of the `claude` process, and the hook is a child of the same process, or of a shell it
starts. The hook reads the log once per index call and walks its own ancestors, closest first and at most
four deep, never counting pid 1 (launchd is everyone's ancestor, and a server whose parent watch found
nothing to arm records `1`). The walk passes through shells (a closed list of kernel process names: `sh`,
`bash`, `zsh` and their kind; macOS's `/bin/sh` is named `bash`) and ends with the first ancestor that is
none, which is still asked for a server: that is the harness running the hook, and past it lies whatever
started the harness. A second harness started from Claude Code's Bash tool, with no server of its own on
record, would otherwise walk on through the outer Bash tool's shell to the outer `claude` and take its
server, which answers some other tree. The harness cannot be recognised by name instead: Claude Code's
process is named for its version (`2.1.292`), and a harness with no start line records nothing about
itself. A process whose name the kernel will not give counts as no shell, so the walk ends there too. It takes the closest ancestor that is the recorded parent of a live server,
and of that ancestor's servers the newest; live means the pid is still held by the process that wrote the
line and is still that ancestor's child. The session is not the key, because it does not identify the
server: after `/clear` Claude Code gives the conversation a new session id and keeps the running server,
whose line carries the old one, and a `sift mcp` an agent starts from Bash inherits the session while
another server answers. Such a server's parent is the Bash tool's shell, never one of the hook's ancestors,
so it is never taken; one the shell `exec`s in place records the harness itself as its parent, so where an
ancestor's live servers record different launch directories the hook cannot tell which answers and amends. Only where no ancestor matches is the session consulted, and then only for a start
line that records no parent at all, written before the field existed. The server answers a call with no
root from the git top level of its launch directory, so a caller whose own top level is that same tree is
already answered from it, and the hook prints nothing. The comparison is like with like, so it holds in a
linked worktree as much as in a main checkout: the old main-checkout condition, which existed because a
project directory said nothing certain about where the server ran, is gone. A subagent's hook runs under
the same `claude` as its parent's and the subagent shares its parent's server, so its call is compared with
that server's root. Everything the log cannot settle is amended as before, under every harness alike: no
live server under any ancestor, a pid that has exited or been reused, a log that cannot be read, a launch
directory in no repository. A live server's start line is kept when the log is trimmed (below), so a
session that runs for days keeps its record. This replaces an inference from `CLAUDE_PROJECT_DIR`, which
the hook no longer reads: Codex runs the same registration with no `--agent`, so a Codex hook that
inherited a stale project directory left a caller in that directory unpinned while its server answered
from another tree, with nothing to say so. One answer does differ when the call is left
alone: a rootless `search` whose query carries an inline `root:` term is now answered from that root, which
the hook's own `root:` used to override. The hook counts such a term as a stated root everywhere it reads a
call's root (the amendment and the ledger's note of the call's root), with the argument still beating it. Whether `permissionDecision: "allow"` beside
`updatedInput` would change the classifier's verdict is untested: it would also approve every call the hook
amends, which the paragraph above rules out.

**A root the caller names is never swapped for another tree.** Sift indexes a git work tree, so a `--root` /
`root:` that is inside none is outside its scope, and the answer is a one-line refusal naming the folder
(`<folder> is not a git work tree …`, `EngineError.notAGitWorkTree`). The self-heal above is for a call that
named *nothing*; applied to a named folder it answered `where Depot --root ~/Scratch/plain` from whichever
indexed repository declared `Depot`, with only a note to say so. `RootResolver.resolve`, told the folder was named,
therefore considers only the indexed roots *under* a named folder (the container case, `Orchard/` holding
`app/` and `web/`, still resolves) and refuses when none does. Every verb takes its root through
`RootOptions.makeEngine`, and the MCP face says so when the call carries `root:`.
`CLINamedRootTests` pins it through the built binary.

**A call is attributed to the context that made it, which the server cannot see on its own.** A subagent
shares its parent's server, `tools/call` carries nothing naming the caller, and the only conversation
identity in the server's environment is the session — which a subagent's calls arrive under exactly as its
parent's do, so without help no logged call can be attributed to a subagent, and the tool cannot evidence
the criterion it is judged on: whether it works for them. The hook payload *does* name the agent, and the
hook already fires on this server's own tools, so it leaves a slip naming the caller, the tool and the
target, and the server claims it when it logs the answer. **Every call gets a slip of its own, and a slip
is claimed only by a call of the shape it names** — the server takes the oldest unexpired slip whose tool
and target match what it answered, and leaves every other for the call it belongs to. A slip per session
would not do: several contexts under one session can have calls in flight at once, and a slip the next
hook run could overwrite leaves the earlier call logged with no agent, invisible to every reader that goes
by a line's agent. A parent's call writes a slip too, carrying no agent, so it has one of its own to claim.
**A lookup through the CLI is attributed the same way, in a namespace of its own.** The hook sees the
agent on the Bash call that runs `sift where …`, before the subcommand starts, so it leaves a slip for each
`digest`, `where`, `search` or `strings` the command invokes, filed under the face `cli` and named by the
words after the binary as the shell will hand them over; the subcommand claims the slip that matches its
own argv under its session. The face is what makes it safe: no server tool is named `cli`, so a CLI lookup
can never take the slip of an MCP call in flight, nor an MCP call a CLI lookup's. A command whose words the
shell rewrites before the binary sees them — a variable, a glob — or one that runs past the claim window
before it reaches `sift`, leaves a slip nobody claims and a line without the field, as every failure here does.
**A claim is atomic**: the server renames the slip to a name of its own before reading it, and a rename
succeeds for exactly one claimant, so two same-shaped calls answered at once never both take one slip and
the loser moves on to the next rather than leaving it unclaimed. **Shape is not identity, though, and the difference is stated rather than glossed**: tool and
target are all there is to match on, and nothing shared between the hook run and the `tools/call` could
tell two `digest SummaryState` calls apart, so two contexts making that call at once may each be logged
under the other's name, and a slip left by a call that never happened can be claimed by a later call of
its shape inside the two-minute window — the claim is about the aggregate and never about a given line.
**A shell short-circuit files the same kind of stray slip.** `false && sift where A` leaves a slip for a lookup the shell never starts, and `sift where A && sift digest B` files `digest B`'s slip whether or not `A` succeeded, both expiring unclaimed after the window. This stays unfixed: skipping a `sift` statement whose predecessor could have failed also skipped `cd /work && sift digest X`, the commonest shape a subagent writes, trading a rare mis-attribution for a common non-attribution.
Nothing about it is load-bearing: every failure is silent and
leaves the entry without the field. That is also why the figure it supports is a **floor**: absent means
only "not attributed to a subagent", covering the session's own calls, a machine with no hook, and lines
older than their face's naming of callers — every CLI lookup logged before the CLI claimed slips among
them — in one undifferentiated remainder, which the wording names rather than partitions.

**A call the server can read is not refused for its spelling.** A Swift name sent under another tool's
key for it — `query:` to `digest`, `target:` to `where` — is read, with a line saying so, for the two
tools whose argument *is* a name, and so is one sent to `digest` under `type:`, the word for what it names. Two more keys are read by what they carry rather than by name shape:
a `path:` sent to `digest` is read as the file `target:` would have named, and a `text:` sent to
`strings` is read as the display text `query:` would have searched for, a whole phrase included.
`search`'s argument is a real query language, where a bare name means something else, and a missing one
still refuses; misspelt words inside one are read as `search` describes. A `root:` term written inside a `search` query is lifted into the root argument, a stated one
still winning. A call read either way is logged and scored as the call it became — the usage log, the
transcript audit's failure rows and the files its tally counts as located all read the call through the
one resolution the server answers from, so no surface can name it differently from another — and
attributed by the call as it was sent: the hook left its slip from the arguments before the server healed anything, so claiming it
with the healed ones would name a different target from the slip's and leave the subagent that made the
call unnamed. Every one of those surfaces names a call by the key its own tool reads first, and credits a
located file from that key alone: `strings symbol:"Engine" text:"Save changes"` searched for "Save
changes", and `where symbol:A target:B` resolved A, so another key sent beside it names a call that was
never answered. Two states of the process itself are caught rather than served through: a cached engine whose
database file has gone — a `.sift/` removed by `reset` or a `git clean`, recognised by device and inode —
is reopened, which reindexes, instead of answering `SQLITE_IOERR` for the rest of the session; and a
binary replaced on disk under a running server is taken over in place between two requests (below,
*Picking up a replaced binary*). Only where that cannot happen does every answer carry a notice under its
header, since the process then goes on executing the superseded code until something restarts it.

**There are two per-user logs, and the distinction is the point**: one records index lookups — every face's,
the server's, the hook's and the CLI's — one records wrapped toolchain runs. Neither folds into the other — a build is not a lookup, so a run in the
lookup log would silently restate existing numbers, and a lookup in the run log would make a suppression
ratio meaningless. Both are best-effort and share one appender so they cannot drift, and a failure is
swallowed after one note on stderr, because a log may never touch the protocol stream. An answered call
records the bytes it served; the source it stood in for is recorded only where both sides were genuinely
counted, never for a lookup standing in for a grep nobody ran and nobody can size. **No source size is
ever modelled** — a file count times an average would make the saving unfalsifiable, the one thing a
savings figure must not be — and a savings line states how many calls it was measured over, so a partial
aggregate is never read as a total. **Each line names the repository its answer was computed against** —
the root the call resolved to, not the directory it named and not the server's launch directory. A
rootless call from a session above its repositories is answered from whichever one declares the name, and
a call naming a folder inside a repository is answered from that repository, so logging the request would
file the call under a directory that answered nothing; every per-repository figure, and the hook's check
for a file already digested, reads this field. A call refused before any repository was settled names the
directory it asked about, since there is no other.

### Server lifecycle, and the orphan question

**A third log records the server's own life** — `~/.sift/server.jsonl`, one line when a server starts, one
when it replaces its own image with a new binary (below, *Picking up a replaced binary*), and one when it
stops, carrying the reason (`SIFT_SERVER_LOG` names another file, so a test can watch a server without
writing to the record a person reads). It exists because a server can drop mid-session — a crash,
a timeout, a `pkill` meant for something else — and `usage.jsonl` stops dead at the moment of a drop,
which makes it a witness to *when* and never to *why*. Bounded to 400 entries, because a long-lived
process may not grow a file without limit; past that it is cut back to the newest 200, which on a busy
day is little more than a day of history. The cut keeps the start line of every server still running
(one per pid), because the `PreToolUse` hook finds the server answering its caller by that line, and a
session can outlast a day. The bound holds, since only so many servers run at once. `SIGTERM`, `SIGINT` and `SIGHUP` are caught and recorded before
the process exits `128+n`; `SIGKILL` cannot be caught by anything, and is exactly the shape `sift status`
reads as a start with no stop whose process is gone. **Exactly one stop is recorded per start**, whichever
path reaches it first, so a signal landing as the client hangs up cannot leave one start with two stops
that disagree.

**A drop costs more than the server, and it cannot be recovered from the server's side.** Claude Code, the host
this is built against, documents none of this and may change it: after a stdio server died mid-session, the
main conversation lost the tools and later subagents were told the server had failed to connect, so a drop has
to be prevented. **No ending the server chooses happens while its client is there**: its input closing, its
output failing and its parent dying each need the client gone, and an ordinary session end arrives as
`SIGINT`, read as a session closing. What else ends one is a signal from outside or a crash, which this log
cannot tell from a `SIGKILL`. Every server's command line is `sift mcp`, so `pkill -f 'sift mcp'` ends all of
them, and BSD `pkill` reads a trailing option as a second pattern, widening the kill. **A server is stopped by
its pid, or through `sift servers --stop`, never by a pattern.**

**Catching a signal must not make a wedged server harder to kill, and that constrains how it is caught.**
Ignoring `SIGTERM` so a dispatch source can see it takes away the escape hatch somebody reaches for when a
server has hung. So the handler is one-shot: before anything that can block, it restores every armed
signal to `SIG_DFL`, and a second `pkill` then kills outright. The residual is stated rather than hidden:
if the queue never runs the handler at all, `SIG_IGN` is never lifted and only `SIGKILL` will end that
process.

**The ledger files are locked, because several processes write them at once by construction** — one server
per session, plus every hook and every wrapped run. Appends go through `O_APPEND` so no seek offset can go
stale, and take an exclusive `flock` so an append cannot land inside the lifecycle log's trim; the trim
rewrites *in place* under the same lock and readers take a shared one, because an atomic replace would put
the bytes on an inode nobody else holds a lock on. **Every one of these locks is bounded and fails open**:
a lock not taken within a quarter of a second is abandoned and the caller proceeds unserialised. (The
advice ledger's lock, below, is the one that waits without a deadline: only another hook process doing
one small read and write can hold it, and a lock that cannot be opened still runs unserialised.) That is
forced by where the appends happen — `MCPServer` records usage between a tool call and its answer, so a
blocking wait would stall every index call in every concurrent session, and `sift status` with them. Losing
serialisation costs at worst an interleaved rewrite of a diagnostic file; waiting costs the tool's purpose.

**Liveness is checked, not assumed, and `sift status` reports only what it checked.** A pid is not an
identity: `kill(pid, 0)` says merely that *something* holds that number, so a recycled pid would let the
tool vouch for a server that died weeks ago. A pid is called running only when the kernel holds a record
for it, that record is **not a zombie** — a process killed but never reaped keeps a valid pid and a valid
start time, which is exactly what a `pkill -9` under a wedged parent leaves behind — and its start time
agrees with the entry's to within 30 seconds. An unclosed start whose process is gone is reported at any
age, filtered only against `kern.boottime`: a start from before the last boot is a machine that went away,
not a server that was killed. That is the question asked exactly rather than by proxy; an age window
would suppress the very case worth seeing — a long-lived server killed a minute ago.

**One property is load-bearing: the process ends when its input does.** A read loop that ends must end
the *process*, and the stream it reads must finish on every path out of its reader thread. A stream that
stops delivering without finishing suspends its consumer forever, and that failure is silent from both
ends at once — the client waits on a response that will never come and reports the tools as gone, while
the process sits alive with the socket still open.

**A server can also outlive its use with nothing wrong with it.** A long-lived server whose client has
gone quiet — socket open, parent alive, main thread parked in the run loop rather than blocked in a read
— still holds a repository's `index.db`, its write-ahead log and an IndexStoreDB lock directory keyed to
its pid, and nothing will speak to it again. **The rule: if the host can clean these up, it must — a
server may not simply be left running.** It resolves to two mechanisms and not one, because a server
whose parent has died and one whose parent is alive but silent are not the same population.

**A server ends when the process that spawned it does.** Parent death is a *fact* — nothing legitimate
holds the other end of a stdio pipe once the process that opened it has exited — which is what separates
it from a policy. `EVFILT_PROC` with `NOTE_EXIT` on the parent pid is the kernel's answer to the question
and a dispatch process source is the ordinary way to ask it, so the handler runs on a queue and writing
the stop line from it is ordinary code. The stop is recorded as `parent-exited`, apart from
`input-closed` on purpose: a client that closes its end is a session ending tidily, and a parent that
dies without closing it is a client that went away without ending anything. **With a second thing that
can end the process, the one-stop claim covers the exit as well as the record**, because two dispatch
sources on one concurrent queue can enter their handlers together — and closing a terminal reaches both
by construction, delivering `SIGHUP` to the foreground group and killing the parent shell in the same
event. Two handlers calling `exit` at once is the hazard the signal watch already names; the loser of the
claim returns instead, since the process is already ending on the thread that won. Two edges are handled
rather than assumed away — a parent that dies in the window before the source is armed is caught by
reading the parent a second time afterwards (a process re-parented away from the pid it was born under has
lost its original), and a process whose parent is already the system arms nothing, because the pid it
would watch is one whose exit it will not live to see. **The first reading comes before the start line**,
and the start line names it: that line is the only sign from outside that a server is up, so a parent
killed once it exists has to be a pid the server already holds. Read after it, the kill lands on a process
that then sees launchd as its parent, takes itself for one with nothing to watch, and runs until something
else ends it. What remains is a parent that dies before the process has read it at all, and the start line
says so: it names pid 1 as the parent, a server nothing is watching.

**Be clear about what that does not catch: a server whose parent is alive.** It catches the other orphan
class — a host that dies, is killed, or crashes without closing the pipe — which is the one that
accumulates across days, and the only one a process can act on without guessing. One residual is stated
rather than hidden: the watched pid is the *parent*, not provably the holder of the pipe, so a client that
spawned the server through a wrapper process that then exited without closing the pipe would end a live
server. Claude Code spawns `sift mcp` directly, and the alternative, waiting for a signal that never
comes, is the state this exists to end.

**For the rest, `sift servers` hands the decision to a person, with the evidence beside it.** `sift status`
sees these; this makes them actionable without making the tool guess. It lists what the lifecycle log
says is running — pid, age, when it last answered anything, and the root it serves — and `--stop` acts
on it. Four rules shape it, and each is there because of a way this could become the very defect it is
meant to avoid:

- **It stops nothing it selected for you.** `--stop` requires `--pid` or `--root`, and a `--root` at or
  above the home directory is **refused**. That second half is not a rail on the rule, it is the rule:
  `/` is a prefix of every absolute path, so one token would select every server on the machine, and
  `$HOME` does the same one level down. In a cron there is no session id to recognise the caller by and
  no shared ancestry with a sibling server, so neither of the other guards is even operative there — what
  would remain is an idle timeout of one person's choosing, run from a cron over every server on the
  machine. Whether servers should end on an idle timeout at all is still open (the last paragraph of this
  section); what this design refuses is to let `servers --stop` settle it for everyone as a side effect,
  a machine-wide policy shipped without ever being decided. A root *below* the home directory stays
  allowed: that is a scope somebody named, and putting it in a cron is a decision made in the open over a
  named place.
- **It changes nothing until `--yes`.** A `--stop` alone prints the plan. The thing being stopped is
  another session's working index, so "would stop" and "stopped" are not left to be inferred from which
  flags were typed.
- **Three kinds of server are never stopped, each named with the evidence that spared it**: one whose
  session id matches the caller's, one in the caller's own process ancestry, and one with a sign of life
  in the last ten minutes. The first guards against a session losing its index to a sweep aimed at
  something else, and a reap run from inside a session is the shortest path to that. The last is the
  newest of a server's start and its last recorded answer, read from `usage.jsonl` and joined to the
  server by session id: reading both closes the hole in reading either, since a session thirty seconds old
  has answered nothing and so has yesterday's corpse. Ten minutes is not deciding when a server is dead —
  nothing here decides that — it is deciding when there is positive evidence one is alive. **A sign of
  life in the future counts as one**, clamped to "now" rather than rejected: a stepped clock makes the age
  negative, which would read as "not recent" and remove the protection entirely, so the *stronger*
  evidence of life would destroy what the weaker alone gives. The listing clamps the same date the same
  way, because a row printing maximal liveness beside a decision to stop the server would show a reader
  the strongest reason to keep it and the tool's intention to kill it, on one line.
- **It signals `SIGTERM`, not `SIGKILL`**, so the server catches it and writes its own stop line, and the
  reap is legible afterwards in the same log every other stop is. Anything the caller asked for that did
  not happen — a guard held it, the kernel refused it, the pid or the **root** was not there — exits
  nonzero, so a script need not parse prose. A root that matched nothing is a finding rather than a
  silence: "nothing to stop" and "stopped everything you named" must not be one answer with one status,
  and a mistyped path is the likeliest way to get the first while believing the second.
- **Every answer opens by naming what it read** — the lifecycle log, and the usage log it took signs of
  life from — and says when either yielded nothing, on all three faces rather than only the listing. Two
  of the three guards rest on files this command can be told which copies of to read, and the third rests
  on an environment variable that may be absent or empty; a caller who cannot be recognised is *about to
  stop things*, and that is the moment to say that the guard which would have spared their own server is
  inoperative, not the one path where nothing happens.

**What is left, stated as a limit.** The lifecycle log only knows servers started since it existed, so an
older one appears in neither mechanism and has to be dealt with by hand. A server started outside a
conversation records no session, so the caller-recognition guard cannot protect it; and a caller whose
own environment does not name its session is told so in every answer, because the guard that would have
protected it is the one that is missing.

**And a session is not one server.** A session can start several servers over its life, all under one
session id, so one live server's activity protects every other server that session ever started. That
errs towards sparing, which is the safe direction — but it means a session cannot reap a server it leaked
itself: its own live server keeps the stale one looking busy, and the caller-recognition guard holds it in
any case. Clearing one of those is a job for a terminal outside the session, where neither guard applies.
The case that remains open is a live parent, an open socket, and a client that will never speak again.
From inside its own pipe this tool cannot tell that from a user at lunch, so nothing here ends it on a
timer: **no idle timeout exists, and whether one should is undecided.** The argument against one is that
a server that exits under a merely slow client — an agent losing its index mid-session for a reason it
cannot see — is a worse bug than one that lingers.

### Picking up a replaced binary

**A binary replaced on disk is taken over in place, between two requests.** A server goes on executing the
code it loaded until something restarts it, and restarting an MCP server is not something an agent can do
from inside its session: the host would have to reconnect it, which in practice means restarting the
session. So an upgrade reached a session only when a person restarted it, and every answer until then
carried a notice asking them to. Instead, before handling each request, the server compares the file at its
own path with the one it loaded — inode and modification time, one `stat` — and where they differ it
replaces its own image with the new file. The pid and the pipes are the ones the client already holds, so
the client sees nothing, and the request that prompted the check is answered by the new code.

- **Only between requests, and the request in hand is handed over, not answered.** It has been read and
  not begun. The input is read one line at a time and only when a line is wanted, so at that moment nothing
  is being read — no `read(2)` is in flight for the exec to destroy — and whatever arrived after the
  request's newline is a buffer the old image holds; both go to the new one. What travels is what lived
  only in the old image's memory: that input, the protocol version agreed at `initialize`, so the client is
  never asked to repeat the handshake, and what the lifecycle log needs — the start time and the parent the
  watch was armed on. It rides in the exec's environment, is taken back out of it before anything can
  inherit it, and names the pid that wrote it, so no other process can take an inherited copy for its own.
- **The new binary is asked first, with the handover itself and the arguments the exec would run.** It is
  run once as a child with this process's own argument vector, a hidden flag (`--read-handover`) appended,
  given the very handover the exec would carry, in the variable it would carry it in, and has to print it
  back as it read it; the running image compares that with what it wrote, field for field. A file still
  being copied, one the kernel will not run (a binary copied over the old inode rather than beside it is
  killed on launch), an older build that has never heard of a handover, a build that reads this layout
  differently from how it was written, and a build that no longer accepts an option the running server was
  started with, all fail that — and exec'd into, each would have ended the session or dropped the request
  it was handed. Asking with a fixed `mcp --read-handover` and nothing else, as this once did, would pass a
  build that broke some other option nobody asked it about, get exec'd, and drop the request it was handed
  the moment real argument parsing ran; a layout number alone would catch even less.
- **`posix_spawn` with `POSIX_SPAWN_SETEXEC`, not `execve`.** It sets the new image's signal state as part
  of the exec: the watched signals at their default but blocked, so one sent while the new image is still
  starting waits for its watch rather than vanishing under the old `SIG_IGN`. The new image reads what is
  pending before it ignores anything, and **reads it on the main thread**, because a signal sent to a
  process whose every thread blocks it is held on the main thread and a thread asking what is pending hears
  only of its own; the read, the ignore and the unblock are made together there. `execve` from the pool
  thread would pass on that thread's mask, which blocks every asynchronous signal. Every descriptor but the
  three standard ones is closed across the exec.
- **The log records a re-exec, not a stop and a start.** The new image writes a `reexec` line and no start
  line: the start line stays the one that opened the process, and it is still what the liveness check
  reads, since an exec keeps the kernel's start time. The parent watch is re-armed on the pid the first
  image read, and its second reading covers a parent that died during the exec. No stop can be written
  while the exec is under way — an ending that arrives is held, and carried out if the exec fails — because
  a stop line followed by a live process would take that server out of `sift status` and `sift servers`
  while it went on serving.
- **Whatever fails leaves the server serving from the old code, with the notice, and what it failed on
  decides when it is tried again.** Serving on is exactly what happened before any of this existed, so it
  is a floor rather than a new way to fail; what must not happen is one unlucky moment costing the session
  its upgrade. A binary that *refused* — would not start, failed, read the handover back differently — is
  not asked again until the file changes, since the same file would answer the same way. A failure that
  says nothing about the file — the question unanswered within its timeout, the exec itself failing — is
  tried again, no sooner than 30 seconds later, the pause doubling with each further failure of the same
  file to at most once every 10 minutes; that bounds how often a probe that keeps failing can hold a request
  up. A request too large to hand over is the third case: an exec carries its arguments and environment in
  `ARG_MAX` bytes, a megabyte on macOS, and the input travels base64-encoded inside JSON, so roughly three
  quarters of a megabyte of request is more than it can carry. That is checked, by the kernel's own
  reckoning, before anything is asked of the binary; the request is answered by the old code and nothing is
  held against the file, so the next ordinary request takes over.

What remains is stated as a limit. **A signal that lands while an exec that then succeeds is under way is
lost.** The old image holds a stop that arrives once it has committed to the exec — or one whose handler had
not run by then — and that image is about to stop existing; the window lasts until the kernel has given the
new image its blocked mask, after which a signal waits for the new image's watch. It is the exec itself, of
the order of a millisecond, and not the new image's startup, which is far longer and is covered. **That millisecond figure is conditioned on the probe having already launched the file**: the first launch of
a never-run binary can take hundreds of milliseconds (macOS's first-launch assessment), which is why the
probe, not the exec, pays it. The sender's next signal lands. **Each takeover strands a copy of the semantic cache until the process ends, and the new
image starts without one.** IndexStoreDB moves the cache under `.sift/isdb` into a working directory named
for the pid while the store is open, and back only when it is closed. The old image's is not closed before
an exec — an open still under way runs on a thread of its own and cannot be stopped, so *that* one could
never be closed on demand; a store that has already finished opening could be, but nothing here does so —
and either way the library's clean-up spares the directory of a pid that is alive, which after an exec it
still is. So the first semantic query after a takeover can answer that the store is still warming, and the
stranded copy takes its size on disk until the server exits. And the check reads the file at the path the
process runs from, so an upgrade that leaves that path as it was — one installed somewhere else — is not
one it can see.

**A probe can outlive the server that asked it.** Nothing signals the probe if the server that spawned it dies
first. One orphaned by a dead server may sit in macOS's first-launch assessment before any of its own code
has run; it cannot watch for anything then, and it exits by itself once it does.

### Wiring into Claude Code

Registering the server makes the tools *available*; it does nothing to make an agent prefer them to
reading a file whole. So the binary also carries the wiring: `session-start`, `pre-tool-use`,
`post-tool-use` and `stop` are subcommands Claude Code runs itself, and `install-hook` / `uninstall-hook` put
them in and take them out. **Three invariants hold across all of them, because a misbehaving hook degrades every
session on the machine**: on the hook path — no flags, whatever the environment — each exits 0, each
prints nothing when it has nothing to say, and nothing any of them does can make a tool call unavailable.

**Registration is a merge done in the binary, not a shell script.** `install-hook` writes the
`SessionStart`, `SubagentStart`, `PreToolUse`, `PostToolUse`, `Stop` and `SubagentStop` entries, and the
allow rules it was told or asked to add, into `~/.claude/settings.json`, and `uninstall-hook` removes
exactly those. Sift draws nothing that is always on screen: the figures are in `sift report`, `sift audit`
and `sift usage`. **A legacy status line or band is removed on install and on uninstall**: a `statusLine`
running `sift statusline` is taken out of the slot (one running anything else is left, unmentioned), and
the `sift-band@sift` plugin with its local `sift` marketplace is taken out through `claude plugin` where the
settings name them, never when `--settings` names another file, and a missing or failing `claude` only
prints the commands to run. That file configures every session
on the machine and this tool did not author it, so: it is copied to `settings.json.bak-sift` before every
rewrite that changes something — so the copy holds the state before the latest rewrite, not the
original, and a `.bak-sift` that is a symlink or not a plain file is named and left, never written
through — an array element of an unexpected shape is carried through verbatim rather than replaced —
casting the whole array and falling back to empty would silently delete hooks this tool never wrote. Doing
this in Swift rather than `jq` or `sed` means one artifact to ship, nothing to depend on being installed,
and the merge rules under test. **Both directions are idempotent**: re-running the install is the upgrade
path, a registration pointing at a moved binary is repointed rather than duplicated, and an uninstall with
nothing to remove says so rather than erroring. **The binary registered is the one that ran, as the shell
found it**: the path it was started by, or for a bare name (the Homebrew caveat's `sift install-hook`) the
first executable of that name in an absolute PATH entry *that resolves (`realpath`) to the running binary*, a link kept as the link — Homebrew's
`/opt/homebrew/bin/sift` survives `brew upgrade`, the Cellar copy it points into does not — else the
process's own executable (also what a PATH hit that is some other `sift` — a relative entry the shell used, a wrapper's bare argv0 — gives way to), and `~/.local/bin/sift` only where none of those resolves. The `claude` lookup in `sift uninstall` is a different binary and is not tied to the running one. `sift uninstall` finds
the binary its last line names by the same lookup without that check (`InvokedBinary`), and only then resolves links, to tell
a Homebrew or npm install from a plain file. Claude Code runs every hook through
`sh -c`, so the path is written shell-quoted (`ShellWord.quoted`) wherever it holds a space or anything
else a shell reads, and bare otherwise; an older unquoted registration of a spaced path is still this
tool's, and a re-run repoints it to the quoted form. A registration is recognised by *shape* — this binary's
name plus the subcommand it runs — which is the only handle the re-install and the uninstall have on a
previous one, so a `--command` outside that shape is refused before a byte is written. The shape is exact:
an executable whose last path component is `sift` (at any path, quoted or not) followed by the subcommand
alone. A command whose path merely contains the name (`/opt/siftscience/x pre-tool-use`) is someone
else's, and both directions leave it alone. `uninstall-hook --only-advice` takes the advice hook alone
and keeps the primer, and an uninstall leaves `~/.sift` exactly where it is and says so: removing the hooks
is not deleting the user's data.

**The primer — `session-start` — is delivery before the fact.** The path-scoped rule this tool ships loads
on contact with a Swift file, one step *after* the read it exists to replace; this hook's output is injected
before the model's first turn instead. It is registered for `SessionStart` on `startup`, `resume`, `clear` and
`compact` (a cleared or compacted context has lost the primer), and for `SubagentStart`, because a subagent
gets neither a session start nor the path-scoped rule and subagents are where the heaviest whole-file reading
happens. It is **silent when there is no Swift in view**, and otherwise says which of three situations the
session is in — inside an indexed root (a repository with a usable index on disk counts, whether or not the
roots registry remembers it), above several (which it lists), or in a Swift repository with no index yet — with a warning when the enclosing root's modules are mostly guesswork, read strictly
read-only so that a session start can never rebuild an index. It leads with reaching for `digest` before
opening a file and closes by naming the CLI as the answer where the MCP tools are missing. **It is the
minimum that does that, under a byte budget** (`SessionPrimerBudgetTests`): it is paid in full by every
session and subagent that starts in Swift, whether or not a lookup follows, so the habits are named in four
lines and the reasons behind them are left to the rule, which arrives with the first `.swift` file, and to
the tool descriptions. A paired benchmark measured the fixed start at +2,452 tokens on the first call (tool
list about 1.4k, primer about 1.1k, the rule nothing until a Swift file is touched). `SessionStart`
injects stdout directly while `SubagentStart` reads a JSON envelope, so the primer is wrapped for one and
plain for the other. **At `SubagentStart`, when the session's server is proven not to be running
(`ServerPresence.isProvenAbsent`), it says first that the tools are not there and the same queries run from
Bash as `sift digest …`, `sift where …`, `sift search …` and `sift strings …`**, because a subagent handed
tool names with nothing behind them spends its first refusals finding that out. Proven means both halves: the
session transcript's latest word on the server is the harness writing it off, *and* no server in the
lifecycle log is still running for that session id or a recorded parent this hook descends from; either alone
can say "absent" about a server that is there. It is never said at `SessionStart`, where the server is being
launched beside the hook and its absence proves nothing yet, and never where the primer is silent. The cost
stays inside the hook's budget: a byte search of the transcript, and the log read only when that search says
the server went away.

**The resumption block is the one thing `session-start` adds beyond the banner, and only for `clear` and
`compact`** — the two moments the conversation's own history was just thrown away; `startup` and `resume`
restore it, and `SubagentStart` carries no such `source`. It is silent wherever the primer is. It states facts
about the working tree and nothing about the conversation that was lost: the branch (or `detached HEAD at
<hash>`); how far `HEAD` has moved from the default branch's merge base and how much of the tree is
uncommitted; the declarations a `sift diff`-style comparison finds changed since that merge base, capped at
ten names with the rest counted; and the last `sift run` recorded for this exact root within the last day,
with its kind, verdict and age. It never carries what the compaction summary already carries.
**Staleness is load-bearing, and it is time-based**: a verdict reads `tree has changed since` whenever
anything that could change what it measured is dated after the run *started* (the record's `ts` less its
`ms`) — `HEAD`'s committer date, the modification time of `HEAD`'s per-worktree reflog, the stash reflog's,
and each dirty file's own. What cannot be dated counts as changed. It compares times, not content, so it errs
stale on purpose, and discarding an uncommitted edit or deleting an untracked file after the run is a blind
spot it does not pretend away. **The whole gather has a wall-clock deadline of 1.5 s**, well inside the
hook's 5 s timeout, and the primer is emitted whether or not it finishes: past the deadline the block is left
out entirely — never a partial one, since a run line without its staleness signals must not appear on its
own. The declaration comparison has its own time, file-count and per-file size bounds, and reaching one drops
to a bare file count with `sift diff` named for the rest. Every fact is gathered independently, so one
gatherer's failure drops only what it was going to say. It reads git, the last 256 KB of the run ledger and
blob content directly, never opens a `SiftEngine` or an `IndexStore` (so a `/clear` can never trigger a
rebuild), and runs every git with `GIT_OPTIONAL_LOCKS=0` so it never holds an `index.lock` another session's
commit could trip on.

**The advice hook — `pre-tool-use` — is delivery *at* the miss, and the only delivery that reaches the
shell at all.** A `grep -n` or `sed -n` on a `.swift` file never opens a file as far as the harness is
concerned, so a path rule never fires for it. It is matched to every tool that can read Swift source —
`Bash`, `Read`, `Grep`, `Glob`, and the Xcode server's `XcodeRead`/`XcodeGrep`/`XcodeGlob` — spelled out
because matchers are anchored. **A call judged to be a lookup is answered in place or let through — a
refusal that only names a call is no longer an outcome.** A lone refusal re-sends about sixteen thousand
tokens of context to say one sentence, where the whole-file read a digest replaces averages about five
thousand, of which the digest saves about four: it costs some four times what it can buy. An answer handed
back inside the denial costs no turn at all. So where the index's answer is provably what the command would
have printed the hook gives it (below), and every other lookup runs exactly as it would have without the
hook, still counted as a miss by the transcript scan and by `audit`, which is where a shape the hook cannot
yet answer goes on showing. Where the context's own transcript records the server leaving it mid-session
(`ServerPresence`; a subagent's is its own file), the calls an answer names are spelled for Bash outright,
since the tools are not there to call; the transcript is read only when the hook is about to speak. A call
judged to be a toolchain run — a bare `swift test` or `xcodebuild` — is offered `sift run --` instead, on the
same ledger and terms. It is wrapped where it stands and the rest of the line is kept as written, a group
around it included (`(cd Kit && swift test)` becomes `(cd Kit && sift run -- swift test)`); only a group
opening on the build itself has nowhere to put the prefix and is left alone. Where the line holds statements
the prefix was not put in front of, the offer says so, since each `sift run --` wraps only the statement it
stands in front of. **Where no permission prompt can follow, the wrapping is not offered but applied**: the
command is rewritten in place through `updatedInput`, with no `permissionDecision`, and runs filtered in the
same turn, its whole log kept under `.sift/runs/`. Claude Code checks its permission rules against the
rewritten command, so a `Bash(swift test:*)` allow rule does not cover `sift run -- swift test`, and a
rewrite that turned an allowed build into a prompt would cost more than the refusal it replaces. So the
rewrite is made only when `permission_mode` is `auto` or `bypassPermissions`, or when an allow rule covers
every statement the wrapping prefixes (`WrappedRunPermission`). **A line the shell would not run as written**
(`swift test &&`, an unclosed quote, `$(`, backtick or parenthesis, a stray `)`: `ShellSyntax.isIncomplete`) is
neither rewritten nor refused: the hook cannot know what the finished line will be, so any wrapping it named
would be a guess at a command nobody wrote. It is let through (`allowed`, rule `incomplete`), and Claude Code,
which cannot split it either, prompts as it would have (#303). The rules are read from the user's, the
project's shared and local, and the managed settings files; an allow rule counts only where Claude Code would
apply it (a project file's only once the workspace trust dialog was accepted, only the managed files' where
those set `allowManagedPermissionRulesOnly`, and none from a file that is not strict JSON — a trailing comma,
which Claude Code documents as a syntax error and skips the file for, a byte order mark, or UTF-16 or UTF-32,
where Claude Code reads settings as UTF-8), while ask and deny rules are read from every file Foundation can
read, malformed or not, and so is `allowManagedPermissionRulesOnly`, since an extra veto only withholds a
rewrite. **A settings file with something in it that Foundation reads no JSON object from** — a Latin-1 byte,
a lone surrogate escape, both of which Claude Code reads — or whose object names a key twice (Foundation keeps
the first, Claude Code may keep the last) could hold a deny rule the hook cannot see, so
while one is in the chain every build is let through untouched (`allowed`, rule `unreadable-settings`); an
absent file, or one holding nothing but whitespace, withholds nothing. **An ask or deny rule on
anything the line runs as written** — any statement or pipeline stage, a substitution's, a group's, a loop
or conditional body's, a function body's and a `case` arm's included (read after every unquoted `)` and `{`), matched past leading variable assignments and the wrappers Claude
Code strips, and with its redirections set aside as well as kept — makes the hook stand aside altogether: no
rewrite and no refusal naming the wrapping, since both hand the model a command that rule, written for the
original, does not match. The call is let through (`allowed`, rule `vetoed`) for Claude Code to apply the
rule. **The stated limit is the rules in no file the hook reads** (passed with `--settings`, granted for the
session, MDM or server-delivered policy, `/etc/claude-code`): one that allows only ever withholds a rewrite;
one that asks or denies can meet a rewrite it did not foresee, which is no worse than the refusal this
replaced, but not a guarantee. Nor is `auto` strictly prompt-free: its classifier can still block a
rewritten build. A rewrite interrupts nothing, so it neither consults nor spends the ledger, and every run of
the build is rewritten. Everywhere else, an incomplete line aside, the offer is a refusal, closing on the identical re-run as the way to
the raw output: it says the re-run is allowed and returns the command's whole output, and never that it is
free, since it costs a round trip and that output (#470). **The answer is one-shot: re-running the
identical command is allowed and costs nothing against the advice**, which is what makes refusing defensible
at all, since some Swift greps really are text searches for a comment or a string literal the index does not
record. Identical means identical in what it runs: a shell command is remembered with its formatting and
comments set aside, and a comment is never a command to judge. A shell lookup is remembered by its reading
stage — pattern, flags and paths, with a `cat`'s pattern-bearing stages beside it — never by the whole line,
so a retry that changes only what rides beside it is the same ask. **A line of several lookups is about the
first one the ledger has not already allowed** (`AdviceLedger.rerunsAllowed`): its key, suggestion, in-place
answer, text-search reason and anchor are all drawn from that lookup, and the allowed ones ride along. **A
riding leg still prints, so no answer covers the line** (#528): `grep -n Foo A.swift` answered, then
`grep -n Foo A.swift && grep -n Bar B.swift`, runs whole as `otherStatementsRun`, with the note naming the
call that answers `B.swift`, rather than being denied with an answer about `B.swift` that swallows
`A.swift`'s output. No denial may swallow a leg's output: an answer covers every leg, or the line runs.
The transcript scan makes the same choice against the answers it has seen. A re-run search is scored out of
the share, because the answer told the context in so many words that the re-run goes through — including the
identical re-run of a lookup the hook answered in place, in either spelling, `Read` or `cat`; a Swift file
read whole after its digest is not, since that read is the cost the index exists to avoid. The ledger records
a denial only where one is actually printed (`AdviceLedger.noteDenial`), so a lookup let through spends no
nudge and counts as no refusal: every budget below is a budget of what a context was *told*. The ledger is
keyed per agent, so a subagent neither inherits a budget it never spent nor is muted by its parent. A runaway
guard, not a budget, sits behind ordinary use (a hundred denials in one stretch open a quiet spell, described
with the ledger below). A symbol no index on this machine could answer for is never denied at all, and
`SIFT_NO_ADVICE` makes the hook inert without touching the registration.

The same offer covers sift's four read-only lookups (#610). Claude Code delivers the MCP tools to a subagent as
names only, and over the week measured to 5 October 150 of 399 sift-using subagent contexts spent a `ToolSearch`
round trip loading them before their first lookup; `sift digest`, `where`, `search` and `strings` from Bash
answer the same with no loading step, and the scan already counts one as served. In a mode that asks, each call
would be a permission prompt, worse than the load, so `install-hook` writes `Bash(sift digest:*)`,
`Bash(sift where:*)`, `Bash(sift search:*)` and `Bash(sift strings:*)` (`LookupAllowRules`) as a block of their own
that the same uninstall takes out, which is also what lets an install over an older file add only these. **Consent is
two questions with two defaults**, because the grants differ: on a terminal `install-hook` asks about the lookups first,
default yes (`[Y/n]`: they write only sift's own index and caches, the repository's `.sift/` (and its `.git/info/exclude` entry) and `~/.sift`,
and run git with the repository's fsmonitor and git hooks switched off, so the
grant is bounded by what is written above; a no is remembered in `~/.sift`, and the question then defaults to no until a yes
or `--allow-lookups`), then about the runs, default no (`[y/N]`: a build or test runs package
manifests and build plugins). Each answer adds only its own block, and a block already in the file is not asked about
again. `sift install` asks the same two questions where it installs Claude Code's hooks, on a terminal only; with no
terminal neither is asked, nothing is added, and the Claude Code section names `sift install-hook --allow-run` and
`--allow-lookups`. `--allow-run` adds both blocks without asking, `--allow-lookups` only the lookups, `--no-allow-run`
neither (`--allow-lookups` with `--no-allow-run` is refused). `Distribution/install.sh` passes no flag: it runs
`install-hook`, which asks on the terminal the script was started from. `sift install` takes none of these flags; it
asks, or leaves them to `install-hook`. **Read-only, by their flags:** `digest` (`--all`,
`--signatures-only`, `--offset`, `--at`, `--root`), `where` (`--syntactic`, `--refs`, `--offset`, `--at`, `--root`),
`search` (`--offset`, `--count`, `--root`) and `strings` (`--root`) select or page an answer. None writes outside
sift's own index and caches (the `.sift/` of the repository named, which it lists in that repository's
`.git/info/exclude`, and `~/.sift`), runs a program of the caller's choosing, or edits the tracked tree; the programs
they start are fixed (`git` reads, `xcrun --find swift`, `swift --version`). **Every `git` sift runs passes `-c core.fsmonitor=false -c core.hooksPath=/dev/null`**
(`ProcessEnvironment.gitHardening`), so neither a hook command named in the repository's `.git/config` nor a git hook
of the repository's (`post-index-change` fires on the Stop gate's scratch index) is ever started by a lookup, and every `git diff` or `git show` that produces content passes `--no-textconv`, since textconv drivers come
from the same config. **Accepted:** a clean or smudge filter driver, which `git status` can run on a file whose stat
changed. It is a driver the user installed in their own config and bound in an attributes file, a clone carries none,
and switching filters off would change what a status reports; so it stays. The cost of the fsmonitor setting is
`git status` speed in a very large tree. The command a caller wraps in `sift run` is not touched: it runs as their
shell would have run it.
`--at` is refused unless it names a commit, so no revision can reach git as an option, and a lookup never starts a
build. **A compound line is matched statement by statement:** Claude Code splits at `&&`, `||`, `;`,
`|`, `|&`, `&` and newlines and requires an allow rule to match each part, so `sift digest X && rm -rf Y` asks
about `rm -rf Y`, and a redirection's target is checked against the file rules whatever the command's rule says;
the current form of `Bash(sift digest:*)` is `Bash(sift digest *)`, which requires the word after `sift`. Its
documented ask and deny reach into substitutions; an allow's reach there is not documented, the same exposure as
the run rules. **The primer's pointer to the CLI depends on the rules:** `session-start` reads the settings the
hook reads for the run rewrite (`WrappedRunPermission.allowsLookups`: the four allowed by a rule, and none vetoed;
no mode is consulted, since SessionStart and SubagentStart payloads carry no `permission_mode`) and only then tells a context whose sift tools are deferred or missing to
call the CLI rather than load them; otherwise it keeps the sentence that only says the CLI answers the same.

**`post-tool-use` is the nudge on the other side of the same edit — delivery after the fact, not at a
miss.** It is matched to the three tools that can put new Swift text on disk, and fires once a write or an
edit has already landed, when there is nothing left to intercept. It reads the declarations the edit added
against the index's view of the file from before the edit, runs the same comparison `similar` does on each
one, and where the best hit clears that command's own threshold, says so once — one line of
`additionalContext`, never a denial, since a tool call that already ran cannot be refused. Once per session,
per file, per declaration: a body edited twice in one session is not nudged twice about the same resemblance,
and a session that already knows is not reminded. A test function — one carrying `@Test`, or a `test…` instance method of a type inheriting `XCTestCase` — is never nudged toward another test function, since sibling tests share their callees by construction and there is nothing to act on; the best hit that is not a test still can be, and a helper in a test file is compared as any helper is. The nudge never blocks and it is silent on anything short of that
threshold, on a file outside an indexed repository, on an overrun of its own one-second budget, or on any
error — the same standing invariant as the other two hooks, that nothing here can make a tool call
unavailable, extended to a hook that cannot refuse in the first place. Its state lives beside the advice
hook's own, under the same directory an override can move.

**Before the nudge, `post-tool-use` checks that the edit left a file that parses — validation on what an
agent writes, as the refusal is on what it reads.** The edited `.swift` file is parsed with the same
parser and the same error reading the index uses (`FileParser`), so the hook and the `parse_errors` count
never disagree. Where the parse has errors the hook prints a `PostToolUse` block, `{"decision":"block",
"reason":…}`: the edit has landed and nothing is undone, but Claude Code hands the reason to the model as
feedback on it, so the next turn fixes the file rather than a build several edits later. The reason names
each error as `Path.swift:line:col message`, repository-relative, five at most and then a count, and ends
by saying the edit left the file unparseable; in an indexed repository it adds what that costs, which is
not a stale answer but a thin one — a reindex stores what the parser recovered from the broken file and
flags it, so answers about it may be missing declarations until it parses again. **It cannot wedge a
session**: a block is marked, like a nudge, by context, file and a hash of the content, so the same broken
bytes are blocked once and an edit that leaves them unchanged goes through; only new content can draw
another. Silent on a clean parse, a non-Swift path, a file it cannot read as UTF-8, a payload with no
file path or no `session_id` to mark against, and past the hook's one-second budget, which the parse
and the nudge share. The block wins over the nudge, which is dropped rather than folded into the reason:
no nudge is drawn from a file that does not parse, and fixing it is the one thing to do next. Syntax
only — a type error needs a build, which no hook runs.

**Only the errors an edit added are reported**, so a file broken on purpose, such as a parser fixture, is
not blocked on every edit of it. What the file held before comes from the payload's `tool_response`: its
`originalFile`; empty for a Write whose `type` is `create`; otherwise its `structuredPatch` undone against
the file, where every context and added line must match the file or the patch is not used. The earlier
content is parsed the same way and its errors matched one for one against the new ones, first by message,
column and the text of the error's line (an error the edit only moved; never an error on a line whose text
cannot be read, such as one past the last `"\n"` of a file broken at a lone `"\r"`, which the parser counts
as a line), then by message alone (one whose
line the edit touched); what is left over is the edit's. The message-only pass pairs an old error with a
new one only inside one hunk of the payload's `structuredPatch`: the new error on a line that hunk left,
the old one on a line the same hunk covers in the earlier content (a line it replaced, or one it kept as context). So an edit that fixes an error in one hunk and adds one with
the same message in another is blocked for the new one, and where the payload carries no hunks the pass
does not run and an error on a line the edit touched counts as added. None left is silence; otherwise the
reason names only those and says how many the file had before. The residual lean toward silence is inside
one hunk: an edit that fixes an error and adds one with the same message within the same hunk reports
neither. Claude Code folds `"\r\n"` to `"\n"` as it reads a file, so `originalFile` and the patch lines are
LF throughout, and it writes the edit back in the file's majority line ending: so the patch is undone
against the file folded to LF, and where most of the file's line breaks are `"\r\n"` the earlier content is
given `"\r\n"` too before it is parsed, so an error's line text and position read as on disk.
Claude Code also makes each leading tab of a patch line two spaces, so where the patch does not match the file as it is, it is undone against the file with its leading tabs made two spaces, the lines the file holds keeping their tabs and a removed line's leading spaces made tabs again, two to a tab.
Where the payload gives none of the three — no `tool_response`, or an empty patch on anything but a create
— every error is reported, as for a file that parsed.

**`sift stop` is the build the parse check cannot be: a gate at the end of the work, on `Stop` and
`SubagentStop`.** One command serves both events, reading `hook_event_name`. The stopping context's own
transcript decides whether it touched Swift — `transcript_path` for the session, skipping sidechain lines,
and `agent_transcript_path` for a subagent (else the `subagents/agent-<id>.jsonl` beside it; never the
parent's in its place). It counts `Write`/`Edit`/`MultiEdit` calls on a `.swift` path whose result was not
an error, since the context's last `Bash` call running `sift run` over a build or a test that did not
error *in the file's own repository*, leaving out a file the index's inclusion rule keeps out. A run
answers for the checkout (a linked worktree is its own) holding the directory it built — the call's `cwd`,
moved by each plain `cd` before it that `&&` joins to it, or what a `swift --package-path`/`-C` or an
`xcodebuild -project`/`-workspace` names — and only where the call's result vouches for the run's: it ends
its pipeline (`sift run … | tail` has `tail`'s status), no `||` stands just before it, and only `&&`
follows it. A subshell or other compound statement, a `pushd`, a `cd` a `;` or a newline separates from the
run (a newline joins statements as `;` does), or a relative path with no `cwd` places no run, and the edits
stand (#318). The line is read as the shell reads it: comments out first, then each backslash-newline joined
away, and a statement of blanks alone is none, so `cd P && \`, a newline and the run, or a run followed by
`# check` or by `;` and spaces, is placed as its one-line form is (#321). That transcript reading is the
fallback. The main route is the record a green `sift run` build or test writes itself, in
`<checkout>/.sift/green-builds.json` (`RunLedger.greenBuilds(inCheckout:)`): exit 0, the command ran what it
named, and the tree key the same after the run as before it. The checkout is the one the command built,
read by `RunCommandKind.builtDirectory(of:from:)` — the reading the transcript uses — so a
`--package-path ../C` run records C's tree for C, never the tree it was started in, and a built directory
in no repository or spelled through a variable records nothing; its proof in `proved-runs.json` follows
the same checkout. A tree edited during the run (a log written to an unignored path inside it, say)
records nothing. The two keys are the record's whole cost: four git calls each (`rev-parse` for both git
directories, `ls-files -v`, `add --all`, `write-tree`), every one awaited on its termination handler, since
`Process.waitUntilExit` sleeps about 65 ms whenever the child is not yet reaped; on this repository that put a
green build's two keys at about 400 ms, now about 85 (#324). Reusing one scratch index across the two keys was
measured and saves nothing (a re-`add` costs what a fresh one does), and a before-key taken lazily would no
longer be a key of the tree the command started on. A record of the tree as it stands answers
that checkout's edits however the shell wrapped the run, and one checkout's records never answer
another's. It is kept apart from `proved-runs.json`, so a build never answers `--proved` or the
pre-push. With any left, each repository they fall in
(the one edited last first) is keyed with `TreeKey` — the key `sift run --proved` uses — and any
`RunLedger` record of that tree, whatever its command, answers it; the ledger is that check and no source
of a command. An edited file no longer on disk — deleted, or checked out away with the branch it was committed on — asks nothing; an
edit committed on a branch, validated there, and then checked out away from is no reason to build `main`
(#672). For the first repository left unanswered the hook prints `{"decision":"block","reason":…}`
naming a build, never a test: `sift run -- swift build` where `Package.swift` is at the repository root,
else the `sift run -- xcodebuild … build` Bash command this context last ran (failed or not), as the agent
wrote it, else no block: an `xcodebuild` is never spelled here. It
cannot loop: `stop_hook_active` never blocks, and a block is claimed in the reuse marks by context and tree
key, so a tree is sent back once. Fails open on anything unreadable and past a one-second budget.
**A live run of the tree as it stands lets the stop through, silently.** Before it names a build, the gate lists
the repository's `.sift/progress/` (`RunProgressPaths.liveRuns`) and takes a run live by the staleness rule
`RunProgressWriter.staleAfter` holds, which any consumer applies: a phase that is not terminal and an `updatedAt` no
more than 5 s old. A live run whose `tree` equals the tree being judged is the run the agent started in the
background and ended its turn to wait on: the stop passes, nothing is claimed, and the verdict lands in the
ledger when the run ends, for the next stop to judge. A second build into the same `.build` would collide with
it, so none is ever advised while a run of this tree is live. A live run of another `tree` (edits made after it
started) does not answer the question, but it changes the advice: the block says a run of an earlier tree is in
progress and to run the build once it ends, never to start one now, and is claimed under a key of its own so
the ordinary advice can still fire once the run has ended. A stale heartbeat, a null `tree` and an unreadable
file are no live run, and the gate blocks as it always has. The proved ledger records test runs only, and is shared by every worktree, so a green `sift run -- swift test`
in a sibling worktree with an identical tree answers too (the same content was tested); a build answers
through its checkout's green-build record, or through the transcript of the context that ran it.

**`sift pre-tool-use --verdict` is for probing the hook, never for the hook itself: one line on stdout,
tab-separated, in place of the JSON `PreToolUse` reads.** The hook's own path stays byte-identical whether or
not the flag is passed; `--verdict` changes only what is printed, never the decision or its side effects (the
ledger, usage and suppression logs are written as without it). The line is `<verdict>` alone where nothing
was offered, `<verdict>\t<call>` where a call was and no rule is known for it, and
`<verdict>\t<call>\t<rule>` where both are. A field keeps its position whatever is missing
(`allowed\t\tledger`, never `allowed\tledger`), and no line ends in a tab. The verdicts, one per outcome
`run()` can reach:
- `allowed` — the command proceeds. No call, and a rule naming *which* allow it is, because a probe cannot
  otherwise tell them apart and they mean opposite things: `disabled` (the hook is inert, `SIFT_NO_ADVICE`),
  `cursor` (the payload is Cursor's, whose client shows a refusal to the user rather than the model),
  `noLookup` (the call is not a lookup the index could answer, and no gate withheld it: a call a gate
  withheld and let through is printed under the rule the suppression log records for it, `unknownName`,
  `alreadyDigested`, `gateLeg` and the rest, so the probe and the log name one decision alike (#385)),
  `adviceTaken` (the call *is* an index call,
  and its root needed no pinning), `ledger` (the decision was the ledger's — a repeat within a quiet
  spell, the identical re-run an answer promised, an offer this context has already taken up, or a record
  that would not save), `notAnswerable` (a lookup with no answered shape behind it: the hook had nothing
  to hand back, so it said nothing), or one of `InPlaceAnswerer.Withholding`'s raw values (`overTime`,
  `overSize`, `notExact`, `noStore`, `backingOff`, `noRepository`, `outsideRoot`, `unchecked`,
  `treeNotWritable`, `failed`)
  — an answer attempted and withheld, named by *why*, which is the more specific of the two facts that
  can end a lookup in an allow. The last two are the outcome rule, answer in place or allow, and both are
  noted in the suppression log as well, so a gate that never answers shows as a rate.

  **`ledger` is the one a probe is surprised by, and the reason a probing caller passes its own
  `--session`.** `--command` carries no hook payload, so a probe with no `--session` shares one default
  ledger entry with every other probe on the machine: the command refused a moment ago is
  `allowed\t\tledger` now, because its nudge was already spent. So a probe passes a unique `--session`, and a
  gate that wants a deny names the third field too.
- `deny` — the one bare refusal left: a toolchain run offered its `sift run --` wrapping (`<call>` is the
  wrapping, `<rule>` is `RunAdvice`) where a rewrite could cost a permission prompt. Where it could not, the
  same run is `amended` instead. Nothing here can be answered in place — there is no digest of a build — and
  what the refusal spares is a whole build or test log, priced in the tens of thousands of tokens, so the
  economics above do not reach it.
- `in-place` — the lookup was answered in the refusal's place, which is the only outcome that still denies
  a call: `<call>` is the suggestion's call, reduced to one line (its several `where` lines, for an
  alternation of names, joined with `; `), and `<rule>` is the advisor that classified it — `ShellAdvice`,
  `ReadAdvice` or `SearchToolAdvice`, the three that can carry an answered shape.
- `held` — the lookup was held back with a pointer at an index call the same message already made and the
  transcript has not yet answered (#606): `<call>` is the calls the pointer names, joined with `; `, and
  `<rule>` is `inFlight`. A denial that carries no answer, so it is never recorded as an answer in place.
- `amended` — the call *is* the advice being taken (an index call, or the tool's own CLI) and its root was
  pinned to the caller's own repository (`CallerRoot.amendment`); no call, since an amendment changes the
  call rather than offering a different one, and the rule is `adviceTaken`. Or a toolchain run rewritten in
  place to its wrapping: `<call>` is the wrapping and `<rule>` is `RunAdvice`. `--permission-mode` judges a
  `--command` probe in the mode it names, since a probe carries no payload to read one from.

**The one-shot promise is kept mechanically, and a refusal that cannot be written down is not made.** The
whole guarantee rests on a single record of the command, so its read-modify-write is one locked operation
(two hook processes from one parallel tool batch would otherwise each overwrite the other), and a decision
whose save does not land resolves to *allow*: an advice hook may never fail closed. Two ways the memory can
still legitimately be lost are named rather than papered over: a lock that cannot be opened runs the body
unserialised rather than wedging the hook, and a session's ledger ages out after a week.

**Where the index's answer is provably what the command would have printed, the hook gives the answer; where
it is not, the command runs.** For the answered shapes the hook runs the call itself (`InPlaceShape`,
`InPlaceAnswerer`) and returns the answer where the refusal would have been — still a denial, so the identical
re-run still passes and gets the raw text, and still delivered as the call's error, the one channel a
`PreToolUse` hook has into the model's context. A shape is only a candidate. **A whole read of one Swift
file** — `Read` with no range, or a `cat` of one file standing alone — is that file's digest, answered only
where the file is there at exactly the path named, is a regular file the index holds, and the digest resolved
to that same repository-relative path (a digest resolves a bare file name to a file of that name anywhere in
the tree). **A grep of one file for its declarations** — a pattern of Swift's declaration vocabulary and
nothing else, each alternative keywords, modifiers and attributes closing at most on the one name a
declaration keyword introduces (`static\|case `, `@Test func`, `public `) — is that file's digest. **A grep of
one file for a member's declaration** (`func signedDelta`, `var body`, `case pending`) is the source of every
member it matches, whatever type in the file holds it (`digest <Type>.<member>`, one call per member). The
same member grep of **several named Swift files, a glob of them, or one file searched recursively** is
answered file by file in operand order, each file proven exactly as a grep of it alone would be, the glob
expanded as the shell expands it from disk at decision time; every file must be a Swift file the index holds,
or the call runs — as it does where one file's match is not a served member's declaration. Claude Code's
`ugrep` prints several files in whatever order its threads finish and puts no `--` between them, where the
system grep prints them in operand order with one, so a cut across files is answered only where it provably
keeps every printed line under any order and with or without a `--`: for `head -N` or `tail -N`, the files'
printed lines plus the `--` a context option might print total no more than `N`; for `sed -n a,b`, `a` is 1
and `b` reaches at least that total. A search printing no file names (`-h`) or filtering them (`--include`) is
left as it was. **A word-anchored sweep for one name** (`grep -rn '\bdepot\b' Sources`, or `-w`) is `where
<name>` with every reference site, answered from the repository its path operands name — every operand inside
one root, a worktree answering for itself and one repository never for another's files. The lookup has to be
the whole of its own statement: one pipeline whose only other stage is a `head`, a `tail`, or a `sed -n`
window keeping the printed lines at those positions; no substitution, no output to a file, no redirection but
standard error's, nothing in front of either stage's command word (an environment assignment can change what
grep prints, as `GREP_OPTIONS=-v` does), and no flag outside a short closed list (`-n`, `-H`, `-h`, `-s`,
`-I`, `-r`, `-E`, `-F`, `-i`, `-w`, `-x`, an `--include=*.swift` beside a `-r`, and a context count for the
member shape alone).

**A line is answered only where the answer reproduces every statement on it.** A lookup that is one leg of a
sequence is the commonest lone refusal there is, but an answer to one leg of a line whose other legs print
what it leaves out saves one statement's output and costs a re-run of the whole line. So another statement
rides beside the lookup only where the answer reproduces it — another answered lookup, a literal
`echo`/`printf`, a `cd`, a `||` fallback proven silent; any other (a lookup the ledger already let through, an
`ls`, a grep over a directory or a document, a `git grep`) lets the whole line run, withheld as
`otherStatementsRun`, which the audit counts as a miss on a `batched` row of its own under `cold`. The line
still runs, but the hook hands the model one line of `additionalContext` naming the index call, with no
`permissionDecision`; `--verdict` is unchanged. **Only a leg that alone would have been answered is a batched
miss.** The hook asks the lookups again as they would be with nothing else on the line (`Match.alone`),
inside what is left of its time budget: where that is answered, the line is logged `otherStatementsRun` and
the note names the calls the answer's own opening line names, spelled for Bash, so the call it names answers
the file that was read, never a same-named type in the caller's own tree. Where the leg alone is withheld — on
worth (`notSmaller`, `linesNotShown`) or for any other reason — the line is logged under that rule and no
note is given. An answer that covers one statement says so in the opening line and nowhere else — *sift
answered the lookup in this command with …* — so that the statements which did not run are not read as
covered. What still keeps a compound line from being answered, so that it runs whole: a substitution anywhere
in it; a joint other than `;` or `&&`, apart from a `||` whose fallback is handled as below; a statement no
answer reproduces; and a directory move this cannot follow (a computed `cd` word, a `pushd`), since stepping
over it would answer one directory's question with another's files. Several answered shapes on one line are
answered together, each in command order (`grep -n A F.swift; grep -n B G.swift` is `where A; where B`).

**A lookup in front of a `||` is answered where the fallback provably never ran.** The fallback runs only
where the list before the `||` fails, so a fallback proven silent (`true`, `:`) is matched as though it were
absent, and any other fallback (`sed -n '1,30p' F.swift 2>/dev/null || find . -iname F.swift`) only where the
lookup's own exit status is proven 0, the answer printed being the lookup's alone. A pipeline's status is its
last stage's, so the last stage — and, for a window, every stage — must be on a closed list of forms seen to
exit 0 against a real file with the system's tools (`FallbackProof`): `cat -n`, `head` and `tail` with at
most one in-range count, `sed -n` with print windows only, and `awk` with `NR` comparisons and a body of at
most `print` of simple fields, redirecting only `2>/dev/null` or `2>&1`. Everything else is refused, however
harmless it looks, because the system tools read some forms as an error (a zero or oversized count, a second
operand, an option after the file) and a body beyond the list can write, pipe or run a command. A lookup
piped into a cut, the names shape's `grep -rn Name Sources | head -5` included, is held to the same list for
its cut. A window that fails the list is refused, here and outside a fallback alike, since a window off it can
print an error or act as well as print, and the digest stands in for neither. Here the window is also
required to be fully parsed, since a whole digest is a safe superset of what a window prints but no proof
that it printed. A lone `cat`, `sed -n`, `head`, `tail` or `awk` window of a file exits 0 exactly where the
file is there to read, which the answer checks when it decides; and a lone `grep` exits 0 exactly where it
prints a line, which every grep shape already proves by running the search — so a grep that finds nothing, or
a read of a file that is not there, is let through (`notExact`). A lookup that opens with `!` is refused
outright, since it negates the list's status. The list in front of the `||` may hold only `cd` moves this can
follow and the one lookup. Every joint after the first `||` must be another `||`: `A || B; C`, `A || B && C`
and a trailing `&` are refused, with the same `notAnswerable` reason. The fallback is never judged as a read
and adds nothing to the ledger or the usage log, since it never ran. The proof assumes no `pipefail` in the
user's shell environment: one set on the same line is refused, but one set in a profile cannot be seen.

**Several whole reads are answered together.** Where every lookup of a command is a whole read — `cat A.swift
&& echo --- && cat B.swift` — each read is answered in command order under one freshness header, the opening
line naming every call and saying it answered *the lookups* where other statements rode beside them. A `cat`
of a Markdown document counts as one of the reads beside a Swift read and sits under the header as its outline
stands: its own first line says it was read live from disk, so the header prices only the index the digests
came from. Beside any other lookup a document's `cat` rides as it always has, and documents alone are not a
lookup on the shell route. Every read is rooted as it would be alone (a Swift file by its own repository, a
document only inside the caller's) and they must all resolve to one root, since one header cannot speak for
two trees. The same size and time budgets bound the whole answer. **The whole thing is withheld where any one
read cannot be answered**, so a partial answer is never read as complete; so is a file read whole twice, or
whole beside a window of it, a directory move between the reads, and a read mixed with any other lookup
outside a compound line (next). Several windows of one file are not a file read twice: they share its one
digest (the cold-window rule below).

**A compound line of two lookups or more is answered whole.** Where a line holds at least two lookups that ask
more than a document's outline, and every statement on it is a lookup answered on its own, a literal
`echo`/`printf`, or a literal `cd`, each lookup is answered in command order under one freshness header, each
literal's text printed verbatim where it falls, and the opening line says it answered *this*. A literal is
one no shell expands or interprets (no `$`, glob, `~` or backslash; the closed forms are in `InPlaceShape`).
A `cd` has to name a directory that is there, and every lookup resolves against one directory. **Every joint
is proven**: a statement and the `||` fallbacks after it are one unit, which has to prove its success where a
fallback could print or an `&&` follows it — a lookup by the same proof a lone lookup in front of a printing
fallback gets, a `cd` by its directory, a literal always — and a backgrounding `&` refuses the line. Each call
is computed on one shared engine exactly as it would be alone: an answer opening on that engine's header
stands under the one header above them all, and any other (a `where` sweep's, which states the semantic
store's freshness too) keeps its own, so every part's freshness is stated. The sweep's loose reading is never
tried inside a line, so **one failed part withholds the compound answer**. **A literal never moves**: a
second window of a file windowed before with a literal printed since would share that file's one digest on
the wrong side of the literal, so the line is not read as compound; a part repeating one before it is said
once, but where a literal was printed between the two the compound answer is withheld. Anything else on the
line lets the whole line run as `otherStatementsRun` (above), counted a batched miss. **A withheld compound
answer falls back to the ordinary reading** (`Match.ordinary`), so the compound rule never takes an answer
away. An `exec` anywhere on a line refuses every answer on it, since the shell is replaced by what it names.
The usage log gets one line per call, as for every answer made of several calls, with the framing charged to
the first.

Everything else is refused
as before, its call named rather than run: a use of a name rather than its declaration; several files, a glob,
a phrase; and any search that is inverted, counted, only-matching, listing files or handed several patterns.
An unanchored name and an alternation of names are the exception below.

**Exactness is proven before an answer is given.** Where the lookup was a grep, the hook runs the command's
own search in-process over the same files (`ShellGrep`, `GrepPattern`) — the same pattern semantics (basic,
extended or fixed, `-i`, `-w`, `-x`) — works out what it prints, context groups and their separators
included, and applies the `head`, `tail` or `sed -n` window to that. The answer is given only if every
printed line falls inside a range the answer serves as source, verbatim, or on a line the answer names by its
own number; a digest's collapsed members and the members past its truncation name no line and account for
nothing. Each shape reads that rule its own way. A declaration grep is answered with the digest only where
every printed line is the first line of a declaration it lists with a range, so a pattern of bare `let`,
`case` or `init`, which prints locals and switch cases no digest numbers, is refused. A `^}` alternative (a
column-0 closing brace) joins a declaration grep, or stands alone, only as the end of a top-level
declaration's range the digest shows as `:a-b`: every line of the file opening on `}` has to be a lone `}` on
which a declaration with no parent ends, read from disk at decision time, or the answer is withheld; it is a
candidate only where the pattern word was quoted or escaped (unquoted, `^}` is a zsh parse error), and an
`-E` or `-w` form is let through. A member grep's every match has to be a served member's declaration, and
every printed line, context included, inside a served member's source or served verbatim beside it; a match
inside a body, such as a string literal spelling the declaration, refuses the answer. Context a `-A`, `-B` or
`-C` count reaches past a member's end or before its start comes back beside that member as the lines
themselves, numbered as grep numbers them, never served as another member, under the same size budget. A
pattern range (`sed -n '/START/,/END/p' F.swift`, `awk '/START/,/END/' F.swift`; `RangeRead`) is answered
with one member's source only where the lines it prints are provably that member's, worked out from the
file's real lines at decision time: START matches exactly one line of the whole file, that line is the
member's first line as the index records it, and the first line after it that END matches is the member's
closing line. The patterns are read in the dialect the tool uses and only where BSD `sed` and `awk` read them
the same way; an escape other than a quoted metacharacter, or an `awk` brace that could open an interval,
leaves the range unread and it runs. A range to the end of the file is let through. An `awk` program that
prints every line is a whole read, answered as `cat -n` is. A sweep's every printed line has to be a
declaration's first line or a reference line the `where` answer lists; a comment or a string literal is a
line the index never records, and a site matched on the name alone is a lead the answer itself disowns, so
either refuses it. **The search reads the common core every grep a shell may run agrees on**, because Claude
Code's shell runs `ugrep` behind a function named `grep`, and bash, sh and a plain shell run the system's own:
an answer has to be exact under both or it is refused. Anything outside the core resolves to the refusal: a
construct implementations read differently (`\w`, `\S`, `\d`, a backslash in brackets, `$` before an
alternation, a quantifier on nothing); the places `ugrep` was probed to read a pattern its own way
(`[[:punct:]]`, a pattern that can match the empty string, `-E` or `-G` after `-F`); a letter outside ASCII
under `-i`; a line whose meaning depends on the locale, decided twice (bytes with ASCII classes, characters
with Unicode's widest) and refused where the two differ; a file that is not UTF-8, holds a NUL, or opens on a
UTF-16/32 byte-order mark, or a first line whose match turns on a UTF-8 one; a line closing on a carriage
return that changes its match; a symbolic link; a tree past four thousand files or thirty-two megabytes; and
a cut across several files, whose order grep does not fix. A recursive search reads every regular file under
its operands, hidden and ignored ones too, as the system grep does, while the `ugrep` behind Claude Code's
`grep` skips version-control directories and every path a `.gitignore` at or below the operand ignores. A
line only the larger set prints is extra, and an extra line in a file the index does not answer for already
refuses the search; what the larger set gets wrong is a search `ugrep` prints nothing for where the system
grep prints lines the index holds. So a walked search is answered only where some printed line is in a file
every grep reads: no version-control directory on its path below the operand, and either no `.gitignore`
between the operand and the file or no ignore pattern matching it (asked of `git check-ignore --no-index`
with case folding off, one call per operand, refused where git cannot say); a `.gitignore` on the path that is
not UTF-8, holds a `[`, or holds an inner-`/` pattern outside the operand's own file refuses it too, since
`ugrep` and git read those differently. Three limits are stated rather than hidden: the locale readings are
Swift's Unicode tables, not the host's; a declaration whose attribute stands on its own line is numbered by
the attribute's line, so a grep for its keyword prints a line the digest does not number, and is refused; and
a sweep over a tree holding any binary file is refused whole, since a NUL-bearing file is undecided whatever
it holds.

**Two shapes are answered without that proof, deliberately, and each is the offer's own answer handed over.** A
search across a tree whose pattern reads as one name or an alternation of names — `grep -rn Depot Sources`, a
`Grep` for `Depot`, `grep -rnE 'Depot|Gizmo' Sources` — is answered with one plain `where` per name: the very
calls the refusal would have listed, in the same order, with one freshness header over the lot. Nothing is run
and nothing is checked against printed lines, because there are none to check: the hook asserts that `where`
answers this search, and refusing is only a way of charging the context a round trip to arrive at the same
text. A symbol search is the second largest refused shape this machine records (fifteen in a week against the
digest answer's twenty-six), and the narrower rule it replaces answered only the word-anchored spelling, which
almost nobody writes. What holds the exception honest is that both ends agree on the question: the pattern is
read by `SweepPattern`, the same reading that builds the offer, so a shape query, a phrase or an alternation
with prose in it is no more answered than it was offered; the names are capped at the offer's own `callCap`;
and every name reaching the answer is one the index declares (`unknownName`, `partlyDeclared`). The two
surfaces are one question — `Grep(pattern: "Depot", path: "Sources")` and `grep -rn Depot Sources` produce the
same call — so a model refused at one and answered at the other is never taught a detour. The word-anchored
reading still runs first, because a proven answer is worth more than an unproven one that says the same
thing, and where that proof fails the sweep is asked again as the names shape, with what is left of the time
budget and under that shape's own rooting, bounds and back-off; otherwise the precise spelling would buy less
than the vague one. **The search's own path operands ride with the call, and they both root the answer and
bound it.** They root it: a search naming another repository's files is not answered from the caller's index,
because the hook's assertion was made against the directory the command runs in, and answering out of a
different tree would hand over an answer nothing checked and index a stranger's checkout to do it. They bound
it: where every site the answer locates falls outside the paths the search named, the answer is withheld
(`outsideSearch`) and the search runs, printing the nothing that is the truth. An operand that *is* the
repository bounds nothing, and neither does a call with no operands. **The operands may be files as well as
trees, but a name grep of named files is let through, not answered.** Several Swift files, a shell glob of
them, or `-r` on named files (`grep -n Depot A.swift B.swift`, `grep -rn Depot Tests/*.swift`) run as written:
a `where` of the whole tree is the wrong answer to a search scoped to files, so the hook offers none, and
`sift audit`'s scan scores these shapes as withheld on worth (`namedFiles`) through the hook's own predicate
(`InPlaceShape.namesOnlySwiftFiles`). One Swift file under a non-recursive grep (`grep -n Depot
Sources/Depot.swift`) is still offered that file's own digest. A file operand is read as the shell reads it (a
`*` never crosses a `/`) where a bound is asked of it. A file is rooted by the directory it stands in, and a glob by the directory before its first
wildcard; a file is bounded by that directory as the filesystem spells it, so a command run from a directory
reached through a symlink bounds as its target does. **A file that is not there is never answered**, and an
operand the bound cannot place in the repository at all holds no site either — being unresolved is never read
as being the repository. A glob written in quotes is no glob by the time the search runs, so it takes no
names answer at all. A file whose references a `where` row lists only up to its cap is located by the lines
the row lists and by none it only counts, which is all the bound needs: one site inside. A grep of one file
whose pattern is a declaration still goes to that file's digest first, and only a pattern that shape does not
read falls to the names (`func stock(in` is `where stock`). A recursive grep of one file (`grep -rn stock
Depot.swift`) is a grep of a named file and is let through, never taking that file's declaration shape; the
same holds across several files or a glob (`grep -n 'func go' A.swift B.swift`), since no one file's digest
was asked to prove them and the names do not answer. Beside a read of a Swift file (`grep -n f12 Big.swift &&
sed -n 20,40p Big.swift`) such a grep rides along, so the read keeps the file's digest it was answered with,
which is also what locates the file for the windows after it. Every
withholding a search of named files draws stands in front of the answer as it did in front of the offer — a
phrase, a string literal, a name no index declares, and an alternation of names confined to the files named
(`severalNames`), whose answer is a tree's and not the files' — and a `| head -N` behind it is treated as it
is behind a tree search: the window is of the very answer handed over, which stands whole. The pattern is
read as the tree's is, with two spellings of one name made one: a member path written with a bare `.` as well
as an escaped one (`Depot.pending`, `Depot\.pending`) reads as that path rather than as its longest component
(the left side capitalised, since `tab.about` is a regex, and the member no file extension an enum case often
spells), and an alternation whose branches read as the same name is that one name, asked once. The bound is
asked of each name in turn: an alternation is answered only where every name has a site inside the operands,
since one name found inside is no evidence about another found only outside — withholding is preferred to
dropping the name, which would hand back a partial answer nobody could tell was partial. Where a name has a
site inside, its answer stands whole rather than narrowed to the operands, since narrowing it would be
invisible. And the exception buys no relief from the rest: the repository must hold an index store, as the
anchored sweep's must, since a `where` without one lists no callers; the whole refusal must fit the size
budget, over which it allows; and a shape that overruns the time budget is backed off in that repository like
any other.

**The second is a whole read of a Markdown document, answered with the document's heading outline.** It is the
largest single read the hook sees: a design document of hundreds of kilobytes against a refusal of a few
carrying its outline, paged at sixty lines with the rest behind an `--offset`. There is no proof to build for
it and no index to bring up to date, because nothing about a `.md` file is indexed: the outline is what
`digest <path>.md` itself renders, read live from disk at the exact path the read named — the very call the
refusal would have listed. What bounds it: a back-off shape of its own (`outline`), so a document that
overruns never switches off the whole read's answers beside it; the same ten-kilobyte size budget, over which
it allows; the caller's own repository and the document at its exact path inside it (an outline consults no
index, but the engine that renders it opens a store, and reading another checkout's document must not leave
a `.sift/` directory there, so a document in another repository is left to the read as `outsideRoot`; a path
in no repository, a directory, or no file at all is withheld rather than resolved to a document of that name
elsewhere); and the compression floor, which keeps the small documents away altogether — below sixty lines
and twenty non-blank ones `ReadAdvice` offers nothing (`DigestFloor.wouldServeContent`). Above the floor, a
document of at most 8 KiB on disk is let through untouched, logged as `smallDocument`
(`ReadAdvice.isSmallDocument`): 8 KiB is about 2k tokens, an outline saves a fraction of that, and a wrong
guess (a document read whole because the caller is about to edit it) pays for the outline, the file and a
round trip. A document with no headings, or whose outline would be no smaller than the document, is withheld
too. Two more cases run the read untouched, because in both the outline only precedes the identical re-run:
an outline past a third of its document is withheld as `outlineTooLarge`; and a document the context's latest
prompt names is a read the context was told to make, let through before any answer is built and logged as
`namedInPrompt` (`LatestPrompt`): the prompt is the latest line of the context's own transcript the user
wrote (the handoff, in a subagent), and a path in it matches written absolute, from home, or relative to
where the prompt was written or to the call's own directory. A replay hands the hook the prompt each call
followed. Both stay uncounted, as every document read is. **The answer carries no freshness header,
deliberately.** Every other answer comes out of the index and a reader has to know what state it was in; this
one comes off the disk, and its own first line says so — *read live from disk — headings only, nothing in it
is indexed*. A tree line above that would price an index state nothing here consulted. For the same reason
the index is never brought up to date to answer one: the engine is opened for the store alone, so a Swift
tree is not built to answer a question about prose.

**A whole read of a Swift file is answered with its digest only where that is worth the turn it costs.** The
digest is followed by another call more often than not. Of 181 hook answers to whole reads, measured on
5 October 2026 (171 of them in subagents), 47% were followed by a ranged read of the same file, 34% by a whole
read of it and 4% by another sift call, so 85% cost a further turn that re-sends the whole context.
For a small file that turn costs more than the digest saves, so the read runs untouched, logged as
`notWorthTheTurn` (`WholeReadWorth`). With F the file's size and D the answer's, each in tokens at four bytes
to the token, and C the context's size in tokens at the call, the digest is the answer only where

    (1 − 0.34) · F − D  >  0.47 · R + 0.85 · (0.1 · C) / (1.25 + 0.1 · T)

The left side is what the digest spares: the file, less the 34% of cases where it is read whole anyway, less the
digest itself. The right side is what the follow-ups cost, in answer tokens. 0.47 is the ranged follow-up share
and R = 700 tokens the median ranged follow-up. 0.85 is the share of answers followed by any further turn, and
a turn costs the context re-read from cache at weight 0.1 of an input token (0.1 · C); one token of answer is
written to the cache once (weight 1.25) and re-read by each of the T = 50 later turns that carry it (0.1 each),
so dividing by 1.25 + 0.1 · T states that turn in answer tokens. At C = 45,000 and a digest a fifth of the file
the margin is about 940 tokens, so a file is answered only above about 2k tokens (about 8.2 KB, about 200 lines).
At the same digest share the threshold is F above about 5.2 KB at C = 20,000 and about 17 KB at C = 120,000.
**C is read from the context's own transcript, never
the parent's.** It is the last assistant message's `usage`: `input_tokens` plus `cache_read_input_tokens` plus
`cache_creation_input_tokens`, taken from the tail of the file alone (`ContextSize`), since the hook runs on
every call and a transcript runs to tens of megabytes. A subagent's payload carries its `agent_id` and the
session's `transcript_path`; its own context is `<transcript_path without .jsonl>/subagents/agent-<agent_id>.jsonl`,
and where that file is absent C is the default, 45,000 tokens (the median of the measured answers), never the
session's usage, which is a different and usually larger context. The default stands too where the transcript
cannot be read or records no usage. A replay has no live transcript, so it hands the hook the usage of the
assistant message each call followed, as it hands the prompt. The rule judges one whole read of one Swift file
answered with its digest; a window, a Markdown document (which has its own floor, `smallDocument`, above), a
line of several reads and every read the hook already lets through are untouched. A let-through on this rule
prints no answer, so it writes no line to the answered log and leaves no marker behind, and it is counted as
withheld on worth, out of the share, as `notSmaller` and `linesNotShown` are.

**The answer is bounded twice, and every doubt resolves to letting the command run.** Three seconds for the
whole answer — engine open, freshness check, search, query and rendering — which a warm index answers from a
cold process in a few hundred milliseconds and which sits well inside the hook's five-second timeout; past it
the index is doing something other than answering, and the command running as it would have is the better use
of the call. A shape that overruns the budget in a repository is left alone there for five minutes afterwards
(`InPlaceBackoff`, one file per repository and shape in the advice directory): the call goes through without
the answer being tried, so a shape whose answers never fit costs at most three seconds of waiting in every
five minutes of lookups. The back-off is kept by shape because the shapes cost different things, and a sweep
that ran out of time says nothing about the next whole read, the cheapest and commonest answer. **The cheap
checks run first, and the engine opens last**, since opening it and bringing the index up to date is most of
what an answer costs: the back-off and the index on disk, then — for a sweep — whether the repository has an
index store at all (without one no `where` answer lists a reference), then the command's own search, which
for a sweep stops at the first printed line of a file no `where` answer lists lines of, or once locating every
printed line would cost more than the size budget. A refusal any of those decides costs a probe or a search,
never the engine. Ten thousand bytes for the whole refusal: Claude Code inlines hook-supplied context only up
to ten thousand characters and saves the rest behind a preview, and bytes bound characters from above. No
repository behind the call, operands in more than one, a shape in its back-off there, a sweep with no index
store behind it, a search that cannot be reproduced exactly, a tree search none of whose answered sites lies
inside the paths it named, an answer that does not account for every printed line (or resolved to another
file or another declaration; a window's members, which leave the `import` lines it prints without a trace, are
never served where the whole digest is not), a failure, or either budget overrun: each leaves the command to
run exactly as it would have, and each is noted in the suppression log (`answerWithheld`, with which of these
it was), so a gate that bites shows as a rate.

**What the answer says.** Its first line names the calls that answered and what the re-run is for —
`sift answered this with \`digest Sources/…/View.swift\` instead of running it — re-run the identical
command if you wanted its raw output.` — several calls comma-separated where several members were served,
and spelled for Bash once the transcript records the server gone; a sweep's call asks for every reference
site in the spelling of the form it is written in, the tool's argument (`where Depot (refs: true)`) or the CLI's
flag (`sift where Depot --refs`). Then the index answer as the calls serve
it, header first. Then one line stating the sizes where the answer weighed itself against source —
`X of source → Y served (P% smaller)`, `Y` being every byte of the refusal and `P` rounded down — and
saying no saving is claimed, and why, where it did not: a `where` and a member's source stand in for no run of
source the log could weigh, exactly as when the server serves them. **The line states sizes, never a saving
in tokens**: when the answer is given nobody knows whether the source will be read anyway, and the two paired
end-to-end benchmarks found no detectable net difference in tokens, so a per-answer
saving would read as a measurement it is not. The opening line's suffix names the re-run as the way to the raw
output, and where the raw output is a measurable amount more than the answer it says what that costs and names
the cheaper route (#613). **Only for a whole read of one Swift file answered with that file's digest** — a `Read`
with no `offset`/`limit`, or a whole-file `cat`, the command carrying nothing else — the suffix is
` — re-run the identical command for all N lines, about K tokens, or Read just a member's line range below with
offset and limit.` `N` is the file's line count as the index holds it, and `K` is its size on disk in bytes over
`WholeReadWorth.bytesPerToken`, the one bytes-per-token figure the `notWorthTheTurn` rule uses, written with one
decimal and a `k` from a thousand tokens up (`3.1k`) and as a whole number below it. The suffix holds no
parentheses, so a call's `(note)` stays the only parenthesised text on the line. Measured over 181 real
answers, 34% were followed by the whole file anyway and 45 of those 61 were the identical re-run the old suffix
offered, while the ranged `Read` of the member wanted — which the hook never interrupts once the context holds
the file's digest — went unnamed. Every other answer (a window's, a `Grep`'s, a `where`, a line of several
lookups) keeps ` — re-run the identical command if you wanted its raw output.` unchanged. **The reader of the
line keys on the stable stem**, ` instead of running it — re-run the identical command`, and takes everything
after it as the suffix, so a transcript written with either form scores the same calls and note, and the old
form needs no migration. The opening line stands above the header,
which the Answer Contract names as an exception: it is the refusal's own sentence about what it carries, not
a note on the answer.

**It is the index serving the lookup, and every surface counts it so.** The ledger notes it as an index
call, which keeps the advice coming to a context that takes it. The hook writes the usage line the server
would have written for each call (session and agent, what was served, every byte of the refusal charged to
some call, and the source it stood in for), marked `via: hook`; those lines are what `usage` and the status
line price the saving from, and what excuses a later whole read of the digested file (`DigestedFiles`).
`usage` leaves them out of its latency percentiles, saying so: an answer in place is timed from a fresh
process with the engine opened inside it. The transcript scan recognises the refusal by its first line: the
lookup the call was counted as is taken back, it is counted `indexed` — never a refusal routed around and
never cold — and what each call located is credited as an index call's answer is, so a ranged read afterwards
is guided; its identical re-run is the escape hatch (above); `audit` says how many of the indexed the hook
answered. **An answer to a read that the same context then reads whole anyway is a miss, not a saving**:
where a whole read of the answered file (a `Read` with no range, or a shell line that prints it whole) or the
identical re-run of the answered call follows within five tool calls in that context
(`AnswerThenRead.window`), counted from the first call of the turn after the answer's own, `audit` withdraws
the bytes that answer's closing line weighed (its source less what it served) and prints the miss rate by answer shape (outline, digest,
window) beside the saving the rest claimed; a ranged read or a different window afterwards is the loop
working and is no miss. `usage` prices the saving from the log, which never sees the read, so its figure is
gross, as it is on every face: `audit` and the report page count the whole reads after a digest beside it and
subtract nothing. **The voluntary share is the release metric**, and `audit` prints it
under `indexed`: the indexed lookups the hook did not answer, over the indexed and the cold ones, with its
arithmetic beside it, since the headline share counts the hook's forced answers too. `audit --share` prints
only those two lines, for comparing roots and windows in a script, and refuses `--replay`. None of this needs
the MCP server — the hook opens the engine the CLI opens — so it goes on serving a context whose server has
dropped.

**What the hook declines to say is as much a design decision as what it says, and the judgement is the
hook's rather than the caller's.** Nobody typing a command can know in advance whether their issue body
happens to mention code search, or whether a file's Swift is real or quoted; asking them to is how a
mechanism that costs one round trip starts costing a rewrite of the command. Thirteen rules, and each errs the
same way, because a withheld nudge costs one missed opportunity while a nudge that fires wrongly costs a
doubled invocation of a possibly long command *and* the credibility of the next suggestion:

- **A command's payload is text being written, not a file being read** — a `gh issue create --body`, a
  commit message, a heredoc — where a word like `search` is prose, not a lookup. A file rewritten in place
  is written too, whatever the line checks afterwards: `perl -0pi -e … View.swift && grep -n … View.swift`
  is the edit, and refusing it on the strength of its check holds the edit up. The in-place flag is read
  off argv, letter by letter, because it usually sits inside a cluster (`-pi`, `-0pi`, `-pi.bak`, `-Ei`)
  where no phrase finds it; a letter that takes a value ends the cluster (`perl -Mstrict`), and an editor
  counts only where something runs it — the command word, or what `xargs` or `find -exec` hands a list to.
- **A count is a question about text volume**, which is the one thing a symbol index does not measure. It
  matters most where a file's Swift lives inside string literals — a lint rule's fixtures — because a
  declaration in a string literal is characters rather than a declaration, so the `digest` offered in its
  place answers a different question and returns a smaller number for it.
- **A listing opens no file**, so nothing was lost to advise about.
- **A search over no one file whose pattern names nothing at all** — no identifier anywhere in it — asks
  for text the index does not record: a version literal, a date, punctuation. The bar is *names nothing*
  rather than *names no symbol*, deliberately: `final class` and `@Test func` name no symbol either and are
  exactly what `search` serves. A pattern that does name something is the `AdvisableName` rule's business,
  not this one's. No length floor is drawn here even though the symbol reading draws one at three
  characters: borrowing it would take a search for a short name out of the denominator and so *raise* the
  reported share, which is the one direction the tally may never round.
  **`sift audit` counts a search of one named file by the same rule**, as a text search of its own cause
  (`one file` under the `text search` row): `grep -n "0\.1\.0" Depot.swift` hunts a literal no digest records
  exactly as the tree form does. Every pattern has to name nothing, and a pattern with a declaration's reading
  (a column-0 `^}`, the ends of the file's top-level declarations) stays a lookup, since the hook answers it
  in place. This is accounting only: the hook still puts such a grep to its in-place answerer and lets it
  through where no answer is exact.
- **A search with no one file behind it is withheld only when no index call answers it.** That the advisor
  cannot build one neat call is not that claim, and scoring it as though it were inflates the share by
  exactly the lookups that went around the index. So a sweep is read generously about what the index answers
  (`SweepPattern`): one name in Swift-shaped company — an attribute, a declaration keyword, code punctuation —
  is `where` for it (`": UsageWindow"`, `UsageWindow?`, `.order`, `Task {`), and a capitalised one in any
  company (`some View`), while a lowercase word beside a control-flow or English word is a phrase (`for now`,
  `is empty`); a pattern of Swift's declaration vocabulary is the `search` query that asks it (`@Observable`
  is `attr:Observable`, `class .*Store` is `kind:class name:Store`, `try!` is `has:forceTry`), and a word
  beside a character class is a fragment the same way (`Transcript[A-Z][a-z]+` is `name:Transcript`, never
  `where` for a prefix); an alternation is one `where` per name in it — but **a comma list is not an
  alternation**: `UsageWindow, CatalogueStore` is a literal adjacency a search tool hunts on one line, and
  `where` for each name answers a different question, so it is text in both its spellings. What is a lookup
  holds however the sweep says it is reading Swift: with `--include=*.swift` or a `*.swift` glob, or by
  pointing at a directory that turns out to hold source. The unmarked case has a pattern as its only
  evidence, so it is a lookup only where that pattern is something one index call answers
  (`PatternReading.answeredByOneCall`): **names and nothing else** — one name by the strict reading, or an
  alternation of two or more — **or a shape built from Swift's own declaration vocabulary** (`final class` is
  `search kind:class modifier:final`, `@Test func` is `search attr:Test kind:func`). Both are read as the
  offer itself reads them, since a shape classified by one reading and withheld by another is a detour rather
  than a rule. **The boundary is the `name:` fragment**, which does not clear the bar unmarked: read off the
  pattern alone a wildcard over a token is what prose is made of — over 10,000 real searches, 61 unmarked
  sweeps read as a shape and 52 of them were markdown (`T[0-9]{3}` as `name:T`). That bar sits in the
  classification because a shape has no downstream withholding: `AdvisableName` drops a name no index
  declares, and nothing corresponds for `search kind:class modifier:final`, which is always answerable.
  **An alternation carrying a prose branch beside a name is answered for the name, and says what it leaves
  out** (`partialAlternation`). `grep -rn "UsageWindow\|stale index" Sources` is answered in place with
  `where UsageWindow` and one line naming each branch it does not cover, verbatim — `This answer does not
  cover "stale index"; re-run the identical command to sweep for that.` — and the identical re-run is allowed
  on the ledger's record. An answer that names its gap claims nothing untrue, and is no worse than the one
  grep it replaces. The reading, not `AdvisableName` (which sees only names), holds the branches the caller
  wrote (`SweepPattern.partial`). Only a sweep takes this answer: an alternation confined to the files it
  names is withheld as `severalNames` with or without prose beside its names, and one on a single file as
  `phrase`; an alternation whose every branch is prose is still text. A file's name is not a name: a pattern
  or branch spelling a path (`rules/sift.md`) or closing on the extension of a file a repository keeps beside
  its source (`View.swift`, `Base.xcconfig`) is text written about a file, so an alternation of paths names
  nothing. The extensions an enum case often spells (`.json`, `.lock`, `.log`, `.resolved`, `.md`, `.csv`,
  `.html`, `.txt`, `.yaml`, `.yml`, `.plist`) spell a file only beside a path separator. A name under three
  characters counts only word-anchored (`\bid\b`, or `-w`). A read of several named files is one `digest` per
  file, and a read of a glob is the module the glob reads (`Sources/<Module>/`), or `digest .`. Each is
  refused and counted as the miss it is. A name no index declares is still `AdvisableName`'s to withhold: a
  call standing on several names offers `where` only for those some index declares, at most five with a line
  counting the rest, and is withheld only when none is. What is left is a phrase of ordinary words, or an
  alternation of nothing else: `stale index` names no symbol however its longest word is chosen, and guessing
  at one would refuse the search wherever an index happens to declare the word it settled on. That is offered
  as a bare `search`, which names nothing to run; the hook withholds it and the scan scores it out of the
  share on the same property of the same suggestion. The property checks every target against what its tool
  accepts (a name or dotted path, the overview, a Swift file's own name or path, `field:value` terms),
  because a regex that reached a target's slot names nothing to run either. An only-matching search
  (`grep -o`) is read strictly for the same reason: it prints what its pattern's variable part matched, so
  the literal beside that part is context, and only a pattern that is one name, a declaration or a call names
  a symbol there. A name is a Swift identifier in any script (`Café`, `Über`), not an ASCII one, and that one
  definition (`IndexSuggestion.identifier`) is also how a search pattern's names are read; an emoji is no
  identifier. A file whose stem is not a name is offered by its file name, which `digest` resolves, and a
  file name with a space in it by its path. A whole read of a file none of these can name is withheld by the
  hook and scored out of the share by the scan, which ask one definition (`IndexSuggestion.digestTarget`), as
  a `cat` of the same file is.
- **A search no index answer could reproduce is withheld wherever it is pointed, one file or a tree**
  (`TextSearch.reason`) — which overturns the earlier rule that where one file is named the file is the answer
  whatever the pattern. It was measured wrong: of 163 refusals standing alone in their turn, 75 were followed
  by the identical call re-run, each a whole context's round trip bought for nothing. A digest records neither
  comments, nor string literals, nor a call site's text, so a grep of one file for prose — whitespace between
  words that does not open on a declaration's form (`stale gate is open`), or any comment marker (`MARK:`,
  `// TODO`) — is withheld (`phrase`), while a grep of the same file for declarations (`func save`,
  `final class`) is still its digest, answered in place where the shape is proven. The rest hold on either
  surface: a pattern holding a `"`, which hunts a string literal, judged over every `-e` pattern
  (`stringLiteral`); a fixed-string search for anything but a name (`fixedString`; a fixed string that *is* a
  name keeps its `where`); an unresolved merge's `<<<<<<<`, `=======` or `>>>>>>>` (`conflictMarkers`); and a
  search or a whole read confined to a tree no index holds — `.build/`, a dependency's `checkouts/`, the
  indexer's default exclusions such as `DerivedData`, or `/tmp` (`outsideSources`) — by one definition the
  audit's refusal shapes read too (`SwiftTree.isOutsideIndexedSources`). An alternation of words no index
  declares is `AdvisableName`'s on one file as across a tree: the file's digest stands on those names, and is
  withheld when none is declared (`unknownName`). **Where the offer is one `where` per name and only some of
  those names are declared, it is withheld whole** (`partlyDeclared`), because advice covering fewer names
  answers a question nobody asked, silently. Staying quiet costs nothing: the search runs. It is a logged rule
  of its own so the two can be told apart by fire rate. One file's digest standing on several names is not
  that shape and keeps its offer while any one of them is declared (`IndexSuggestion.isOneCallPerName` is the
  distinction both ends ask). **A reading stage whose output a later stage of the same pipeline filters is
  withheld last of these** (`filteredOutput`) — a `sort -u`, a `cut -d: -f1`, a second `grep`, on a search, a
  `cat` or a positional printer alike. What reaches the terminal is what the filter kept of the lines the read
  printed, and no index answer prints those lines, so the refusal could never be repaid. A line *window* after
  the read is not this: `| head -20` prints the opening of the very answer the refusal offers, and that
  pipeline is answered in place, both ends reading one definition of a window
  (`ShellQuery.windowsWhatItIsHanded`). A line window *on the file* is a window only while nothing after it
  filters. It is asked last, so it takes only what the rules above it left as a withholding and relabels none
  of them. **A search printing only file names is withheld after every one of these** (`filesOnly`): `grep`,
  `egrep` or `fgrep` with `-l`, `-L`, `--files-with-matches` or `--files-without-match`; `rg` with `-l` or
  either long spelling, never `rg -L`, which follows links and lists nothing; a short flag inside a cluster
  (`-rlw`); and a `Grep` whose `output_mode` is `files_with_matches` or absent, the tool's default. The flags
  are read from the search verb on, so a wrapper's own (`xargs -L1`) are never the search's, a word handed
  over as a flag's value is never read as a flag, and `--` ends them; each tool's list is closed, so a
  spelling missing from it leaves the search judged as before. The list is already the smallest answer to
  "which files", and it holds files whose only mention is a comment or a string, which no `where` lists. Why:
  in the `sg-live10` rename-sweep task the hook denied that `Grep` and answered with a larger `where` in 10
  runs of 10, the agent re-ran it in the shell, and the task cost 28% more session price than without sift;
  let through, it is level (+3%, an interval straddling zero). A count was withheld from the start
  (`textSearch`). Each is logged under its own rule, and the scan scores the same call out of the share on the
  same verdict, never as a miss.
  A neighbouring shape is no lookup at all, at either end: a `git grep` of another revision,
  including any word between the pattern and a `--` (which git reads as a tree), is logged `anotherRevision`
  for its fire rate. Nor is a `cat` of one file piped into nothing but windows (`cat -n View.swift | sed -n
  '1,140p'`) withheld as filtered: it is the ranged read it stands for (`ShellQuery.windowedReadPath`), judged
  as every window is (below).
- **A gate leg is run for a verdict read out of the whole log** — `xcodebuild build-for-testing` and
  `test-without-building`, and any command already redirecting to a log of its own — so no `sift run --`
  wrapping is offered for one. Not a claim that the filter would lose those lines, but that this caller wants
  the log; the action is read off argv directly, since a verdict must fail closed and a nudge open.
- **A quiet linter has no log to spare** — a `swiftlint` run carrying `--quiet` prints only its violations —
  so no `sift run --` wrapping is offered for that statement; another toolchain statement on the line keeps
  its own. Logged `quietLinter` for its fire rate.
- **A whole read of a file this context has already been served a digest of is let through**
  (`DigestedFiles`, `AdviceLedger`), logged `alreadyDigested`, which records that the digest was served, not that
  the context's copy of it is current. The refusal would offer the digest the context was served — nothing new, for a round trip priced at the whole context so far, the most expensive thing the hook
  can do late in a long session. There are two sources of evidence, because neither alone covers every route.
  The usage log's line for an answered `digest` under this session and this agent counts only where it served
  the digest the refusal would offer: answered from the repository the file is in, a type or file digest (the
  only answers that record `srcBytes`, so never a member's source, a candidate list or a miss), naming the
  file itself or, as its final component, the type the file is named for; only the end of the log is read, and
  a digest older than the bound is missed and the read refused, the side a miss is allowed to fall on. But a
  digest run from Bash cannot be attributed there (the CLI knows the session but never the agent), so the hook
  also records the digest targets a context asks for — an MCP `digest`, a Bash `sift digest` (its `--root`,
  else the repository the literal `cd`s in front of it moved to, else the caller's), and a digest the hook itself
  answered in place — in that context's ledger, filed by the repository answered from, at the one moment it sees
  both the call and the context. A Bash digest whose directory a move on its line leaves unknown — a subshell,
  `pushd`, `cd -`, a substitution, a pipe the move is in, a statement behind `||` — is recorded nowhere (#358): the caller's
  repository could be the wrong one (`(cd R && sift digest Big)` is `R`'s `Big.swift`), and a digest left out
  costs one answered read, never a wrong suppression. A line with no move on it is the caller's, whatever its
  shape. The transcript scan keys a Bash digest by the same reading. Without it,
  a subagent's `cat -n` of a file it had just digested was answered with the same digest and the agent re-ran
  the identical command to get the source: about ten forced turns across three makers in one session, each
  re-sending a 60–150k context. A whole read (`Read` with no range, `cat`, `cat -n`, several in one command,
  one riding alongside something else, or run from another directory — every shape an in-place answer covers)
  of files every one of which a recorded target names is allowed before the ledger decides anything. A target
  names a file by the path in any spelling the renderer resolves, exactly, or, for a bare name, only where the
  index at that repository resolves the name to exactly this file, never by its stem alone; where the index
  cannot resolve the name, the read is refused as before. Per context (a subagent's window never held its
  parent's digest) and per file; a file changed on disk since is still let through, since the context wants
  current text either way. **A held digest never lapses** (#545), on four findings: the ledger keeps its targets
  with no served time, so a lapse could reach only the usage log's holds and the two records would disagree; a
  modification time is not content — a checkout, a rebase, a patch set aside and restored, a formatter and a
  `touch` all move it with the text unchanged, and a spurious lapse is a refusal offering the digest the context
  holds, the round trip this rule exists to save; a missed lapse costs only the log label, since the read prints
  the current source; and the usage log's `ts` is the second the answer was logged, by the wall clock even in a
  replay, where the ledger runs on the transcript's, so "served before the change and the change before now" has
  no one clock to be asked against. `srcBytes` is no proxy either: only usage-log lines carry it, and a same-size
  edit leaves it alone. So `alreadyDigested` reads as "a digest of this file was served in this context", never as
  "the context holds this file's current digest". Recorded before the call is answered, since a hook never sees an answer, so a
  digest that failed still counts, the side a missed refusal is allowed to fall on. Searches are unchanged by
  it.
- **A window of a Swift file no index call in this context has located is a lookup, answered in place with the
  file's digest exactly as a whole `cat` is.** A shell window — `sed -n '1,200p' F.swift`, `head`, `tail`, an
  `awk` program picking its lines by number, a `cat` piped into nothing but windows — and a `Read` with
  `offset`/`limit` of a `.swift` file (lines `offset` through `offset + limit - 1`, `limit` 2000 where only
  `offset` is given) are the same in-place call as the whole read, with the "re-run the identical command if
  you wanted its raw output" line (a window's keeps that suffix, unless it reaches every line of the file, which is
  answered as a whole read and carries the figures; only a whole read states its re-run's cost, and a file of more
  than 2000 lines, the default `Read` limit, keeps the old suffix, its identical re-run printing no more) and
  the identical re-run allowed by the ledger. The reason it is a
  lookup: agents stopped reading whole files and read windows instead, and the share fell from about 80% to
  43% while the hook said nothing about them (`noLookup`). **A line of several windows or whole reads of Swift
  files** — joined by `;`, `&&` or line breaks, with no other command on it and no pipe into a filter — is one
  lookup, answered with **one digest per distinct file the context has not located, in the order first
  named**, under the same size budget as several whole reads (`overSize` beyond it); several windows of one
  file are one digest. **A window is answered only where the answer is smaller than the window**: the whole
  refusal, framing included, is weighed against the bytes of the lines the command prints, read from disk (for
  several windows on a line, their sum, a part that weighs no source left out of both sides), and where the
  whole digest is not smaller, the members the windows overlap (below) are tried under the same test; where
  neither is, the window runs as `notSmaller`. The weighing reads what the candidate's own reason would say,
  not only its bytes: a candidate whose closing line would settle on its "No saving: " prefix is withheld as
  `notSmaller` too. **The closing line states the refusal's own size, or claims none**: it prices the text it
  ends, itself included, so it is written at the one length whose figures are the finished text's own; where
  no length is, a read is withheld as `notSmaller` rather than served with a figure a byte or a token off,
  while a declaration grep or a name lookup is never withheld for this and closes on the line that claims no
  saving. **A whole read is weighed like a window**: an answer no smaller than the file it stands in for is
  withheld as `notSmaller`, priced against the file's size on disk, and a small file's digest gives way to its
  own source, framed, which is always bigger than the file, so a whole read of one runs. **On a line of
  several parts, each windowed file is also weighed alone**, its digest against its own windows' bytes and,
  where that is not smaller, its members in the digest's place, so a whole read's saving beside it never pays
  for a digest bigger than the window; where its members are not smaller either, the line is withheld as
  `notSmaller`. Nor does another part's saving pay the floor below for a file whose lines the answer does not
  show: each such windowed file saves `windowSavingFloor` against its own windows' bytes, its listing weighed
  without the framing the line shares, or the line runs as `linesNotShown` (#425). A window that runs alone
  can still be denied beside a large read for that reason, since alone it is weighed with the framing it would
  carry on its own. Where one file's windows fall short while the line saves enough, the members answer's note
  names that file and its saving, not the line's. Whole reads on the line keep their own rule. The saving
  line is priced against those lines,
  never the whole file, and so is the usage log's `source`, since an answer that costs more than the window
  and still claims a saving is followed by the identical re-run. **A window whose answer would not show its
  lines runs as `linesNotShown`**: one reading only a declaration's leading doc comment (a digest line carries
  a doc comment's summary at most), one whose members answer would name a single member and nothing else,
  beneath its containers' headers (that member's declaration line, which the reader who chose the window already knew; a member whose answer carries a SwiftUI view outline is a summary of its lines and stays answered;
  decided on what the answer prints, so a window reaching past the member onto a blank or brace line counts;
  `digest File.swift:a-b` there serves the whole member, bigger than the window), and any window saving under `windowSavingFloor` (4 KiB) whose answer does
  not hold the text of every non-blank line it prints — a denial that cannot stand in for the read makes the
  identical re-run certain, and a week of real sessions priced letting such a window run, under 4 KiB, cheaper than answering it (#480). **A window the hook lets run
  as `notSmaller` is not worth answering, and out of the share**: answering it would save nothing, so it is
  neither a miss nor a lookup won. The replay counts it on a `not worth` row of its own and takes it out of
  the replayed share's denominator (below). The live audit counts one as not worth only where the hook's
  suppression log records that verdict for that very call: the hook writes the call's `tool_use_id` into the
  `answerWithheld` entry, since a call the hook lets run leaves no mark in the transcript and weighing each
  cold window against a digest again would mean recomputing digests of files long changed or gone. So a window
  the log names no call for is still a miss in the live audit, and the log is never trimmed. The replay re-judges every cold window itself. A line the
  hook lets run whole as `otherStatementsRun` is read off the log the same way and counted as a miss on a
  `batched` line of its own under `cold`. A window whose lines cannot be read off the command (`head -c`, a
  flag not modelled; `LineWindow`) has nothing to be weighed against and keeps the whole digest. A shell
  window is answered only where every stage is on `FallbackProof`'s closed list of forms seen to exit 0 doing
  nothing but print; the list being closed, harmless forms nobody ran here (`head -c 5`, `sed -n -E`, an `awk`
  body with `printf`) are let through too. An `awk` action must also print each line it picks whole, numbered
  or not, since `{print $1}` and `{print NR}` exit 0 but print text the file does not hold as its lines.
  **A window of a file holding an unresolved merge conflict marker at a line start** runs as `conflicted`, a
  ranged `Read` as much as a shell window, since nothing but the raw text shows both sides of a conflict. **A
  read of a file indexed with a parse error is never answered in place either** — whole or bounded, alone or
  on a compound line — and runs as `parseError`, since a digest built over a parse error is not the source the
  command would have printed. **Where those digests are over the budget, each window is answered with the
  members its lines overlap instead**, rather than withheld. Each distinct range is one call, answered with
  the lines a file digest prints for the members the range overlaps — signature, range, doc summary — under
  the header of each type enclosing them; a range in no member is answered in the wording `digest F.swift:N`
  gives there, the container it is in and the nearest members before and after it, or, outside every
  declaration, the nearest top-level declarations. **What is displayed and what is recorded differ on
  purpose**: the opening line names the call it served the answer with, `digest F.swift`, with a note outside
  the backticks (only the members of lines a-b are shown; the whole digest is over the size budget, would be no
  smaller than these lines, saves under 4096 B, or is larger than they are), since what actually
  answered is the file's own digest, cut down to what fits. The reason is the first check the whole answer
  failed, in the order it is held to them, never one that does not hold of it (#398): over the budget; no
  smaller than what it weighed, or closing on a line saying it saved nothing; or, standing in for lines it
  does not show, saving less than the floor. Where a file read whole on the same line weighs in too, no one
  window's digest is what fell short, so the reason is said of them together: the whole digests save under
  4096 B, or would be no smaller than the output. Each reason is worded no longer than the one it replaced,
  since the note is part of what the members answer is weighed as. The no-smaller reason is said in the
  conditional, of a digest that was not served (#507): worded as a fact it read as the served answer's own
  verdict, against the closing line, which is the only verdict on it. The ledger and the usage log keep the real target, `F.swift:a-b`, so a bounded
  answer counts as locating the file (a window read afterwards is let through) and never as its whole digest (a
  later whole read is still answered in place, `DigestedFiles.isDigested` requiring a whole-file target). The
  transcript scan reads the same note back off the opening line. **A bounded answer is withheld where it costs
  more than the lines it stands in for**, measured as the whole refusal, framing included, against the window's
  own source, and the whole answer's own withholding stands in its place. Where several files are bounded on
  one line, the note names each bounded file beside its ranges, and only those are credited as located rather
  than digested; a whole read on the same line keeps its whole digest. **A window's members answer it wherever
  they are strictly smaller than the whole digest** (#357), paged or not, under the budget or over it: the
  digest answers a question about the file, the members the one the window asked. Alone on its line, the
  members answer has to be smaller both as listed and as the whole refusal the caller reads, framing and note
  included, so two answers differing in their notes alone, or tied, keep the whole digest; a line of several
  files is weighed as one, every window's members against the digests the line would otherwise serve, since its
  framing, a module notice included, is shared. The note then says the whole digest is larger than they are.
  On a line of several files, a members answer's note also keeps the reason each file whose digest was already
  set aside for its window's members was set aside for (#396) — no smaller than its lines, a first page
  stopping short of them, or naming them without their lines — ahead of its own, each said once, in the line's
  order, joined by `or`. Those reasons are weighed as part of the answer too, so a note of several can tip a
  borderline line from answered to run: each further reason's words come off the line's saving, so a line
  that clears the 4096 B floor with one reason can fall under it with two.
  **A window over a file's imports keeps the whole digest or runs**: the digest's `imports:` line accounts for
  the `import` lines the window prints, where the members answer leaves them without a trace, an answer that
  does not account for every printed line, so those members are never served. Where the whole digest would be
  served, it is; where it would not — saving less than the floor, no smaller than the lines, a first page
  stopping short of the window, or a digest naming its members without their lines — the read runs, for the
  whole digest's own reason (`linesNotShown`, `overSize`, `notSmaller`, `notExact`). Over the budget, the
  digest's first page cut to fit stands in where it reaches the window and saves the floor (below), and the
  read runs as `overSize` where it does not. On a line
  of several files, one such window keeps the whole digests for the line, or the line runs. So a whole- or
  most-of-file window (`sed -n 1,9999p`, `2,180p`) of a file with imports keeps the whole digest or runs; of a
  file without them, or starting below them, it
  is answered with its members, usually the smaller since they leave out the file's header and any notice its
  digest carries, and, being bounded, they locate the file without digesting it, so a later whole read of the
  file is still answered in place. A whole read has no window and keeps its whole digest, and a bounded answer
  still over the budget is `overSize`.
  **A digest over the budget is answered with its first page cut to fit** (#605). Where the one file a read
  names has a whole digest whose refusal runs past the ten-thousand-byte budget, and no members answer is served
  in its place, the answer is that digest's first page cut to the most member lines that keep the whole refusal,
  framing and closing line included, inside the budget, ending in the `truncated:` marker that pages it, spelled
  for the face the answer names. The cut is made on counted member lines, as every page is, and only in the hook:
  `sift digest` and the MCP tool keep their sixty-line page, and the cursor pages on from member line K at that
  size, so the continuation is the ordinary paged digest. The cut page is served only where it saves at least
  the 4096 B floor on what the read would print, since a page that does not show every line asked for is
  followed by a further call, and only where a page may stand in at all: for a window, only where the cut page
  reaches every member the window overlaps. Short of either, the read runs as `overSize`, and the log names the
  whole answer's size against the budget, as before. The page is recorded as the file's digest, as a sixty-line
  first page is, so a ranged `Read` of the file afterwards is let through and the identical re-run passes; the
  `notWorthTheTurn` rule weighs the page as D. A line looking up several files is never cut: over the budget
  it runs as `overSize`. A lone lookup on a line with other statements (`cat F.swift && echo done`) is cut
  like any other single-file answer, and so can be the leg `judgedAlone` judges. The cut is made only where
  nothing cheaper ends the read: a read that would end `linesNotShown`, `notSmaller` or as members, or be
  served whole, renders no extra page, and the size is found from an estimate in a few renders, reach being
  asked once of the page that stays. Measured on 5 Oct: chain-1's one `overSize` read printed 48,791 characters, and its session cost
  99k against a median of about 41k.
  **The whole digest, paged or not, stands in
  for a window only where it gives every member the window overlaps a line of its own, with its range** (#337,
  #357). A paged digest does so only where its first page reaches the window: past the first declaration the
  page leaves for a later one, the page stops short of some of what the window prints (the members answer's
  note: the whole digest's first page stops short of some of them). Nor does a digest that names a nested
  type's members on that type's line alone (`struct Inner — 10 members: n1() … n10()`), which places none of
  the lines a window over them prints (the note: the whole digest names some of them without their lines).
  Either way the members answer stands in, or, with none or with a window over the file's imports, the read
  runs as `notExact`.
  Windows of a file the context has located
  are no lookup, so a line whose every file is located is `noLookup`. Where only some of the windows are of
  such a file, they are dropped (`InPlaceShape.Match.droppingWindows(where:)`) and the rest is never answered:
  the dropped windows print lines no answer to the rest reproduces, so the line runs as `otherStatementsRun`,
  with the note naming the call for the files not located (#517). It is not set aside whole as `noLookup`,
  which would lose that note and the audit's `batched` row. A whole read the hook would let through standing
  alone — a `cat` of a file whose whole digest the context holds (`alreadyDigested`), or that it wrote
  (`written`) — is dropped from a line of several reads the same way (`InPlaceShape.Match.droppingReads(where:)`),
  so `cat Shell.swift; sed -n '5,40p' Other.swift` runs as `otherStatementsRun` rather than being denied with the
  digest of `Shell.swift` the context already holds in place of its source; a line where every read is so held is
  let through as `alreadyDigested`, or as `written`, noting nothing, where a whole read on it is held only because
  the context wrote the file, whose digest it does not hold (#538). Either record of the digest lets a shell line's
  reads through alike: a bare `cat`, or `cat Shell.swift; echo done`, of a file whose digest only the usage log
  holds is `alreadyDigested`, not answered with that digest (#538). The identical re-run is allowed on every window the answer
  covered. **Once the file is located — this context was handed a digest of the file, or of a type declared in
  it, by the same test a whole read is let through on — every window of it is `noLookup` and nothing is
  noted**: that window is the second half of the loop the digest began, where a whole read of the same file is
  let through but still counted (`alreadyDigested`). **A `where` or `search` answer that listed the file
  locates it the same way**: whoever serves one — the server, the CLI, the hook's own in-place answer —
  records the files it listed on its usage-log line (`located`, repository-relative, read by
  `DigestedFiles.locatedFiles`: a `where` answer's declarations and reference lines, never its name-matched
  call sites, and a `search` answer's file headings; nothing for an answer as of another revision), and
  `DigestedFiles.locates` matches a window's file against them under the same session, context and repository
  a digest is matched under. It locates for a window only, never a whole read, and a line written before the
  field existed locates nothing. **Nor does anything but the file's whole digest locate a window printing more
  than 200 lines of it** (`ListedWindow.widestExcused`): such a window is judged exactly as a cold one is —
  answered with the whole digest or the members it overlaps under every rule above, or run for their reasons.
  Only the whole digest (`DigestedFiles.contains`, the one that excuses a whole read: the file's path, the type
  it is named for, or the one file a path digest served) still locates every window of it, however wide, since it
  has already handed the context the member map such a window would be answered with. A `where` or `search`
  listing, a module digest's file heading, a digest of some of its lines (`F.swift:455`, which may answer with
  nothing but the nearest members), a member's digest, and a digest that resolved nothing all locate a window of
  200 lines or fewer as before and no wider one: a member digest could excuse a wide window only where its
  served members provably held the window's lines, and no usage-log line records where a member lies, so none
  does. A listing names a declaration's or a reference's line and nothing of the members around it, so a window of
  hundreds of lines beside it is the file read through a window, not the ranged read the listing pointed at. In
  a paired benchmark, three of six runs followed a `where --refs` with one `Read` of lines 1–520 of a
  1,190-line, 100 KB file, 48.8k characters let through as `noLookup` for ~22.7k tokens of context, and then made
  ranged reads outside it; the runs that took a digest instead cost what the arm without sift did. 200 lines is
  ten members of twenty, room for the ranged read around a listed line and its neighbours, and well short of
  that window. The width is the lines the window prints of the file on disk, every window of the file on the
  line together (a `Read` past the end prints to the end); a window whose lines cannot be read off the command,
  or a file that cannot be read, stays located. The replay feeds the same credit from the transcript's answer text
  (`TranscriptReplay.answerKey`); the scan, which reads answers by file name, scores such a window guided. A
  window of a file the digest floor would serve as source is let through as the whole read is, a window whose
  lines a later stage filters stays the filtered read above, and a document's ranged read is unchanged — its
  outline's section ranges are what located it.
- **An offer this context has already taken up** is not made again (`AdviceLedger`). A refusal alone in its
  turn costs a whole round trip, and where the call it names is already answered in that context, the
  sentence is one the context has read and acted on; a large minority of such refusals were followed by the
  identical command re-run unchanged. The test is the *offered call*, never the symbol behind it — a context
  that digested a type and then greps for its callers is asking a question the digest did not answer, and
  only a `where` already made makes that offer redundant — and every line of a multi-call offer has to have
  been made, so an alternation answered in part, or an offer capped with a line standing for calls it does not
  list, is still worth saying. What a context asked is recorded at the one moment an index call and the
  conversation that made it are visible together, the same payload the reset is read from.
- **An offered call already made but not yet answered holds the lookup back with a pointer** (#606). The
  offered-call rule lets a lookup through where the context has already made every call its refusal would
  offer, since that answer is in the context. A call sent in the same message as the lookup is made but not
  yet answered: in the 5 Oct paired run, 10 of 20 sift-arm conformers runs sent `where <Name>` and a Grep for
  the same name in one message, all ten `where` first, and paid for both answers. So where an offered call
  was noted within the last 60 seconds and the context's own transcript — a subagent's own file, never its
  parent's — holds no tool_result for that call's `tool_use_id` in its tail, the lookup is refused with a
  pointer instead of let through: ``sift held this lookup back — already called in this context: `where X`,
  whose answer covers it. Re-run the identical command for the raw output.`` Where the call was the hook's own,
  an answer given in place to a lookup of the same message, the line opens ``sift held this lookup back — already
  answered beside this:`` instead, since the context never called it; the ledger notes each call with whether the
  hook made it (a note written before that was kept reads as the context's), and a pointer naming both kinds
  names the context's calls under the first wording and the hook's in a second sentence, ``Also answered beside
  this: …``. The transcript scan recognises both openings. It is the one refusal that
  names a call without carrying its answer, and the exception to "nothing is refused with a bare call this
  instead" for the reason that rule exists: a bare refusal costs a round trip, and this one costs none, since
  the answer it points at arrives in the same batch of results. Where the signal cannot be read — no
  transcript, a transcript that is missing or cannot be read, a subagent whose own file is missing, no recorded
  id, the result already written, or a call noted over 60 seconds ago — the lookup is let through as before.
  The tail read is the last 64 MiB, which nothing writes in a minute, so a result written within the window is
  inside it and a result not in it is not written. A call whose use line is not yet written is held like one
  whose result is not, since the harness writes the use line late as well: a fast hook runs before it lands. A call is made only as
  a plain statement: a CLI call behind a pipe, a redirection, a chain or a trailing `&` is not, since its answer
  is not the whole one. A ranged `Read` is never held back, and neither
  is a lookup beside other statements of a shell line, whose output a denial would swallow. The identical
  re-run passes, as after every refusal. A whole read of a file whose digest is in flight meets this hold
  before the already-digested rule: a digest whose result is not yet written is not held by the context, and
  the repository the offer is pinned to is found without depending on a `git` finishing in time, so the
  verdict never depends on load. The transcript scan reads the pointer by its own stem: the lookup is
  retracted and counted as indexed, and its key sanctions the re-run; it is not an answer in place (no
  `answered.jsonl` entry, no marker, no bytes credited) and not a refusal priced as a round trip. Claude Code
  2.1.289 ran one message's hooks in order and wrote results to the transcript late, so the other order — a
  lookup answered in place with the very call the same message makes next — cannot be told apart here and is
  not handled (none of the ten). A probe sees it as the `held` verdict with the rule `inFlight`.
- **A repository with no index of its own draws a nudge like any other, and the index is built on demand**
  (`RepositoryIndex`, which holds only the rule below). The earlier rule was *no index, no nudge*, on the
  premise that the offered call would have to walk and parse a whole checkout first. **The premise was false
  where it mattered.** Indexing from nothing was measured at 0.4–0.7 s (this repository 0.41 s, the largest
  app repository on this machine, 878 Swift files, 0.74 s), inside a hook's own budget. What the rule cost was
  the entire population the hook exists for: every isolated subagent runs in `.claude/worktrees/<agent>/`, a
  repository of its own that nothing has ever indexed, so the hook was silent for that agent's whole run. So
  a path in an unindexed repository now reaches the refusal and the in-place answer exactly as one in an
  indexed repository does, and **whatever answers builds the index it needs**: the in-place answerer opens an
  engine on the caller's own root and brings it up to date (`InPlaceAnswerer.compute`), and the `digest` a
  plain refusal names indexes on its first call as the CLI always has. The hook's existing budgets keep that
  honest — an index build past the in-place time budget is abandoned where it stands, the back-off holds that
  shape off in that repository for the window, and the plain refusal stands. An abandoned build leaves a store
  that opens at the current schema with nothing indexed into it (0 files, no `indexed_head`), and that store
  counts as no index at all, exactly like a missing one (`ReadOnlyIndex.hasUsableIndex(atRoot:)`,
  `AdvisableName.couldAnswer`), or the name probe would find the empty store, answer "not declared here" for
  every symbol, and silence the hook for the rest of the tree's life. **The offer is rooted at the tree the
  lookup itself names**, never at the checkout a worktree was cut from: the root comes from `CallerRoot.root`
  over the lookup's own anchor — the path a read or a search names, and otherwise the directory the call runs
  in — which is `git rev-parse --show-toplevel` and so resolves a linked worktree to itself. Distinct from
  the compression floor, which is about one file's size rather than about a tree: a short file draws no
  nudge wherever it lives.
  **But a call that names a path, in a tree with no repository at all, draws no nudge**
  (`RepositoryIndex.isRootless`, logged under `noRepository`). A call naming a path is answered by reading
  that exact path *under a root*; with no root the answer would be `… is in no repository to root at — read it
  directly`, the read the refusal just denied, charged a whole context re-send to arrive at. The question is
  asked of the offered call's own targets, not of the tree the caller stands in (`digest View` names a symbol
  and resolves out of the caller's own index; `digest /notes/Plan.md` can be answered nowhere), and only of a
  path that exists. A document outside any checkout, such as a vault note or a rule file, is the everyday case.

**A rule that withholds a suggestion the metric would still count must be asked by the metric too, or the
number stops meaning anything.** A search the hook declines to claim it could serve, still counted as a
lookup the index lost, lowers the share by exactly the amount the judgement was right — so the two ends ask
one predicate (`TextSearch`), as `AdvisableName` already does, and the withholding happens at the seam that
already logs one. Both search surfaces ask it: `grep -c` and `Grep(output_mode: "count")` are one question,
and a refusal on one spelling that is silent on the other teaches a model where to go to avoid it.

Some rules need no such agreement. **A payload and a listing are not lookups by either end** (`gh issue
create`, `ls -R`): nothing was withheld, so there is nothing to log. **A gate leg is outside every share**
(a toolchain run enters no denominator) yet is recorded in the suppression log, because the fire rate is the
only evidence the rule is not over-firing. **A read after its digest is counted on purpose**: the index
could have served it, and did; the read is the cost of going around the answer, which is what the tally
exists to report, so the scan files it as a read whole after its digest whether or not a refusal came first.
**An offer already taken up is counted the same way** and stays in the share; only whether the hook spends a
turn saying so changes. It is a decision of the ledger's, logged nowhere, like the identical re-run and the
quiet spell, and reaches a probe as `allowed\t\tledger`.

**The reset has to be as per-context as the counter, and there is one place on the machine where it can be.**
The logs cannot serve: a line in `usage.jsonl` or `run.jsonl` carries no conversation identity, and a
subagent's MCP calls are indistinguishable from its parent's at the server, so a reset read off them would be
machine-wide. A hook payload does name the conversation, so the `PreToolUse` matcher covers this server's own
tools, about which the hook has no opinion and from which it only learns — one short hook run per index call.
Reaching for the binary in the shell counts identically (`sift run --`, a bare `sift where`, a command
substitution's body included), since it is the only route left to a context whose allowlist stripped the MCP
server; the hook, the scan and the advisor ask one definition (`ShellInspection.invokesSift`).

**No diagnosis, and no quiet spell for a run of unheeded denials.** Once the hook answers a lookup in place
or lets it through, the only denials it prints are the answer itself, which the ledger records as an index
call on the next line, and a build's `sift run --` wrapping; a context that cannot reach the index is handed
the answer anyway, so "you cannot reach the index" diagnosed a condition the hook now compensates for, and an
answer resets the run it adds to. What is left is the identical re-run, the offer already taken up, and
`nudgeCap`, the runaway guard whose spell expires: fifteen minutes the first time, doubling to a two-hour
ceiling (`AdviceLedger.baseQuietPeriod`, `maximumQuietPeriod`). `RegisteredHooks` survives as a doctor line,
since a stale matcher still hides this server's own calls from the hook. **The check that finds a context
shut out of the index before it costs anything is `AgentAllowlist`**, read by `status` and `install-hook`:
an absent `tools:` inherits every tool and is correct, `tools: "*"` is correct, and an explicit list this
server is missing from is a defect.

**A saving is an estimate, and is stated with its baseline.** `usage`, the report page and `audit` each print
it as `~4.9M tokens saved (est. vs whole-file reads)` (`TokenEstimate.savedLabel`, the one wording they
share). Its bytes are measured, each
digest's source less what it served, but its baseline is a counterfactual: that the agent would otherwise have
read the whole file (for a type digest, the type's whole extent), where a grep or a ranged read would often have
cost less. So the whole-file baseline leans high, and the figure is a floor only in the sense that calls which
weigh nothing are left out of it: `where`, `search` and `strings` record no `srcBytes` and contribute nothing.
Tokens are bytes over four, a fixed ratio, never the model's tokenizer. **The saving is stated gross, and says so.** A file read whole after its digest —
by `Read`, or by a shell `cat`, `cat -n` or every-line `awk` of it, the whole reads the hook answers in place
(`ShellReadAfterDigest`) — stays in the share's denominator as a miss, `read whole after its digest`. Its digest's
saving is not subtracted from the figure: `audit` and the report page print one plain line beside it counting those
reads, the share's own `read whole` count (`TokenEstimate.readAnyway`), and price none of them; `usage` reads the log
alone, so it says its figure is gross and points at `sift audit` for the count. **Why gross:** netting meant joining
each digest a transcript records to the usage-log line that priced it, by session, face, target and the second it
was written, and that join is fragile — three review rounds each found it overclaiming or underclaiming in a new
way. A number that cannot be shown right is not shown. An in-place answer is the one exception:
its own closing line states its sizes, so `audit` withdraws exactly their difference when the file is read anyway
(`AnswerThenRead`). Each face states the baseline once (`TokenEstimate.baseline`) and the basis beside the figure,
`8.7 MB gross at 4 bytes a token`, so the arithmetic can be checked.

**"The lookups that had a choice" is a claim, and a lookup made where the index was not reachable is not
one of them.** A subagent transcript is its own context with its own tool list, and an allowlist like
`tools: Read, Grep, Glob, Bash` strips every MCP server from it: it receives the guidance, takes the
refusals, and holds nothing it was told to call. **The verdict is reached per context and at render, never
per lookup and never at fold**: the scan is append-only, so a lookup classified early could not be
reclassified when a later line makes an index call, whereas a verdict taken from the whole transcript's
counters simply comes out differently on the next render. **The direct evidence is the tool list itself,
where the transcript records it whole**: the tools a context is sent in full are in a `prompt_snapshot`'s
`tools` (this server's normally appear there, being marked alwaysLoad, §4), and the tools held back go into a
`deferred_tools_delta` (this server's only from a client that ignores the mark); the snapshot offers
`ToolSearch` only when something is held back, so a tool list with no `ToolSearch` is whole on its own and
one offering it is whole together with a delta. A context that never reached the index by any route and
whose whole list names none of this server's tools is judged unreachable however few refusals it took
(`recordedToolListWithoutIndex`). **Anything short of that is a transcript that has not said, and silence is
never read as absence**: no snapshot with a tool list, a snapshot offering `ToolSearch` with no delta, or
the server reported failed with no list at all (a failed server can be reconnected, so the failure says why,
never whether). Checked against 230 contexts, no context whose record lacked sift ever had an index call
answered. Where the list is not on record whole, the evidence is a run of twelve refusals with never an
index call between them, set well above the usual delay between a first refusal and a first call. A failed
index call counts as reaching, since making one proves the tool was there. **A call the harness answered
with `No such tool available` is not a failed call**: it never reached the server, so it is neither reported
against the tool nor taken as proof of access, and it counts towards the floor beside the refusals (the live
hook never sees how the harness answered, so cannot weigh it). **A call the permission check stopped is
neither a failure nor a miss**: declined at the prompt, or not ruled on in time by the auto-mode classifier,
it is reported on its own `declined` line, never enters the share, and counts as reaching, since only a tool
the context holds is asked about. These lookups leave the share and enter a bucket of their own on `audit`,
because a denominator that shrinks with nothing said about it is a count under-reported
(§6 of the answer contract). The floor is one-sided by design: a context that has not called *yet* is never
excused, which keeps the share a floor.

**`audit` names the cause per context, because the causes have different fixes.** The transcript records
the harness reporting this server as failed in that context (`failedMcpServers`): the server never started or
dropped, and the agent definition is not at fault. Or the session's own context never held the tools (its
whole list on record without them, or the server failed with none arriving): the session had no server to
give any agent, whatever a subagent's own transcript recorded. Only where neither is on record is the tool
list the likely gap, and the durable fix the definition that spawned the context. A session whose
`SessionStart` hook exited 127 on this binary's `session-start` registration had no binary when its server
launched, and the report says so. A context whose list has no sift but which ran the `sift` CLI was within
reach, so it is not in the bucket and is counted on a line of its own.

**What counts as an index call is one prefix, read everywhere from one place** (`IndexToolName`): the
transcript classifier, the scan's byte pre-filter, the hook's check that a context took the advice, and the
root amendment. A call the scanner fails to recognise is read as no call at all, which under-reports the
tool (§6) and files the context as holding no tools.

**`usage` and `audit` are how all of the above is judged, and they read different halves of it.** `usage`
summarises the two per-user logs — calls by tool, root and day, latency, top targets, wrapped runs in a
section of their own — and can say how often the tool was used but never how often it should have been.
`audit` reads the transcripts, which hold both sides, and names the misses: first touches of a Swift file
with no index call locating it first, subagents included, with the reads a digest sent someone to reported
separately and not counted against the index. **An index call locates a file only once it answers**: one
declined, never delivered, not ruled on in time or failed located nothing. A `sift digest` run from Bash
locates what it names once its line comes back without an error, and that error stays the line's, never
filed as the index failing. It locates only what it resolved: the sites a `where` lists by name match where
the store cannot answer are leads, not locations. A re-read of a file already open in that context is
neither, in either spelling: a shell window (`sed -n '120,160p'`, `head`, `tail`, an `awk` picking lines by
number, or a `cat` of one file piped into nothing but such windows) is scored as the ranged `Read` it stands
for, and makes the windows and ranged reads of that file which follow it re-reads. That holds inside a
subshell or command substitution, whose body is read as commands of its own, and with a closing `)` written
against the file name, which ends the word there as the shell does. A body is *the* lookup only where no
statement outside every substitution reads Swift: in `grep -rn Name --include='*.swift' Sources
--exclude="$(head -1 Names.swift)"` the lookup is the sweep, at both ends, at every depth. A substitution
spelled where it does not run (single quotes, behind a backslash) is characters and reads nothing. A window
never makes a later whole `Read` a re-read: a window put only its lines in context, and the whole read pays
for the file in full. Standing for a ranged `Read` includes the floor: a first window of a file below it is
below the floor, never cold or guided, except where the file cannot be spelled out in full (a relative path
behind a `cd`, or a line with no directory), which is never probed. **Whether a first touch was below the
digest floor is read off the transcript wherever it can be**: a whole-file digest's answer says in its own
text whether it served the file's source, and that record outlives a worktree the disk does not. A type's
digest decides nothing about its file. The answer names its file by a path R relative to the root that
answered, and the transcript does not record that root, only the call's *anchor* (its `root` argument, else
the directory it was made from), the header's `tree:` field, and for a call resolved from above every
repository a note naming the repository. A read at absolute path P is decided by the digest exactly when P
ends with R by path components, X (P less R) is the resolved-to path where the answer carries one, else the
anchor or a directory above it, and X's own name is the header's tree name (the worktree's when the field
reads `(worktree <name>)`); where the header cannot be read, X is the anchor itself. Comparison ignores case
where the anchor's volume does (`volumeSupportsCaseSensitiveNames`). So `/work/big/…` is never decided by a digest asked from `/work/small`, a
repository's files never by a digest a nested worktree answered, and the reverse. Three residuals are known:
a worktree nested in a repository of the same name (or the reverse) can't be told apart by name; a
subdirectory between the root and the call's directory carrying the tree's name (`Foo/Foo`) is taken for the
checkout by the suffix match; and a checkout reached through a symlink under another name decides none of its
own reads, the opposite error, toward a lower share. A digest with neither an absolute anchor nor a
resolved-to note records nothing. Only a first touch with no such answer is judged against the disk as it
stands, and the audit says how many were, and how many of those files it could not read. Both are
pseudonymised by default so a report can be shared as it is, `--unredact` prints the real names, and `report`
(§3) is the same material as one page on disk.

**`audit` prices each refusal by the round trip it cost, not by its text.** A refusal's own result is a few
hundred bytes; what it costs is the turn the context takes to act on it, which re-sends everything the context
holds, from tens of thousands of tokens early in a session to most of a million late. Where the refused call
was the only one in its assistant turn (the `message.id` its blocks share), the refusal is charged what the
next turn re-sent, as the harness records it in `message.usage`: measured, not estimated. A refusal that
shared its turn is charged nothing, since the next turn was coming anyway; nor is one the transcript ends on,
or one answered in place. `audit` prints how many refusals were alone in their turn, the total they
re-sent, and the costliest few with the context each was given in.

**The re-sent total is priced by what it costs, not by its raw size.** A cache read is a tenth of the
uncached input rate; a cache write is more than uncached input, 1.25× for a five-minute entry and 2× for a
one-hour one. `RoundTripCost` carries the four figures separately, read from `message.usage`'s
`cache_creation` split where the harness wrote one, and otherwise the flat `cache_creation_input_tokens`
as a five-minute write, the cheaper of the two. `inputEquivalentTokens` applies the multipliers and rounds
once; it is a price comparison against the uncached input rate, never a token count, and `audit`'s headline
leads with it while keeping the raw total beside it.

**What followed each lone refusal is classified** (`RefusalFollowUp`), from the next `tool_use` block the
transcript writes after it: `reRun` for the identical tool and input (the refusal bought nothing), `index`
for an `mcp__sift__*` tool or `sift digest`/`where`/`search`/`strings` from Bash (it redirected), `other`,
and `ended` when no further call exists. A refusal that shared its turn is excluded, as it is from the
pricing. `audit` prints a count and the input-equivalent tokens for each class, so a hook fix shows up as the
`reRun` count falling and the `index` count rising. Lone refusals are also split by where they happened: the
main context, a subagent whose transcript ever recorded one of this server's tools as callable, a subagent
whose whole tool list is on record without them, and, only when there is one, a subagent whose transcript
settled neither (`TranscriptTally/recordsWholeToolList`). Both places the harness records tools are read
(a `prompt_snapshot`'s list and a `deferred_tools_delta`'s `addedNames`), since a deferred tool never appears
in a snapshot and reading the snapshot alone counts nearly every such subagent as never having held them; a
subagent with no tool list at all is its own bucket, not folded into "never held them".
`couldNotReachTheIndex` reads `recordedToolListWithoutIndex` (the list recorded whole *and* missing this
server), only after asking whether the context reached the index by any route, the CLI included; that field
only ever moves from `false` to `true`.

**The refused calls a lone re-run followed are grouped by shape, then the ten repeated most are listed
verbatim.** `RefusalShape` checks in order for conflict markers, another revision (`git grep`/`git show`/`git
log -p`), a path outside what this index covers (`.build/`, `DerivedData`, `checkouts/`, `/tmp`), a
fixed-string search, a phrase, an alternation, a shell window, and a whole-file read; first match wins. The
listed calls are redacted unless `--unredact` is given: every whitespace-delimited word containing a `/` is
replaced by its pseudonym, while flags, pattern and the call's shape are left as written, since that shape is
the reason the section exists. **A per-day line makes a hook fix visible as a trend**: lone refusals per day
and how many were a re-run, printed apart so a falling re-run count (the fix working) is never read as the
same claim as a falling lone-refusal count.

**`--summary` prints only the summary block** (the share, the not-worth rows and the refusal accounting) and
drops the lists a re-measure never reads twice, ending with one line naming how to get the rest. With
`--replay`, the replay's own section is printed in full beside the trimmed audit.

**`audit --replay` puts the window's real lookups to the hook as it stands now**, because a unit test pins
one shape and the share is made of every shape at once. Each context is walked in transcript order and every
`Bash`, `Read`, `Grep` and `Glob` call (and the Xcode server's `XcodeRead`, `XcodeGrep`, `XcodeGlob`) is
handed to the hook's own decision in-process (`PreToolUseCommand.lookup`, then `outcome`) with the payload
the harness would have sent. **The audit and its replay read one snapshot**: transcripts, subagents and each
file's size are taken once and read only up to that size, so a lookup a live session writes mid-run is
counted by neither. **The snapshot holds the machine's indexes too, as the run first opens them**
(`RunIndexState`): the first question about a root opens one read-only connection to its store inside a read
transaction held until the run ends, and every later declares, extends and member question about that root
goes through it. The store keeps a write-ahead log, so a store another session's newer build rebuilds in
place stays the snapshot the transaction began on; asked live, one audit judged the same lookups cold in
three runs and against no index in the next two. A store deleted mid-run answers from pages already read and
otherwise errs toward advising, never "no index declares"; a root whose store could not be opened the first
time is treated as having none for the whole run. Not held, and so able to move within a run: `below floor`
(each file's size as asked), `path`, `unreplayable`, and the in-place answers, which read the indexes live;
the header's `live:` line says so. Otherwise a run's output is a function of its snapshot: where several
calls could have located a file the earliest by transcript order is named, ties broken by call id. The
replay's walk can classify a lookup differently from the audit's, so the audit hands its own per-context
counts to the replay, which prints them as the audit's own share beside the replayed one.

What the hook reads about the context is rebuilt from the transcript, never from today's logs: a scratch
ledger per run, keyed per context, notes each index call when it is made, and a scratch usage log gains each
digest when its answer arrives, so "already digested" is what that context really held. Suppressions are
written nowhere, but a call the hook lets through as `noLookup` after a gate logged it withheld is reported
under the rule logged, as `filteredOutput (logged)`. The server is taken as present and the in-place
answerer is the real one (a stub would make the gate lie). **Its back-off is per context and its time
budget sixty seconds**, a deliberate departure from the live hook (one back-off per repository and shape
across the machine, three seconds), because a count must not depend on the order contexts are walked in or on
how busy the machine was; the ledger and back-off read the transcript's clock. A working directory under
`.claude/worktrees/<name>`, and any such path a call names, is mapped onto the repository above it, and the
floor a first read is put to is asked of the mapped path too, since a file that cannot be read is never
excused. Any other gone linked worktree is mapped onto the repository it was cut from where evidence names
one: the repository a `git worktree add <path>` in the session's own transcripts ran in, else the nearest
repository whose tree held the gone directory and whose ignore rules cover it, unless the session made that
directory itself (`mkdir`, `git init`, `git clone`). A tracked directory since deleted is never taken for a
worktree, and a gone path in a command's text counts only as a working directory or a `cd` target. A command
that opens by moving into a gone worktree has the move rewritten onto the repository. What is still not on
disk is **unreplayable** and counted on its own row, never as recovered, as is a shell command whose first
statement `cd`s to an absolute path not on disk. This moves the replay's `the audit's own` share away from
plain `sift audit`, which asks the path as written. A context straddling `--since` is judged from its first
line, so a pre-window denial, digest or nudge is on the ledger before the window opens, though only a lookup
inside the window is counted.

**`--replay` replays a sample of the window's sessions, bounded by contexts, 100 by default**: a
replay with nothing printed ran for tens of minutes, so the paired replay a hook change needs could not be
had. A session is replayed with all its subagents or not at all, since they are read together for the
worktrees they share. The sample walks the sessions holding a lookup in the window in order of the SHA-256
of their file names, lowest first, and keeps each, subagents and all, until the contexts kept reach the
bound: the session that reaches it is kept whole, so the sample overshoots by less than one session's
contexts, and a session larger than the whole bound is never passed over, since skipping it would steer
every sample away from orchestrator sessions. Two runs over one window replay the same sessions whatever
order the directory lists them in; a session written between the two, ranked among the kept, displaces
about its own contexts' worth of the later ones. `--against` judges both hooks in that one replay, so its
comparison is always paired. Where sessions were left out, a line under the replay's heading (first, under
`--summary`) says how many sessions and contexts of how many, and that the replayed share and the audit's
own beside it are the sample's; the audit above the replay still reads every session. `--sample N` sets
the bound in contexts, `--sample 0` lifts it.

The bound counts contexts, not sessions, because that is what the time follows. Measured on this machine's
own transcripts with a release build and a progress line per session: one day held 40 sessions, 297
contexts and about 9,400 calls put to the hook, and replayed whole in 2.5 minutes (35 seconds more for the
audit above it); seven days held 135 sessions, 1,184 contexts and about 44,600 calls, and replayed whole
in 10 minutes (2.5 more for the audit). A session's time tracked the calls it put to the hook (13 to 16 ms
each, correlation 0.96) and its contexts (about half a second each, 0.95), and sessions ranged from one
context to 71: per session the median was 0.1 seconds, the 90th percentile 18 and the longest 54, and the
sessions of ten or more contexts took over 90% of the time. `--against` costs 3.7 times as much (about
60 ms a call, the other binary's process for each), so the paired replay of that one day took 9.5
minutes, and one orchestrator session of 68 contexts took nearly 4 of them. A bound of ten sessions bounded
nothing there (only 8 of the 40 sessions held a lookup), and over the week it could have meant 10 seconds
or several minutes depending on which sessions ranked first. A bound of 100 contexts kept 4 sessions of
that day (122 contexts: 76 seconds plain, 4.3 minutes paired) and 5 of the week (119 contexts: 73 seconds
plain, about 4.5 minutes paired, scaled by the measured ratio), so the paired replay takes a few minutes
on either window. The replay tells each session as it finishes, with its contexts and the elapsed time, on
stderr, under the rule `report` follows: only on a terminal or with `--progress`, and never changing the
report.
The audit's own transcript scan, which reads every session in the window with or without `--replay`, tells
its advance under the same rule and on the same channel: that it began and over how many sessions, a count
every 50, and that it finished, each line prefixed `audit: ` as the replay's are, so a plain `sift audit`
over weeks of transcripts reads as slow, not stuck. `--progress` therefore stands without `--replay`. Stdout
is the answer and is byte for byte the same whether anything is told.

**`--until <day>`** closes the window at its other edge, exclusive and in the grammar of `--since` (`today`,
`yesterday`, `<N>d`, `YYYY-MM-DD`, local midnight): a lookup on `--until`'s own day falls outside, and a
straddling context's later calls are never put to the hook. The transcript is still read past `--until` for
what a counted call is waiting on (an index call's error, a refusal's round trip, what followed it), each
anchored on the call it belongs to. `--until` at or before `--since` is refused up front rather than printed
as "nothing to audit". The header names the window, giving the *last day included* when it spans more than
one, so a single day's share is read off one run instead of a subtraction of two.

Of the lookups the scan calls cold, the replay reports how many the hook would now answer in place
(**recovered**, by rule and call), how many it would still let through (by rule), and how many are
unreplayable, and then **replayed share = (indexed + recovered) / the audit's own denominator** (indexed +
cold + read whole after its digest) less the located reads below, the unreplayable calls and the lookups not
worth answering, per day and in total, beside the audit's own share. An unreplayable call was never judged,
so it is no evidence either way and leaves the denominator. **A lookup not worth answering** is one the hook
lets run as `notSmaller`, since no answer it has is smaller than what the command prints; it has a `not worth`
row by rule (a line let run whole as `otherStatementsRun` is a batched miss, in the share). Logged ones are
put back into the denominator before those the hook finds not worth are taken out, so each is taken out
once. The line then states the share on the old denominator, which held the unreplayable, not-worth and
one-file text searches as misses, with the count of each it adds; the numerator is the same on both. The
change is to the accounting alone: no verdict of the hook moves. **A cold lookup the hook now lets through
only because an answer the replay itself gave in place located its file is scored as the audit scores the
same read after a real digest**: a window or ranged `Read` is the located read the scan scores guided, out
of the denominator, and a whole `Read` is read whole after its digest, which stays in it and is not
recovered. Each has a row of its own (`located`, `read whole`), never folded into still cold. Only the
replay's own answers move a lookup, and only where its file is known exactly: a relative path behind a shell
`cd` is spelled out against the directory every literal `cd` in front of its lookup moves to, read over the list
in front of the line's first `||` as the hook places its answer, and located nowhere behind a move that cannot be
followed (a subshell, `pushd`, `cd -`, a substitution, a piped `cd`) or where the line's lookups ran in more than
one directory. A context that could not reach the index is left out, as its cold lookups are out of the share.

**Under each still-cold rule, the replay lists the calls behind it**, because the next hook shape is chosen
from what was let through, not guessed at: the ten commonest, **collapsed by shape**, and one line summing
the rest. A shape is the call with every operand replaced by its kind (`<file>`, `<path>`, `<range>`,
`<n>`, `<text>`, `<rev>`) and its command words, flags and shell operators kept, by the same allowlist the
refused-call section redacts by, so `sed -n 95,135p A.swift` and `sed -n 1,30p B.swift` count as one; a run
of four or more like operands reads `<file>×N`. A tool call is spelled from its fields (`Read <file>
offset=<n> limit=<n>`). No path, name or text survives a redacted run; `--unredact` adds up to two real calls
per shape. **A lookup withheld as `overSize` also names how big its answer came to against the budget**
(smallest and largest in the shape), or how many stopped at the search's own ceiling, since whether a shape
is worth answering under a larger budget turns on how far over it went.

**A rule with more shapes than it lists also groups its calls by structure**, so a design pass on compound
command lines is sized from the tool, not a hand count. The grouping covers every call of the rule, so its
buckets add up to the rule's count, except a still-cold lookup counted before its call could be resolved; the
header names how many (`3  notHooked (1 without a call to group)`) so the total is never hidden. Each bucket
is one line, commonest first, eight listed and the rest summed, read off four axes: how many statements the
line holds (`1`, `2`, `3+`, split as every other reading of a call splits, never inside a quote or a
substitution, and a heredoc body is gone before the split), the command words that open them (sorted,
anything off the redaction allowlist read as `other`, a leading `for`/`if`/`while`/`time` skipped), whether
it names no file, one or several, and whether the line is `piped` or also carries a `sift` call. **`--shapes
<file>`** (with `--replay`) writes every shape of every still-cold rule and every bucket, nothing summed, to
that file; the report itself keeps the ten-shape form.

**`--scan-diff`** (with `--against <binary>`, in place of the audit and of `--replay`) does for the audit's
own scan what `--against` does for the hook: both builds' scans run over one snapshot of the transcripts and
every window they class differently is listed as its class → this one's, grouped with counts and capped at
100 windows a group (`--all-windows` lifts the cap; a cut group ends on `… listed 100 of N`), then one line: `scan differs on N of M windows` with both scans' guided and
cold totals. The other build answers through a hidden `scan-dump` entry point, reading the snapshot on stdin
(session and subagent paths with sizes, the window's instants, the suppression log with its size) and
printing one JSON line per scored window, so both builds read the same bytes however the live files grow; a
binary without the entry point is refused in one line before anything is scanned. **`--root`** scopes both scans on this side, to the transcripts the plain audit keeps, each judged by its own recorded directory; a subagent in scope under a session out of scope is promoted to a session of its own in the handed snapshot, and the other binary's windows keyed by that agent's file name are re-keyed to the parent session before the two scans are joined, so a binary from before a subagent file was read as that agent of its parent needs nothing new. A root that keeps no transcript is refused with the plain audit's "no session … ran in … or below it" answer and a nonzero exit, never a clean `0 of 0`. A call holds two windows at
most, joined on session, call and `part`: `index` for the `.indexed` lookup an index call is counted as, and
`lookup` for the lookup a read, search or shell line is held as. A window its result took back is dumped
`retracted` or `refused`, and a context that could not reach the index has its cold windows dumped
`unreachable`; every other window is one of the audit's Swift lookups. The snapshot freezes the transcripts
and the suppression log but not the indexes, so the two scans run **at once** and read the indexes in the same
window of time. Where they still differ, both are run again, and a window a build classed differently between
its own two runs is listed apart under `unstable` and left out of the differing count. The windows are
recorded by the scan itself (`ScanWindowLog`) inside the audit's own sweep, never re-derived beside it.

**`--against <binary>`** (with `--replay`) answers "what does this change to the hook change?" in one run
instead of two replays diffed by hand, whose counts drift apart on anything that is not the change. Every
call is put to this build's hook and to the other binary's, each with state of its own (ledger, back-off,
usage log, fed only the answers to its own index calls). The other binary answers through a hidden
`replay-hook` entry point (payload on stdin, one JSON object out), and is refused up front if it has none.
**It must also keep its index at this build's schema version**: both binaries answer from the same
per-repository stores, and each drops and rebuilds a store at another version on open (§6.6), so two versions
would rebuild every live index the window touches, in turn, for every call. The version is read, not asked,
from the store the other binary writes when it indexes an empty throwaway repository with its home moved
beside it; a differing or unestablishable version is refused, naming both. The section printed in place of the
replay's own lists only the calls the two judge differently, grouped as rule → rule (or one rule with its two
verdicts, or, where only the index call an in-place answer runs changed, one rule with its two calls, `[call digest
<file> → digest <file>:<range>]`, each call's words shaped so it names nothing in the tree, and under `--unredact` the two calls as written beside it, since a moved target shapes alike on both sides), shaped and redacted as `--shapes` shapes them; two hooks that agree print `no difference`. Where
the replayed share's denominator differs it is printed on its own line, `denominator d → d′`, with the
located, unreplayable and not-worth counts behind it. A request the other binary fails, or answers in a shape
that cannot be read, is never read as agreement: it is listed under the rule `unanswered`, with a count of
failed requests. With `--summary` the output is the comparison alone, ending in a verdict line a gate can
expect without comparing rounded percentages (`share: unchanged` where the two fractions are equal, else
`share: moved +0.3` in points of the exact difference) and a line naming the command that prints the audit
body. Each request is a process of its own, so the run costs about 3.7 times a plain replay (measured over
one day's sessions: 60 ms a call against 15).

### Delivering through a Claude Code mod — removed

The mod that delivered an in-place answer to Bash and Grep as an ordinary result (off by default, behind
`SIFT_MOD_TRANSPORT=on`) was removed with the band on 6 October 2026: it never fired in measurement. The marker per
answer the hook still writes under `answers/` in the advice directory was read only by that mod.

**The answered log stays.** `TranscriptScan` recognises an in-place answer by an `is_error` result
whose opening line parses, so an answer delivered as an ordinary result would be scored as a Swift lookup that went
around the index, in the audit and every replay. The hook
therefore records every answer it *prints* in `~/.sift/advice/answered.jsonl` (`call` the `tool_use_id`, `ts`),
beside `suppressions.jsonl` and through the same appender, written just before the denial is returned and never
for an answer that was built and withheld, nor where the ledger refused to record the denial. It is never
trimmed, for the reason the suppression log is not: an audit re-scans transcripts a week old. **A result whose
call is in that log takes exactly the path an error-delivered answer takes, whatever its error flag says**: the
lookup is retracted and counted as indexed, `answeredInPlace` and any partial-alternation event are reported, what
the answer located is credited, and the same scan state moves. The log is the proof, so the result's text is never
read to decide; the opening line is parsed for the calls it names as before, with or without the harness prefix
or an `Error: ` prefix in front of it. The ids are read once per render or audit, beside the suppression log
(`AnsweredLog.fileURL`), and handed down with `loggedLetThrough`. Pinned by one transcript
delivered both ways, whose tally, misses and events must be equal, and by the same normal result with no log
entry, which scores as the cold lookup it looks like.

### Wiring into Codex and Cursor — both installers built (experimental)

Codex and Cursor can call the four query tools over plain MCP and get nothing else: no guidance, no hook, no
audit. Built for Cursor, probed on Cursor Agent CLI 2026.09.28 (the IDE only for allowed calls): its silence, the
installer, and the `pre-tool-use`, `session-start` and `post-tool-use` handlers. Built for Codex: its installer
(hooks and MCP server), running today's Claude Code handlers unmodified. Not built: Cursor's `.mdc` project rule.
The rules that hold:

- **One command, one flag, and the flag is part of the registration.** `sift install-hook --agent
  codex|cursor` (default `claude`) and `uninstall-hook --agent …` as its exact inverse; the registered hook
  commands carry the flag too (Cursor's; Codex's speak Claude Code's protocol and carry none), so a hook registered with `--agent` never sniffs its caller's protocol from the payload. (The Claude Code registration recognises a payload in two ways only: the Cursor silence, below, which only ever withholds output, and, in the post-tool-use hook, a Codex `apply_patch`, recognised by its tool name and answered as the `Write` of each file it adds or updates; see the Codex section.) On Cursor a
  response that does not match the schema *blocks the call*, and a protocol guessed wrongly would break the
  invariant that nothing this tool does can make a call unavailable.
- **Cursor may run today's Claude Code hooks, and the Claude Code registration stays silent under it.** Cursor
  documents importing hooks from Claude Code's settings files (on by default; Settings → Agents → Third-Party
  Imports) and translating `permissionDecisionReason` to `user_message`. A probe of the Cursor CLI (Agent CLI
  2026.09.28) found the premise that this reaches the user and not the model wrong there: on a `deny` the call
  is blocked and the **model receives `user_message`** as the rejection reason, followed by Cursor's fixed line
  asking it not to suggest workarounds; `agent_message` never reached the model. Empty stdout, `{}` and
  `{"permission":"allow"}` all let the call run. The IDE (3.22.12) was probed in allow mode only, so how it
  delivers a `deny` is **unconfirmed**. The silence on a payload carrying any of Cursor's common fields
  (`cursor_version`, `conversation_id`, `generation_id`, `workspace_roots`) stands, since the Claude Code
  protocol is not Cursor's and the probe found no evidence the CLI runs the imported hooks at all.
- **`pre-tool-use --agent cursor` is built.** It reads the payload as the Claude Code one the hook judges and
  answers in Cursor's schema, so one engine decides for both: Shell `{command, cwd, timeout}` as Bash (its
  `cwd` comes empty, so paths resolve against `workspace_roots[0]`), Read `{file_path}`, Grep `{pattern,
  file_path}` and Write `{file_path, content}`, key for key as probed; any other key, tool or event, or no
  absolute workspace root, prints nothing. A refusal or an answer in place is `{"permission":"deny",
  "user_message":…, "agent_message":…}` with the reason in both. An MCP call arrives as `MCP:<tool>` with no
  server name, so it is taken for this server's only where every argument is one its tool takes and the
  required ones are present (`IndexToolName`), and anything else is left alone.
- **`session-start --agent cursor` and `post-tool-use --agent cursor` are built**, and both carry their text
  in `{"additional_context":…}`, which a probe of the CLI saw the model quote back from each event (after a
  tool call it arrives as a system reminder). `sessionStart` has no `cwd` and no `source`: the primer Claude
  Code gets at a session's start is read against `workspace_roots[0]`, never the process directory, with no
  resumption block and no subagent variant; no absolute root, another event or no Swift in view prints
  nothing. `postToolUse` reported both writes probed, a new file and a search-and-replace edit, as `Write
  {file_path, content}` with the whole new file and no prior content (`tool_output` is a JSON string, `cwd` absent), so it
  is judged as a Claude Code `Write` whose prior is unknown; any other tool or key prints nothing. The parse
  block's reason goes out as context too, since no block of a call already made was probed.
- **Codex guidance is the primer alone.** No path-scoped rule exists on Codex, and `AGENTS.md` would reach every
  session on the machine; the installer writes none. It is the same slim primer a Claude Code session gets:
  Codex's registration carries no `--agent` flag, so the hook cannot tell it apart. Cursor's Swift-scoped rule is per project only, so it is
  an opt-in (`--project <root>`) that writes inside the user's repository.
- **Codex hooks must be trusted before they run**: the installer cannot activate them, so it says so: Codex asks to trust
  them the first time it opens (seen on a real Codex home, 1 Oct), and they can be approved in that prompt or in
  `/hooks`, where they are reviewed; a repointed binary changes the hook's hash and needs trusting again.
- **Codex, as probed** (Codex CLI 0.159.2, `codex exec`, 30 Sep): payloads and responses are Claude Code's, and
  today's `session-start`, `pre-tool-use` and `post-tool-use` run unmodified, so the Codex registration carries
  no flag. A user-level `$CODEX_HOME/hooks.json` loads (source `user`) beside a project's `.codex/hooks.json`;
  its shape is `{"hooks":{"<Event>":[{"matcher":…,"hooks":[{"type":"command","command":…}]}]}}`. An untrusted
  hook is skipped with no output at all. Trust lives in `config.toml` as `[hooks.state."<file>:<event>:<group
  index>:<handler index>"] trusted_hash`, the hash Codex's own (the app-server's `hooks/list` reports it), so
  the key is positional: the installer appends its group and never inserts ahead of a foreign one, and an
  uninstall that removes a group ahead of a foreign one voids that one's trust. Pre-trusting would go through
  the experimental app-server and bypass a review Codex asks the user for, so the installer does not.
  `$CODEX_HOME` is honoured before `~/.codex`. An MCP call arrives as `mcp__sift__<tool>`, which `pre-tool-use`
  already amends with `root`; a rootless call reached a server launched in the workspace. `codex exec` refuses
  an MCP call under its default approval policy. `codex mcp add` replaces a server of the same name without a
  word, so a foreign `sift` is checked for (`codex mcp get --json`) first. An `apply_patch` edit carries
  Codex's own patch grammar (`tool_input.command`, paths relative to `cwd`, `tool_response` a string opening
  `Exit code: 0`), recognised by tool name in the Claude handler (#364): each `.swift` file a `*** Add File:`
  section names is judged as a `Write` that created it, each an `*** Update File:` section names as a `Write`
  whose prior is unknown, and the hook answers once for the patch, the first parse block across its files, else
  the first nudge, within the one budget. Each file is judged against the repository that holds it (looked up once
  per directory), so a patch made from a folder above several checkouts answers as the `Write` of each file would,
  and a file no repository holds is left out of the nudge without silencing the rest. A `*** Delete File:` leaves nothing to check; an update carrying
  `*** Move to:` is skipped, as is a patch whose exit code is not 0, until a payload of each has been captured.
  Only the Add section's grammar is from a capture; the update, delete and move headers are Codex's documented
  ones.
- **A Codex shell call's payload, as captured** (Codex CLI 0.159.2, `codex exec -s workspace-write`, a stand-in
  Responses API behind the real binary, 1 Oct; `Tests/SiftMCPTests/Fixtures/codex-shell-payloads.json`, with its
  PROVENANCE section): `PostToolUse` carries `tool_name` `Bash`, `tool_input.command`, and a `tool_response`
  *string*: the output the model got, stdout and stderr merged, with no exit code, cut past about 10 KB under a
  `Warning: truncated output` header. It also carries `session_id`, `turn_id`, `tool_use_id` and `cwd`, and the
  shell's `CODEX_THREAD_ID` equals the payload's `session_id`. Claude Code's Bash response is an object, not a
  string. *Unconfirmed:* the format of a real model's `tool_use_id` (the capture's model was a stand-in).
- **Codex CLI lookups are not counted in the usage log.** The `workspace-write` sandbox cannot write `~/.sift`,
  so the CLI's own line is lost there; the CLI says nothing about that (see the CLI usage-log note below), and no
  Codex transcript is a documented interface to count from instead. A hook-side record was built and rejected:
  anything the unsandboxed hook trusts from the sandboxed side (a stat of a path the command names, the text of
  `tool_response`) can hang it on a FIFO or forge its byte counts. A `read-only` sandbox does not reach the log at
  all: the CLI cannot open the index there (SQLite's `attempt to write a readonly database`, from the open's
  journal and schema writes), so the lookup fails inside the call `LoggedLookup` wraps and exits 1 with no success line, and the failure line it
  then tries to write is dropped as silently as any other. (Verified by reading that path, not by running a sandbox.)
- **`updated_input` is honoured without `permission`**, on the CLI: a Shell command rewritten that way ran as
  rewritten, and an `MCP:digest` call without `root` ran with the root added. So the `root:` amendment carries
  over (the whole arguments sent back, `root` the git top level of `workspace_roots[0]`), and closes the gap a
  rootless Cursor call otherwise has ("Per query is only as good as the query"). The build rewrite does not:
  the probe ran under `--force`, so whether a rewritten command prompts is not established, and Claude Code's
  allow rules say nothing of Cursor's; a build is refused once with its wrapping instead. Where a documented
  fact is missing, the design says *unconfirmed* and probes; guessing a payload shape is refused.
- **Audit is unsupported** on both: neither transcript format is a documented interface. The install output says so rather than half-supporting it.
- **Installer guarantees** match `settings.json`'s: merged in the binary (Codex's MCP half through `codex mcp`),
  a `.bak-sift` copy before any changing rewrite, entries recognised by shape, unexpected elements carried
  verbatim, both directions idempotent, a server of another shape reported and left alone. Cursor's
  fail-closed flag is never set. No test touches a real `~/.codex` or `~/.cursor`.
- **Built: the Cursor installer.** `install-hook --agent cursor` and `uninstall-hook --agent cursor` (with
  `--cursor-dir`) write `mcp.json` and `hooks.json` under those guarantees, and `sift uninstall` runs the
  inverse. It registers `sessionStart`, `preToolUse` and `postToolUse` and prints what is unsupported. It is
  experimental until a live Cursor run of the whole path is done (#296). **Still not built:** the per-project
  `.mdc` rule (`--project <root>`).
- **Built: the Codex installer.** `install-hook --agent codex` and `uninstall-hook --agent codex` (with
  `--codex-dir`, then `$CODEX_HOME`, then `~/.codex`; the answer names the directory) merge `SessionStart`,
  `PreToolUse` and `PostToolUse` groups into `hooks.json`, each running the plain `<binary> <subcommand>`, and
  `sift uninstall` runs the inverse. The MCP server goes through `codex mcp get --json` then `codex mcp add sift
  -- <binary> mcp` (with `CODEX_HOME` set to the directory used), or the line is printed when `codex` is not on
  PATH; `codex mcp remove sift` undoes it. A server named `sift` of another shape is reported and left alone. It
  says Codex asks to trust the hooks when it next opens, and what is unsupported: audit, a Swift-scoped
  rule, the subagent primer and the post-edit note for a file `apply_patch` moves. Experimental until a live Codex
  run of the whole path is done (#295).
- **Built: the unified command.** `sift install [--agent …] [--all] [--yes] [--dry-run]` (#365) runs the three
  installers above and adds no merge logic of its own. Detection reads signs on the machine: `claude` on PATH or
  `~/.claude`; `~/.cursor` or Cursor.app; `codex` on PATH, `$CODEX_HOME` or `~/.codex`. It asks once per agent
  found on a terminal; with none, it installs nothing until `--yes`, `--all` or `--agent` says what to install
  into. A step's refusal is captured and reported, the other agents still run, and the exit status is 1 if any
  failed. It is idempotent (a second run reports nothing to do), and `--dry-run` resolves and prints the paths
  it would write without writing, and calls neither `claude` nor `codex` (no runner is invoked). It also names,
  one line each, a legacy band plugin or marketplace the settings register and the install would remove, read
  through the same checks the install uses.

## 5. Large codebases

- **Module awareness.** A module per file, and module scoping wherever a query names one — `digest
  <Module>` reads only that module's rows, and `where Module.Name` narrows to it; `search` narrows by
  `path:` instead, and `strings` not at all. Reindexing is per file rather than per module: the dirty set
  is reparsed wherever in the repository it falls, and `index --full` is the only whole rebuild.
- **Partial indexing.** A directory allowlist in config: indexing only the subtrees actually worked in is
  often the right answer on a large repository.
- **Vendored code.** `Pods/`, `Carthage/`, `DerivedData/`, `node_modules/` and **every hidden path
  component** — a directory or a file whose name starts with `.` — are excluded outright, by the
  enumerator and by the build-file walk alike, so a tree that is not indexed cannot name modules either.
  The hidden rule is absolute and general, since a list of names loses a race with every tool that adds a
  dotted directory, and losing it is a wrong answer (vendored source indexed as a module, a guessed-module
  banner on everything touching it): a hidden tree is build output, a cache or somebody else's code.
- **Generated code.** An exclusion list in config, matched as plain substrings of the repo-relative path
  rather than as globs — generated files inflate the index and are rarely worth digesting.
- **An excluded file is said to be excluded.** A `digest` of a file that exists in the repository but that
  one of these rules keeps out — or the index's own rules, Swift sources only and no build manifests —
  names the rule and points to a plain Read, instead of answering "no indexed file matches", which reads
  as "there is no such file". The rule is taken from the enumerator that built the index, so the answer
  cannot name one that did not apply. A file git ignores is said to be ignored the same way; that rule
  lives in git's listing rather than in the enumerator (§2), so it is asked of git (`check-ignore`) — last,
  and only on this miss, for a file no other rule accounts for.
- **No global rebuild on a branch switch.** The incremental path — the dirty set, plus the diff between
  the recorded head and the new one (§2) — is what makes the large profile viable, and it has to hold
  across a switch touching 500+ files.
- **Concurrent worktrees.** The index path is per-worktree, so parallel worktrees stay independent; a
  shared index is not attempted.

## 6. Data lifecycle and pruning

The index must be bounded in size and self-cleaning. Each accumulation vector needs an explicit answer.

**6.1 Per-file replacement — the bug this design exists to prevent.** Reindexing a file is
**delete-then-insert within a single transaction**, keyed on the file's row; never insert without first
clearing that file's prior rows. `ON DELETE CASCADE` runs from files to symbols to inherited so one delete
cleans the subtree — remembering that cascades only run on connections that set `PRAGMA foreign_keys = ON`
and the default is off, which would make this paragraph a comforting fiction. The cascade does not reach
`symbols_fts`, a standalone FTS5 table with no foreign key, so a file's FTS rows are deleted explicitly
first, by the symbol ids about to go. Getting it wrong duplicates every symbol on every reparse, and the
symptom — slowly degrading results — is easy to miss for weeks.

**6.2 Deleted and renamed files.** The dirty-set diff honours statuses, not just names: a delete removes
the file's row and cascades away its symbols; a rename removes the old path's row and indexes the new
path, with no attempt at rename tracking, because the index has no history; an add or a modification
reparses.

**6.3 Branch churn.** The index represents the working tree at one HEAD and nothing else: no multi-branch
retention, no history, no caching of symbols from branches not checked out, and switching back to a
previously-visited branch reparses rather than restoring. This is the decision that makes size bounded —
index size is a function of the current checkout, not of how many branches have been visited — and any
future optimisation caching per-branch state trades a bounded cache for an unbounded one to save seconds.

**6.4 The reconciliation sweep — the backstop.** Even with query-time git state as the source of truth,
convergence is worth one cheap command: clock skew, files outside git's view and plain bugs all land
somewhere. `reconcile` lists the Swift files git can see — `git ls-files --cached --others
--exclude-standard`, the same enumeration the index is built from, with a directory walk only when git
itself fails — applies the exclusions, diffs against the files table, deletes rows for paths no longer
present, and reparses paths absent from the table, whose size no longer matches the row, or whose content
hash no longer does: every equal-sized file is hashed, mtime regardless, since a backstop that trusted the
stat would miss exactly the edit that kept it (§2). A gitignored file is outside it by design, as it is
outside the index (§2). One listing plus one query, a `stat` per file and a hash of each equal-sized one
(on this repository's 1,250 files, 12 MB, about 45 ms more than a stat-only sweep, ~210 ms for the whole
`sift reconcile` command, measured on a debug build) —
cheap enough to run on every twentieth incremental update that changed
something, whenever the resolution fingerprint moves and whenever the recorded head no longer resolves
(a full index purges unlisted rows the same way), and the only mechanism that guarantees convergence
regardless of what else missed.

**6.5 Reclaiming disk, not just rows.** Deleting rows does not shrink a SQLite file; freed pages are
retained for reuse. So: set `PRAGMA auto_vacuum = INCREMENTAL` **before creating any table**, since it
cannot be changed afterwards without a full vacuum and a complete file rewrite; after a full index, and
after a reconcile that removed rows, run FTS5's `optimize`, because it accumulates tombstones, then
`PRAGMA incremental_vacuum` and `PRAGMA wal_checkpoint(TRUNCATE)`; and cap the write-ahead log with
`PRAGMA journal_size_limit`, reapplied on every open since it is per connection, so a long session
cannot leave a multi-gigabyte sidecar beside a modest database. The incremental path's own deletes do
not compact: their freed pages are reused by the inserts that follow, and returned to the filesystem only
by the next full index or a reconcile that itself removes rows.

**6.6 Schema changes and the nuclear reset.** On a schema version mismatch, **drop every table and
rebuild** rather than migrate. A change to what a derived column *holds* — the rule a doc summary is cut
by, say — is a schema change too, DDL untouched: an unchanged file is never reparsed, so nothing else
would ever reach its stored rows and pick up the new rule unless the version bumps and forces a rebuild.
Migration logic for a derived cache is pure cost, since the source of truth is the source code and a
rebuild is seconds. The tables are dropped in place rather than the file
deleted, because another process may hold the database open and unlinking a live SQLite file is a
documented corruption path. `reset` deletes `.sift/` entirely, and the directory is kept out of git
through `.git/info/exclude`. Everything in it but one thing is a cache the next query rebuilds — the
index and the semantic store's cache — which is why a reset is the first troubleshooting step and any
corruption resolves to it. The one thing is the raw transcripts under `.sift/runs/`: receipts of past
runs rather than caches, deleted with the rest and never rebuilt. And while `run --without` has changes set
aside (§3), `.sift/set-aside/` holds the only copy of them, so `reset` refuses until `sift run --restore` has
put them back — and while any run, watcher or restore holds the set-aside lock, a run's second pass
included, it refuses in the words a busy run is refused in. It deletes holding that lock, the lock file
last, so no run can set the tree aside under it. A server still holding the old database notices the file is
gone by its device and inode and reopens (§4) rather than answering from a dead handle. The semantic
cache's own layout is a third stamp beside the schema and the resolution fingerprint: the next time it
bumps, the schema version must bump alongside it, so a binary at the new layout is never taken for one at
the old.

**6.7 Expected steady-state size.** A sanity check for the large profile: ~5,000 files at ~100 symbols
each is around 500k symbol rows plus FTS overhead — low hundreds of megabytes, stable across branch
switches. If it grows monotonically over a week of normal work, 6.1 or 6.4 is broken; `sift status`
reports the database size, which is where the trend is read — nothing logs it on its own. The index
store's own databases (`.sift/isdb`, one per store, each reclaimed once its store is gone — §2) are a
separate cache this tool creates and may delete freely, while
the underlying store belongs to the build system and sits outside this lifecycle. An index held in memory
because the tree cannot be written (§2) accumulates nothing: it goes with the process that built it.

**6.8 What else accumulates.** Beside the index, `.sift/runs/` keeps the raw transcripts of wrapped runs
(§3): the newest five, with an unfinished one left alone for a day before it is read as abandoned.
`.sift/progress/` holds one small file per run, its live progress (§3): the newest five, pruned as a run begins.
`.sift/set-aside/` exists only while a set-aside is out of the tree, and a capture interrupted before its
record was written takes its copies with it; `.sift/set-aside.lock` is left in place, since a lock on a file
that is removed excludes nobody, holding one line naming its last holder's pid and role, which is read only
while the lock is held, and `.sift/set-aside.watch` beside it, empty, held by each watcher while it lives;
`.sift/without-build/` holds the build directory the run without the change builds in, one per tool — as
large as a build of the repository, removed when the run ends unless `--keep-without-build` kept it so the
next proof of the same package or scheme builds incrementally, and removed before a run whenever the last
one's build did not reach its tests or was for another; `.sift/test-durations.json` holds the per-test history the shard planner bins by (§3), bounded twice
over — the last five observations per test, and no entry unseen for 90 days, both applied when the file is
written, so a suite that is renamed away stops costing anything within the quarter; the proved-run ledger holds the green runs the repository's content has been proved by (§3), and is the one file here that
is not under `.sift` at all: it is `<git-common-dir>/sift/proved-runs.json`, shared by every worktree of the
repository, so `reset` leaves it alone and it dies with the repository. It is bounded
twice over — nothing past the hour a record stands for, and at most the newest sixty — both applied when
the file is written, which is once per green run; it is rewritten whole and renamed into place rather than
appended to, so no reader sees half of it, and a file that will not parse is read as empty, which runs the
suite. It is a cache in the sense the index is: losing it costs a run and never an answer. `.sift/device-prefix` is
six hex characters minted once per checkout and never rewritten, which is what lets a later run recognise a
simulator this checkout created without any record of the run that made it; `.sift/shards/<runid>/` exists
only while a sharded run does, holding that run's ledger and its result bundles, and is removed when the run
ends — by the owner, by its watcher, or by the next run's sweep, which is the invariant that keeps the
simulators bounded too; and a `.sift-kept-` file a set-aside or a restore moved beside a path is never removed by the tool, because
it holds somebody's bytes. Per
user, `~/.sift` holds the usage, run, suppression and answered logs, which are appended to and not pruned (the answered log's per-call markers under `advice/answers/` are removed after a day, §Delivering through a Claude Code mod), and the
lifecycle log, trimmed at 400 entries (§4); the roots registry, pruned of vanished paths on read; the
advice ledger, each context's state aged out a week after its last denial; the caller slips, claimable
for two minutes; and the redaction salt. `SIFT_HOME`, an absolute path, moves that whole directory (the per-user home is otherwise `CFFIXED_USER_HOME`, then `HOME`), so a probe keeps out of the user's real state (#522); the per-file overrides still win. `uninstall-hook`
leaves all of it in place, and deleting the directory resets everything the tool remembers. `uninstall`
lists it, with every repository's `.sift/` the roots registry and the logs name and the `.bak-sift` copy beside
each file it rewrites — the settings file, Cursor's `mcp.json` and `hooks.json`, Codex's `hooks.json`, each
beside the file a symlink leads to — and deletes them only under `--purge`: a `~/.sift` or `.sift/` that is a symlink or not a
directory is refused and counted rather than deleted through, and deleting a repository's `.sift/` leaves its
`.git/info/exclude` as it was. A purge deletes the record of which repositories the tool ran in, so the one line
naming a recorded repository's `.mcp.json` that still registers this tool also says, where the roots read again
no longer reach that repository, that a later run cannot find it; reports `~/.sift` purged only when it is still absent at the end,
counting it otherwise; and, whenever it deleted `~/.sift`, says that sessions already running keep the hooks and
server they started with and can recreate it. A recorded root that is not an absolute path is counted and skipped by every
step that looks under a repository, the `.sift/` listing and the `.mcp.json` check alike, never resolved against
the working directory. A settings file, `.claude.json` or recorded repository's `.mcp.json` it cannot read or parse is named as not
checked (a missing `.mcp.json` is not), never read as nothing registered, and the command exits 1 while anything it names was not removed. A server named
`sift` is this tool's only when it runs `sift mcp` (the binary by that name, `mcp` alone) or `npx` with this
package and `mcp` (`-y`/`--yes` and a version allowed): the user-scope one is removed with `claude mcp remove
sift --scope user`, and a local-scope one with `claude mcp remove sift --scope local` run in that project's
directory, with `PWD` and HOME set to match — only where the project key is a directory whose path, links
resolved, is the key itself, which is not inside a git repository rooted elsewhere and which is not in a
linked worktree, at its root or below (its own git directory differs from the shared one), so the entry `claude` finds from there is the one
read: Claude Code 2.1.285, run under a scratch HOME, keyed a local-scope server added from a repository's
subdirectory by the repository's root, removed the root's entry when run from that subdirectory, keyed one added
in a linked worktree by the main repository's root and one added in a submodule by the submodule's own root, and
outside any repository keyed it by the directory itself. Each is reported removed only when
`.claude.json`, read back, no longer holds it; each removal, user scope or local, is also read back against every
`mcpServers` entry, user scope and each project's, as they stood just before it ran, and if any other entry
changed, those entries are named to check and the removal is counted as not removed, as it is when the file
cannot be parsed afterwards, which leaves the outcome unknown. A local-scope one whose directory is not
there, is reached through a link, lies inside another repository or is a linked worktree, and one in a recorded repository's
`.mcp.json`, are named with how to remove them and counted as not removed; the `.mcp.json` is never edited. A
server of that name that runs anything else is named and left.

## 7. Acceptance

Properties, pinned by a test except where stated. Three are targets no test holds, since a suite that
runs on any machine cannot hold a wall-clock or peak-memory bound: a cold index of a ~200-file project
completes in seconds, an incremental update after a 500-file branch switch in a few seconds more, and
peak memory during a full index of 5,000 files stays well under a gigabyte. A digest is a small fraction
of its file's token cost for typical shapes and stays a small fraction for the dense worst cases, never
exceeds a bounded page, and omits no declaration at or above the requested access level. An answer from
each of the four query tools, and from `status` and `affected`, opens with its header, with any note under
it (§2): `AnswerHeaderTests` pins the header leading and an adopted root's note directly beneath it for
all four query tools on both faces, the live header's exact line for `search` and `strings`, and the same
placement for `status` and `affected` on the command line. Semantic queries refuse per symbol when the
symbol's file postdates the store's build. Index size is demonstrably non-monotonic across repeated alternating branch switches, and
`reconcile` on an untouched tree reports zero changes. A plain commit with a clean tree triggers neither a
refusal nor a reindex on the next query — the test holds the first half; the second follows from the
empty range diff of §2 and is not asserted. A file with syntax errors indexes with its parse-error count
set, appears in the freshness header, and any answer touching it says so inline. The MCP server's stdout
is byte-clean JSON-RPC over real pipes, with its logging on a channel of its own. `run --without` returns the tree it was handed, byte for byte, across every interruption, exit code and racing writer, and never checks then writes (`SetAsideTests`, `SetAsideEdgeTests`, `RunWithoutCommandTests`). And the visitor is
covered against a fixture exercising generics, `some`/`any`, property wrappers, actors, macro-attributed
types, nested types, protocol extensions with `where` clauses, result builders, `@MainActor`/`nonisolated`
and `async`/`throws` in signatures, overload sets, typealiases, free functions, operators, and `#if` blocks
with both branches indexed and tagged.

## 8. Risks

- **Macro expansion.** Macros generate members SwiftSyntax cannot see before expansion, so the digest of a
  macro-attributed type is incomplete in a way that may not be obvious. The answer is an explicit marker
  on such types, and resolution through the store where one exists. **Never silently under-report.**
- **Adoption failure.** The likeliest bad outcome is a technically correct tool the model never calls.
  Trigger-phrased descriptions, the measured share of lookups that went through the index, and the report
  page exist to catch that rather than assume it away.

  **The share counts a lookup by what answered it, never by the route it took.** A `sift where` run from
  a Bash block is the index serving a Swift lookup exactly as `mcp__sift__where` is, and counts in
  `indexed` for that reason; the audit prints the CLI-served part on a row inside `indexed`, so the route
  stays visible. What does *not* count is a subcommand that answers no lookup — a build wrapped in `sift
  run`, a `sift status` — which still stands as evidence that the context could reach the index, and
  nothing more.

  **An excluded route is only a floor while it is rare.** CLI use once sat outside the share, but a context
  under an output style that mandates the Bash tool reaches the index almost entirely through the CLI, so the
  error scaled with a harness setting rather than with the tool: a blind spot, not a floor, and one the
  report cannot show (one day measured 1858 lookups, `indexed 432`, `cold 534`, a 44% share, with no way to
  split the 56% between genuine misses and off-camera answers). The remaining biases, a Grep that merely
  mentions Swift counting as a raw lookup and the unreachable floor, are properties of the lookup and the
  context, which is the difference.

  **The saving is measured on the same rule, from `usage.jsonl`.** Every face writes one line per lookup: the
  MCP server, the advice hook answering in place, and the CLI's `digest`, `where`, `search` and `strings`. The
  saving is computed at call time from what was served against the source it stood in for, so every face
  holds the same numbers; had the CLI not logged, the saving would have covered roughly half of what the
  index served (one machine: 2446 lookups, 64% indexed, 535 on the CLI absent from the log). `sift run`
  keeps `run.jsonl`, since a wrapped build is not a lookup. The line names its face in `via` (absent for the
  server, `hook` or `cli` otherwise), which keeps the latency percentiles the server's own: a CLI or hook
  process opens the index inside the call it times. The note on what the saving leaves out says a lookup is missing only
  where the window reaches back past the first `cli` line the log holds; a log with no `cli` line keeps the
  clause, since it cannot tell a machine that never used the CLI from a log that predates it.
  **The CLI never speaks about the log**: its output is the answer, and an agent reads all of it, so a write the
  log refuses (a shell sandbox that cannot reach `~/.sift`) is dropped without a word; under Codex that lookup is
  simply not counted (the Codex wiring section has why).
- **Toolchain coupling.** SwiftSyntax must match the compiler version, so it is pinned exactly. The pin
  is the whole guard: nothing checks the toolchain at run time.
- **Stale confidence.** A wrong answer delivered fast is worse than a slow correct one, so every ambiguity
  resolves toward refusing to answer.
- **Dependency churn.** SwiftSyntax breaks API across majors routinely and `indexstore-db` has no semver
  releases at all, so a small maintenance tax falls at each toolchain update: bump the pins, run the
  fixture tests.
- **Concurrent access.** Two agent sessions, or the CLI beside the MCP server, on one repository: WAL
  allows exactly one writer, so every writing connection sets a five-second busy timeout — SQLite's own
  wait-and-retry, with no retry layered above it — and no background work may hold a transaction across
  a parse.

## 9. Publishing: what the tree is allowed to say

This repository is published, so its tracked tree *is* the artifact — on the premise that the public
repository is cut fresh with no history carried over, since both gates read the tip and neither reads
history: a name committed and later taken out is still in the object database. Two gates stand over it,
and they are deliberately of opposite kinds.

**9.1 The blocklist.** `Distribution/private-terms.txt` holds a short list of
generic phrases, and `Distribution/verify-private.sh` adds to them the names of the directories sitting
beside the checkout, discovered at run time so that the private names themselves are never committed.
Beside the **primary** checkout, and which directory that is comes from git rather than from path
arithmetic: `rev-parse --git-dir --git-common-dir`, equal meaning this is the repository's main working
tree, which `--show-toplevel` names, and different meaning a linked worktree, whose main tree
`git worktree list` reports first. The parent of the common git directory is the checkout in the
ordinary layout and in no other — a bare repository sits beside the projects it would be named after,
and a `--separate-git-dir` checkout keeps its git directory anywhere — and reading it that way would not
fail, it would discover fewer names and pass. Where no checkout can be anchored at all the gate
**refuses** (exit 1). Only *this machine holds no other projects to learn names from* (exit 2) is a
report a push may continue past, because that one is a fact about the machine rather than about the
tree being pushed.
`Distribution/verify-tree.sh` runs that over the working tree, tracked plus untracked-not-ignored less
`--deleted`, from `githooks/pre-push` and again before publishing; `ShippedDocumentsTests` runs the same words
plus the builder's identity on every `swift test` (tracked only, the narrower claim) and `PrivacyGateTests`
covers the gate's own verdicts. The untracked half is not a detail: from `ls-files` alone a scratch file
naming a sibling project would clear the gate until somebody staged it, the *blind until staged* shape §9.3
describes. The gate reads every file as bytes, in the C locale, since under UTF-8 `grep` skips everything from
the first invalid byte on a line; a needle outside ASCII is matched under the caller's locale as well, for
case-folding only that locale has. A discovered name is matched as a substring, less a hit whose case
changes where the name's own spelling never does (`Ergo` inside `underGoing`); what that leaves unmatched
and the cost of a line dense with near-misses are stated in the script's header.

**9.2not.

**9.2 Why a blocklist alone cannot close.** A blocklist checks the names it can enumerate, and a leak sits
in exactly what it cannot name: prose has no vocabulary to grep for, a product or a measurement taken from
elsewhere was never anybody's neighbouring directory, and a codebase belonging to somebody else reads
*more* ordinary than an invention rather than less, so no reviewer's eye stops on it. The category the
check has to notice is *a name that arrived without anybody putting it here on purpose*, and no
enumeration of forbidden names describes that category.

**9.3 The permit list.** `Distribution/example-names.txt` enumerates the compound identifiers this
repository is allowed to say in an *example* position — a fixture, a string literal, a doc comment, a
document. `ExampleNamesTests` reads every file in the tree on every run and fails on anything the list does
not carry. Three properties make it work:

- **The tree is what git tracks plus what it neither tracks nor ignores.** `git ls-files` alone would make
  the gate blind rather than strict — a new file's name passing until the day somebody staged it, where
  the claim is that a name fails on the day it is *written* — and would make the two halves disagree about
  the same file: adding a fixture and its permit line together, which is what the refusal asks for, would
  have the staleness check calling the new line dead. Both halves read one set, built from `ls-files -z` and
  `ls-files -z --others --exclude-standard` with what `--deleted` names taken back out. A scratch file
  nobody means to commit is inside the gate deliberately; the one way out is `.gitignore`, which is a
  decision somebody makes rather than one a new file makes by default.

- **Names this repository declares are not on it.** Those are code: the compiler governs them, a rename
  is a build error, and a list obliged to carry every one of them would fire on an ordinary
  morning's work and be switched off inside a week. `ExampleNameScanner` splits a `.swift` file into a
  code half and an example half, harvests declarations from the first and reads names only out of the
  second — and harvests from the *code* half specifically, so a fixture holding a declaration inside a
  string literal cannot declare its own permission.
- **The list is published and safe to read.** Every entry is an invented placeholder or public framework
  API — `SwiftSyntax`, `HealthKit`, the rest. Read end to end it says what this repository invents and
  nothing about what else is on the machine it was written on. The one repair the failure message rules
  out is adding a real name to it, which is publishing the leak and switching off the alarm that found
  it; the two it names are renaming the fixture to an existing placeholder, and adding a genuinely new
  invention deliberately. Sorted, one name per line, and pruned when its last use goes, so a commit that
  adds a line is the diff a human stops and reads.

The two gates stay side by side, because they miss opposite things. A neighbouring project's name written
into a sentence of prose is invisible to the permit list the moment it is spelled like permitted
vocabulary, and is exactly what the term check reads every file for.

**9.4 The captures, and the one exemption.** `Tests/SiftCoreTests/Fixtures/RunOutput/*.txt` are byte-exact
tool output whose value is that nobody edited them, and thousands of the names in them are the build
system's own vocabulary. They are exempt from the permit list — the only files that are — and an
exemption is where a leak can sit: a capture carries whatever the shell that produced it printed, an
exported `PATH` included. An exemption from one check is a reason to write the other, not a reason to stop
looking, so the same suite reads the captures for environmental disclosure instead: an exported `PATH`
naming anything outside the toolchain and the system, any home directory but the placeholder
`/Users/dev`, and any machine identifier — a destination's id in either shape, a simulator's device
directory, a DerivedData hash, a per-user `/var/folders` path — but its placeholder, which the test names
for each. Substitutions made to a capture are
recorded in `PROVENANCE.md` beside it.

**9.5 The tree carries rules, never their history.** A document or a comment here states a rule and the
general reason for it — never how the rule was found. No dates of past events, no incident narratives, no
private issue or pull-request numbers, and nothing tied to a particular machine, session or person: each
is a detail about somebody's work that a published tree would carry to everyone who reads it, and the
public repository, cut with no history, could not resolve an issue number anyway. A reason that can only
be told as a story is restated as the general case it proves, or left out; the story belongs to version
control, not the tree. The part a machine can check is enforced by
`Tests/SiftCoreTests/CommentHistoryTests.swift` on every `swift test`, over the tree §9.1 argues a gate
must read — what git tracks plus what it neither tracks nor ignores, less deleted paths — so a new file is
held to it the day it is written. It fails on any comment line of a `.swift` file, `Package.swift`
included, that carries an ISO date, a `#NN` reference, an issue or pull request named in words, or a
tracker URL; and on any `#` comment of a shell script — the `*.sh` files and the `githooks/` hooks — that
carries a date, a `#NN` reference, a named issue or pull request, or a tracker URL. In shell the `#NN`
check reads the comment after its leading run of `#` markers and the blanks that follow them, since there
the marker is itself a `#`: a reference later in the comment is caught, while a shebang, a `##` heading
and a number opening the comment are not. Anecdote without a date stays a reviewer's call.

## 10. Planned: measuring on your own code

Two commands that are designed here and not built. Neither makes a claim about a number: both exist so a developer
can find the answer on their own code, and so a result from code nobody else may see can still reach the people
who maintain the tool.

**10.1 `sift trial` — a developer's own paired measurement.** The paired harness in `Benchmarks/` with a front
door. The developer names a task (a prompt) and, where they can, a check (an expected answer, or a test command
that must pass). The tool runs the task in two isolated arms, one with sift and one without, and reports.
Conditions for the result to mean anything:

- **Two separate fresh sessions per repeat, never one agent doing both.** An agent doing a task a second time
  already knows the answer. Arms are isolated as `Benchmarks/README.md` describes, and their order alternates.
- **Repeats and a range.** One arm on one task varies widely between repeats, so the default is five and the
  report gives an interval; where the interval straddles zero it says "no detectable difference".
- **A correctness check.** Without a check the two arms' final answers are compared, any disagreement is
  flagged for the developer, and the run is reported as unchecked.
- **A liveness check before any model call.** The hook must answer a whole-file read in the trial corpus, and the
  report says whether a compiler index answered. A trial with sift inert is refused, never reported.
- **Raw input as the headline**, with turns, tool calls and peak context; the cache-weighted figure is secondary.
- **The cost is estimated and printed before it starts**, because it spends the developer's own tokens.
- **It can say sift lost**, per task, with the shape of the call that cost more.

The corpus is the developer's repository at its current commit, copied outside any build directory. The report
states its own limits: these tasks only; one model and version on one day; three to five typical tasks is the
smallest set worth reading. Its output is a local report, and on request the shareable form of §10.2.

A check is either an answer pattern set (every pattern must match the final answer) or a command whose exit
status is the verdict, run in the arm's copy after the session ends.

**10.2 `sift misses --shareable` — a miss report with no code, names or paths.** Reads what sift already keeps (its
usage log, the hook's ledger, the session transcripts the audit already scans) and writes one plain-text file. It
sends nothing anywhere: the person reads the file, then decides whether to attach it to a report.

Each record is one sift call, or one lookup sift did not answer:

- the tool and the query's *shape*, never its text: which fields were used, and a class for each value (a single
  name, an alternation of names, a regex, a qualified member, a file with a line);
- the verdict and the rule that decided it, by its code name, which is sift's own vocabulary;
- sizes: the answer in characters, and what the agent's next calls returned;
- what came next, as kinds only: a ranged read inside the answer's range, a grep for the same target, a
  whole-file read;
- the environment: sift version, whether a compiler index answered, toolchain, and the tree's size in buckets.

What stands in for the data: identifiers become tokens from a hash salted per report, with the salt never
written, so "the same symbol was asked twice" is visible and nothing can be reversed or joined across reports;
paths become their depth and extension, with components hashed the same way except a closed list of generic
directory names kept in clear (`Sources`, `Tests`, `.build`, `DerivedData`, `checkouts`), because a rule can turn
on one of those; lengths and counts are bucketed. No source line, string literal, comment, query text or error
text copied from the tree is ever written.

**The guarantee is mechanical.** Before the file is written it is checked against every identifier, path
component and string-literal word the tree's own index holds, and against a closed list of words a report may
contain. Any hit refuses the report and names the field that leaked: the repository's own privacy gate (§9)
turned on the tool's output, failing closed. It is tested by planting names in a fixture tree and asserting none
reaches the file. The report lists exactly which facts it carries (a shape can still say that a tree has a string
catalog, or how deep its folders go), so the person can judge before sending.

**Order.** `sift misses` waits on the record of a miss that the workaround study fixes; the shareable report is
that record, redacted. `sift trial` waits on the harness's liveness check and its raw-input metric.
