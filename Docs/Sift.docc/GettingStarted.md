# Getting Started

Put `sift` on your machine, ask it a first question in a Swift repository, and read the line every
answer opens with.

## Overview

You need an Apple silicon Mac on macOS 13 or later, and the Swift repository must be a git repository.
Xcode or the Command Line Tools must be installed, because the semantic half finds the compiler's index
through `xcrun`.

### Install

The public repository, the Homebrew tap and the npm package are not published yet: the lines marked so show
how installing will work once they are, and nothing else here (a release bundle included) is available to
download.

```sh
brew install agulhas-labs/tap/sift   # not published yet
sift --version
```

Until then, build it from source with Swift 6.2 or later. The clone URL is the repository's future address,
so it does not resolve yet; run the same steps in any checkout of the source:

```sh
git clone https://github.com/Agulhas-Labs/sift.git   # not published yet
cd sift
swift build -c release
.build/release/sift --version
```

The build leaves the binary in `.build/release/`, and nothing puts it on your `PATH`. Every later step, and
the hooks `sift install` registers, run plain `sift`, so copy it somewhere on the `PATH` yourself.
`~/.local/bin` is the usual place:

```sh
mkdir -p ~/.local/bin
cp .build/release/sift ~/.local/bin/sift.new && mv -f ~/.local/bin/sift.new ~/.local/bin/sift
sift --version
```

Copy to a new name and then rename, as here, and do not `cp` over a `sift` that is already installed: macOS
kills a binary rewritten in place, with exit 137 and no message. If `sift --version` says the command is
not found, add `~/.local/bin` to the `PATH` in your shell profile.

Then set it up in the agents you use. See <doc:Installing>, which also says what a source build leaves out.

### Ask a first question

There is no setup step: a repository indexes itself on its first query, which takes a few seconds on a
large tree and happens once. The examples here run in a small package of four types, `Library`, `Book`,
`Shelf` and `Loan`, in a module called `Stacks`. Every sample in these articles was pasted from one run of
`Distribution/docs-fixture.sh` in the source tree, which builds that package, so the line numbers and the
head hash agree from one article to the next and you can reproduce them:

```sh
sh Distribution/docs-fixture.sh ~/code/Shelf
cd ~/code/Shelf
```

The script commits the package once with a fixed author and date, so its `head:` is `ec26cde` on every
machine. The articles show the checkout as `~/code/Shelf`; yours prints wherever you put it. Start with the
module:

```text
$ sift digest Stacks
tree: Shelf  head: ec26cde  clean  semantic: syntactic-only
module Stacks — 4 top-level declarations

Sources/Stacks/Book.swift:
  public struct Book: Sendable, Hashable  :3-23  /// A title the library holds.

Sources/Stacks/Library.swift:
  public final class Library  :3-69  /// Holds the shelves and the loans out of them.

Sources/Stacks/Loan.swift:
  public struct Loan: Sendable  :3-13  /// A book out on loan.

Sources/Stacks/Shelf.swift:
  public struct Shelf: Sendable  :3-22  /// A row of books, in order.
```

Every declaration comes with its line range. To read one member, name it, and only that member's source
comes back:

```text
$ sift digest Library.lend
tree: Shelf  head: ec26cde  clean  semantic: syntactic-only
Stacks.Library.lend(title:to:days:) — func — Sources/Stacks/Library.swift:16-27

    public func lend(title: String, to borrower: String, days: Int) -> Loan? {
        guard let book = shelf.take(title: title) else {
            return nil
        }
        guard count(for: borrower) < limit else {
            shelf.add(book)
            return nil
        }
        let loan = Loan(book: book, borrower: borrower, days: days)
        loans.append(loan)
        return loan
    }
```

For a short type or file, a digest would cost about as much as the code, so `sift digest Library` returns
the source itself and says so.

To find where something is used, ask `sift where`. Without a build it matches written names:

```text
$ sift where Loan
tree: Shelf  head: ec26cde  clean  semantic: none (no index store — see note)
where Loan
mode: syntactic (sift help answers); no index store for this tree yet; how to build one: sift help answers, section (index store)
used by: NOT ANSWERED from the index store (by written name — an empty list is not "unused"); see the mode line above.

declarations (1):
  Stacks.Loan — struct — public struct Loan: Sendable — Sources/Stacks/Loan.swift:3-13  /// A book out on loan.

syntactic uses — by written name over the working tree, never stale — see sift help answers (call sites)

"Loan" used by 5 lines in 1 file — 5 production · 0 tests, split on the XCTest or Testing import, never the path (for Stacks.Loan):
  Sources/Stacks/Library.swift (5):
    :4  | public private(set) var loans: [Loan] = []
    :16  | public func lend(title: String, to borrower: String, days: Int) -> Loan? {
    :24  | let loan = Loan(book: book, borrower: borrower, days: days)
    :42  | public func overdue(after days: Int) -> [Loan] {
    :50  | public func longestLoan() -> Loan? {
```

On a large repository, `sift init` first reports which files got their module from a directory-name guess
rather than from a build file, and proposes the `.sift.json` settings that fix it. It writes nothing unless
you pass `--write`.

### Read the header

The first line of every answer says what it describes and how far to trust it:

```text
tree: Shelf  head: ec26cde  clean  semantic: syntactic-only
```

- `tree:` is the checkout the answer was read from. A linked git worktree is named
  `tree: Name (worktree …)`, so an answer from the wrong tree does not look like the right one.
- `head:` is the git revision the index describes.
- `clean` stands for `dirty: 0  parse_errors: 0`: no Swift file has changed since `head:` and none failed to
  parse. Any other state prints `dirty:` and `parse_errors:` instead.
- `dirty:` is how far the working tree has moved from that revision.
- `parse_errors:` counts files in the repository that did not parse cleanly. Only a banner under the
  header says the answer in front of you drew on one.
- `semantic:` is the mode that produced this answer, not a property of the tree. `syntactic-only` means it
  came from the source alone, which is never stale: files you have edited are reparsed before it answers.
  `none` means the answer asked for the compiler's index and no build has produced one for this tree. After
  a build, `where` can say `fresh`. If the build is older than your edits, it says `stale` and refuses the
  affected symbols until you build again.

To get the semantic half, build the package once so the compiler writes its index:
`sift run -- swift build --build-tests`. Then `sift status` reports which index store it found.

## Next steps

The guide covers [what an answer promises](https://github.com/Agulhas-Labs/sift/blob/main/Docs/Guide.md#6-what-an-answer-promises),
[getting a repository indexing](https://github.com/Agulhas-Labs/sift/blob/main/Docs/Guide.md#5-getting-it-indexing),
and [semantic answers](https://github.com/Agulhas-Labs/sift/blob/main/Docs/Guide.md#7-semantic-answers-need-a-real-build)
in full.
