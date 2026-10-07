# The Four Tools

Ask `digest`, `where`, `search` and `strings` the right question, and read how far each answer can be trusted.

## Overview

Sift answers through four tools, on the command line and over MCP. They share one habit: each answer opens
with a header saying which tree it describes and how it was produced (see <doc:GettingStarted> for the
fields). The examples here run in the same small package as there: four types, `Library`, `Book`, `Shelf`
and `Loan`, in a module called `Stacks`.

### digest: the shape of code, with line ranges

Reach for `digest` when you want to know what is in a module, a file or a type, or where in a file
something lives, before you read any of it. It takes a module, a type, a repo-relative file path or a
cited location such as `Library.swift:30`, and `.` for the repository overview.

```text
$ sift digest Library
tree: Shelf  head: ec26cde  clean  semantic: syntactic-only
Library — Stacks — Sources/Stacks/Library.swift:3-69
public final class Library

stored properties:
  public private(set) var loans: [Loan] = []  :4
  private var shelf = Shelf()  :5
  private let limit: Int  :6

members:
  public init(limit: Int = 3)  :8-10
  public func stock(_ book: Book)  :12-14
  public func lend(title: String, to borrower: String, days: Int) -> Loan?  :16-27
  public func giveBack(title: String) -> Bool  :29-36
  public func count(for borrower: String) -> Int  :38-40
  public func overdue(after days: Int) -> [Loan]  :42-44
  public var available: Int  :46-48
  public func longestLoan() -> Loan?  :50-52
  public func borrowers() -> [String]  :54-56
  public func summary() -> String  :58-60
  public func extend(title: String, by extra: Int) -> Bool  :62-68

synthesized members (memberwise init, Codable) not listed
```

Each member carries its line range, so the next step is a ranged read of the lines you want, or
`sift digest Library.lend` for that one member's source. A digest is read from the source alone, so it is
`syntactic-only` and never stale: files you have edited are reparsed before it answers. Code short enough
that a digest would cost as much as the code comes back as the source itself.

### where: definitions, callers and uses

Reach for `where` when you know a name and want its declaration, its conformers, overrides and callers, or
(with `--refs`) every place it is referenced before a rename or a delete. Without a build, it matches
written names:

```text
$ sift where Library.lend
tree: Shelf  head: ec26cde  clean  semantic: none (no index store — see note)
where Library.lend
mode: syntactic (sift help answers); no index store for this tree yet; how to build one: sift help answers, section (index store)
callers/overrides: NOT ANSWERED from the index store; see the mode line above.

declarations (1):
  Stacks.Library.lend(title:to:days:) — func — public func lend(title: String, to borrower: String, days: Int) -> Loan? — Sources/Stacks/Library.swift:16-27

syntactic call sites — by written name over the working tree, never stale — see sift help answers (call sites)

"lend" (3 call sites in 1 file):
  Tests/StacksTests/LibraryTests.swift:
    :15  in LibraryTests.lendingMovesABookToLoans().loan  | let loan = library.lend(title: "Tides", to: "Cleo", days: 7)
    :23  in LibraryTests.givingBackRestocks()  | _ = library.lend(title: "Atlas", to: "Cleo", days: 7)
    :31  in LibraryTests.overdueCountsLongLoans()  | _ = library.lend(title: "Tides", to: "Cleo", days: 30)
```

After `sift run -- swift build --build-tests` has written the compiler's index, the same question is
answered from it:

```text
$ sift where Library.lend
tree: Shelf  head: ec26cde  clean  semantic: fresh
where Library.lend
mode: syntactic + semantic (index store via .build)

declarations (1):
  Stacks.Library.lend(title:to:days:) — func — public func lend(title: String, to borrower: String, days: Int) -> Loan? — Sources/Stacks/Library.swift:16-27

callers of Stacks.Library.lend(title:to:days:) (3):
  Tests/StacksTests/LibraryTests.swift (3):
    :15  lendingMovesABookToLoans()  | let loan = library.lend(title: "Tides", to: "Cleo", days: 7)
    :23  givingBackRestocks()  | _ = library.lend(title: "Atlas", to: "Cleo", days: 7)
    :31  overdueCountsLongLoans()  | _ = library.lend(title: "Tides", to: "Cleo", days: 30)
```

### search: code by shape

Reach for `search` when the question is about form rather than a name: every function that calls something
and throws, every `@Test` that wraps a call in an unstructured `Task`, every async function that never
awaits. Terms are `field:value`, ANDed, and `!` negates one. Quote the query so the shell leaves it whole.

```text
$ sift search 'kind:func calls:filter'
tree: Shelf  source: working tree, read live — nothing stored to go stale
search kind:func calls:filter
2 declaration(s) in 1 file(s) — scanned 5 file(s)
syntactic shape match over the working tree — never stale, never refuses; calls:/uses: match written names, not resolved symbols, so same-named members of unrelated types are included — confirm a specific hit with where.

Sources/Stacks/Library.swift:
  :38-40  Library.count(for:) — public func count(for borrower: String) -> Int
  :42-44  Library.overdue(after:) — public func overdue(after days: Int) -> [Loan]
```

The Guide lists every field. When nothing matches, the answer says which term removed the last candidates
(`effect:throws removed the last 16 declaration(s)`), so an empty result tells you which condition to loosen.

### strings: from wording to code

Reach for `strings` when you have text from the screen or a log and want the code behind it. It looks in
string catalogs (`.xcstrings`, `.strings`) and in Swift string literals:

```text
$ sift strings 'on the shelf'
tree: Shelf  source: working tree, read live — nothing stored to go stale
strings "on the shelf"
no string catalogs (.xcstrings / .strings) in this repo

source literals (Swift string literals holding the wording, not catalog entries):
  Library.summary() — Sources/Stacks/Library.swift:59: "\(available) on the shelf, \(loans.count) out"
```

### Reading the answer honestly

- **The header names its source.** `digest`, `search` and `strings` read the working tree, so none of them
  can be out of date, but a read of source is all they are. `search` and `strings` say so with `source:
  working tree, read live`.
- **`semantic: none` is a limit, not a verdict.** With no index store for the tree, `where` matches written
  names. It says `callers/overrides: NOT ANSWERED from the index store` and still lists the call sites it
  found by spelling. A call through a different spelling, a type used only in an annotation or a
  conformance, a `#selector` and a name inside a string are not in that list. Read a short list as "no call
  of that name was found", never as "nothing uses this".
- **A type has no calls.** The syntactic fallback answers for methods and properties by their written
  calls. For "who uses this type" or a rename sweep, build first and ask `where --refs`.
- **`semantic: stale` refuses.** If your edits are newer than the last build, `where` refuses the affected
  symbols until you build again. Re-running the query does not help.
- **Matches are names, not resolved symbols.** `calls:` and `uses:` in `search` match what is written, so
  confirm a specific hit with `where`.
- **`parse_errors:` above zero** means a file in the repository did not parse cleanly. A banner under the
  header says when the answer in front of you drew on one.

## Next steps

The guide has the full account of
[what an answer promises](https://github.com/Agulhas-Labs/sift/blob/main/Docs/Guide.md#6-what-an-answer-promises),
[semantic answers](https://github.com/Agulhas-Labs/sift/blob/main/Docs/Guide.md#7-semantic-answers-need-a-real-build)
and [every `search` field](https://github.com/Agulhas-Labs/sift/blob/main/Docs/Guide.md#8-finding-code-by-shape--search).
To wrap builds and tests, see <doc:RunningBuildsAndTests>.
