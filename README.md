# Sift

**A Swift toolkit for AI coding agents: an index of your code, builds and tests that tell the truth, and
checks on every change.**

Sift is one binary, a command-line tool and an MCP server, for agents (and people) working in Swift:

- **Read code by structure.** `digest`, `where`, `search` and `strings` answer from an index of your code: a
  type's members with their line ranges, every caller and conformer, code found by its shape.
- **Build and test.** `sift run` wraps `swift build`, `swift test` and `xcodebuild` and prints the verdict and
  what failed, not the log. It also ranks what is slow to compile and shards a scheme's tests across
  simulators.
- **Check a change.** The tests your diff reaches, whether a test really fails without your fix, a review
  declaration by declaration, and which changed lines the tests ran.
- **Keep agents on it.** Hooks for Claude Code (Cursor and Codex experimental) steer lookups to the index and
  builds through `sift run`.

Everything runs on your machine.

```
$ sift digest CheckoutModel
tree: Shop  head: 4be21c0  clean  semantic: fresh
CheckoutModel — Shop — Sources/Shop/CheckoutModel.swift:14-612
@Observable final class CheckoutModel

stored properties:
  private(set) var basket: Basket  :17
  private(set) var state: CheckoutState = .idle  :18
  private let payments: PaymentService  :21

members:
  init(basket: Basket, payments: PaymentService)  :24-28
  func applyCoupon(_ code: String) async throws  :31-74
  func placeOrder() async throws -> Receipt  :77-140
  var canPlaceOrder: Bool  :143-151
  …
```

```
$ sift run -- swift test
✔ swift test
  Swift Testing (bundle 1 of 2, 2786 tests in 375 suites): 0 failures, 1 known issue
  Swift Testing (bundle 2 of 2, 3609 tests in 521 suites): 0 failures, 2 known issues
totals: ✔ passed · Swift Testing 6395 tests in 896 suites across 2 bundles
  event stream: 6395 Swift Testing endings, the console relayed 6329 — the other 66 read from the stream
inventory: 6395 declared, 6395 reported (4 outside this run's scope)
raw: .sift/runs/run-20261007-105807Z-11fbda0b.log (17789 lines in, 7 out)
```

The first is a 600-line type as a table of contents. The second is Sift's own test suite: 17,789 lines of
output, seven of them worth reading, with the full log kept and named on the last line.

## Why

An agent working in Swift spends its time reading code and running the toolchain, and both go wrong in
predictable ways:

- **grep doesn't understand Swift.** It can't tell a call from a comment or follow a protocol to its
  conformers, so the agent falls back to reading a whole 600-line file to find one method.
- **Build logs are huge.** One `xcodebuild` prints hundreds of lines of plan and argument dump around one
  result, and the agent reads all of them, every time it checks its work.
- **Green can mean nothing ran.** A `--filter` with a typo, a test target that didn't build, a suite that was
  never discovered: the exit code is 0 and the agent reports success.
- **A passing test may pin nothing.** It can pass just as well without the fix it was written for.

Sift answers each of these with a command that says exactly what it checked.

## What it does

### Read code by structure

- **`digest`**: a type, file or module, each member with its line range; `digest Type.member` for one
  member's source, or what a SwiftUI view's `body` builds.
- **`where`**: declarations, extensions, conformers, overrides and callers, and what uses a type.
- **`search`**: shapes grep can't express, like tests that start a `Task` and never await it:
  `sift search 'kind:func attr:Test calls:Task !has:await'`.
- **`strings`**: on-screen text back to its localization key and the code that shows it.
- **`similar`** and **`dupes`**: code shaped like code you already have, before you write it twice.
- **`--at <rev>`**: `digest` and `where` as of a commit, branch or tag.

The index builds itself the first time you ask and re-parses whatever you've edited. With your build's
index store, `where` resolves callers properly rather than matching names. Every index answer opens with a
line saying which tree it describes and how fresh it is, and when it can't be sure (an index store older
than your edits, say), it says so rather than guessing.

### Build and test

```
$ sift run -- swift test
✘ swift test — exit 1
  aFailingTest() — Tests/SiftCoreTests/DepotStoreTests.swift:11 (body :8-12)
    Expectation failed: depot.count == 2 → false depot.count → 1
totals: ✘ failed · Swift Testing 1 test in 1 suite, 1 failure
raw: .sift/runs/run-20260929-090807Z-1b642cfb.log (17 lines in, 5 out)
```

- **`sift run`** wraps `swift build`, `swift test` and `xcodebuild` and keeps what you act on: errors with
  file, line and column, test failures with their messages, deduplicated warnings. On 20 build and test
  outputs (18 cases on a clone of this repository, green and red, and 2 replays of a real iOS app's
  `xcodebuild` log) it cut the bytes by a median 94%, and no answer was ever larger than its log
  ([Benchmarks](Benchmarks/RESULTS-run-compression.md)).
- **Nothing ran is a failure.** A filtered run that executed none of its tests exits 4 and names the filter.
  A filtered run whose build failed before any test started exits 5, so it doesn't read as a failing test.
- **The count is checked.** An unfiltered `swift test` is compared against the tests the index declares
  (`inventory: 6395 declared, 6395 reported`), so a test that silently never ran shows up, as a note under
  the verdict; the exit code stays the test command's.
- **A failure it can't explain gets the raw log**, not a reassuring summary of nothing.
- **`sift build --analyse`**: the function bodies and expressions slowest to type-check.
- **`sift test`**: a scheme's tests sharded across simulators it creates and deletes, from one build.
- **`sift run --proved`**: whether this exact command already passed on this exact tree, without running it.
- **`sift flakes`**: the tests that have both failed and passed across your runs.

### Check a change

```
$ sift run --without Sources/ -- swift test --filter WidgetTests
✘ 1 of 2 fails without Sources/ and passes with it
  ✘ sizeIsCarried() — passes without Sources/ too, so it pins nothing
  ✔ shoutingWorks() — fails without Sources/, passes with it
  set aside and put back: 3 paths under Sources/ (1 with staged changes, 1 with unstaged changes, 1 untracked), checked by content hash
  …
```

- **`sift run --without`**: sets your change aside, runs the tests, puts the change back exactly (checked by
  content hash, on every exit path, including Ctrl-C), runs them again and answers test by test.
  `--since <rev>` does the same for a fix already committed.
- **`sift affected`**: the tests your diff can reach, with ready-to-paste `-only-testing:` arguments.
- **`sift diff`**: a change reviewed declaration by declaration, with the callers of every changed signature
  and the tests that reach it.
- **`sift run --coverage`**: which lines of each changed declaration the tests ran.

### Keep agents on it

Registering a tool doesn't mean an agent will use it. `sift install` adds hooks to Claude Code that:

- start each session with a short primer, only in repositories with Swift in them;
- answer a Swift file read, grep or glob in place when the index has a smaller answer. Running the same
  command again always goes through, so nothing is ever blocked for good;
- point a bare `swift build`, `swift test` or `xcodebuild` at `sift run`;
- hand an edit that left a `.swift` file unparseable straight back with its errors;
- send a session that edited Swift back, once, to run the build before it stops.

Cursor and Codex are supported too (experimental): the four query tools and their own hooks.

The server exposes only the query tools (`digest`, `where`, `search`, `strings`).
Everything else stays on the command line, so the tool list your agent carries stays small.

## Install

You need macOS 13 or later on Apple silicon, and Swift 6.2 or later to build it. Put `~/.local/bin` on your
`PATH` first: agents run `sift` from the shell, and `sift install` registers the binary you run it from.

```sh
git clone https://github.com/Agulhas-Labs/sift.git
cd sift
swift build -c release
mkdir -p ~/.local/bin
cp .build/release/sift ~/.local/bin/sift.new && mv -f ~/.local/bin/sift.new ~/.local/bin/sift
sift --version
```

Copy to a new name and then rename, as above: macOS kills a binary rewritten in place, with exit 137 and no
message.

Then set it up in your agents:

```sh
sift install
```

It finds Claude Code, Cursor and Codex, asks once for each, and installs the MCP server and hooks in the ones
you accept. Then start a new Claude Code session, restart Cursor, or restart Codex and approve the hooks it
asks you to trust; `sift doctor` checks each one. A second run changes nothing and says so; `--dry-run`
previews it.
`sift uninstall` takes it all back out.

Or with Homebrew:

```sh
brew install agulhas-labs/tap/sift
```

Give the full name: homebrew-core has an unrelated formula called `sift` (a grep alternative), so
asking Homebrew for plain `sift` installs the wrong tool.

## Use it yourself

The CLI gives the same answers, so it's handy for your own digging too. There's no setup step: a repository
indexes itself the first time you ask.

```sh
cd MyApp
sift digest SettingsView          # what's in it, and what body builds
sift where PaymentService.charge  # declaration, callers, overrides
sift search 'kind:class !modifier:final inherits:UIViewController'
sift run -- swift test            # just the failures
sift status                       # what's indexed, and how fresh
```

## Privacy

Nothing leaves your machine. The index is a SQLite file at `.sift/index.db`, kept out of `git status`. Your
source is never changed on its own, and `sift run --without` puts back every byte it sets aside.
`sift install` edits each agent's settings and copies each file to `.bak-sift` before a rewrite. [What it touches](Docs/Guide.md#10-what-it-touches)
lists every file, down to what each log line holds.

## More

- [The guide](Docs/Guide.md): setup, configuration, monorepos, index stores and freshness, `sift run` in
  depth, and the full command reference.
- [Docs/Design.md](Docs/Design.md): how it works and why, including what it deliberately doesn't do.
- [Docs/AnswerContract.md](Docs/AnswerContract.md): what every answer promises about itself.
- [Benchmarks/](Benchmarks/): what we measured and how to rerun it.
- [CHANGELOG.md](CHANGELOG.md)

## License

Apache 2.0. See [LICENSE](LICENSE).
