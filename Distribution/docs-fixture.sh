#!/bin/sh
# Creates the sample package every article in Docs/Sift.docc runs its examples in, so each pasted answer
# can be reproduced and none of them comes from a different build of the sample.
#
# Usage:  sh Distribution/docs-fixture.sh <dir> [pad]
#
# <dir> must not exist or must be empty. Its last component is the tree name the answers print
# (`tree: Shelf` when <dir> ends in `Shelf`). The package is a module called `Stacks` with four types
# (Library, Book, Shelf, Loan) and a test target of three Swift Testing tests, committed once with a fixed
# author, committer and date, so the head hash in every answer's header is the same on every machine.
# Nothing here touches the repository this script lives in or any git configuration.
#
# Variants the articles use:
#   a failing test:   change `== 1` to `== 2` on the `overdue` line of Tests/StacksTests/LibraryTests.swift
#   a stale answer:   append a comment line to Sources/Stacks/Library.swift after `swift build --build-tests`
#   a broken edit:    delete the `)` that ends the parameters of `init` in Sources/Stacks/Book.swift
#   a long file:      pass `pad` as the second argument. After the commit it appends sixty members to
#                     Library.swift, so the file is long enough for a whole-file read to be stopped and,
#                     at over one and a half times the size where the digest starts to pay, still answered
#                     by a digest. The change is left uncommitted (`dirty: 1`), and the head hash is the same.
set -eu

{ [ "$#" -ge 1 ] && [ "$#" -le 2 ]; } || { echo "usage: sh Distribution/docs-fixture.sh <dir> [pad]" >&2; exit 1; }
DIR="$1"
PAD="${2:-}"
[ -z "$PAD" ] || [ "$PAD" = "pad" ] || { echo "docs-fixture: the second argument is 'pad' or nothing" >&2; exit 1; }
if [ -e "$DIR" ] && [ -n "$(ls -A "$DIR")" ]; then
    echo "docs-fixture: $DIR is not empty" >&2
    exit 1
fi
mkdir -p "$DIR/Sources/Stacks" "$DIR/Tests/StacksTests"
cd "$DIR"

cat > Package.swift <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stacks",
    products: [.library(name: "Stacks", targets: ["Stacks"])],
    targets: [
        .target(name: "Stacks"),
        .testTarget(name: "StacksTests", dependencies: ["Stacks"]),
    ]
)
EOF

printf '.build/\n.sift/\n' > .gitignore

cat > Sources/Stacks/Book.swift <<'EOF'
import Foundation
/// A title the library holds.
public struct Book: Sendable, Hashable {
    public let title: String
    public let author: String
    public let pages: Int

    public init(title: String, author: String, pages: Int) {
        self.title = title
        self.author = author
        self.pages = pages
    }

    /// True when the title starts with the given prefix, ignoring case.
    public func titleStarts(with prefix: String) -> Bool {
        title.lowercased().hasPrefix(prefix.lowercased())
    }

    /// A line for a catalogue card.
    public var card: String {
        "\(title) by \(author), \(pages) pages"
    }
}
EOF

cat > Sources/Stacks/Shelf.swift <<'EOF'
import Foundation
/// A row of books, in order.
public struct Shelf: Sendable {
    public private(set) var books: [Book] = []

    public init() {}

    public mutating func add(_ book: Book) {
        books.append(book)
    }

    public mutating func take(title: String) -> Book? {
        guard let index = books.firstIndex(where: { $0.title == title }) else {
            return nil
        }
        return books.remove(at: index)
    }

    public var isEmpty: Bool {
        books.isEmpty
    }
}
EOF

cat > Sources/Stacks/Loan.swift <<'EOF'
import Foundation
/// A book out on loan.
public struct Loan: Sendable {
    public let book: Book
    public let borrower: String
    public var days: Int

    public init(book: Book, borrower: String, days: Int) {
        self.book = book
        self.borrower = borrower
        self.days = days
    }
}
EOF

cat > Sources/Stacks/Library.swift <<'EOF'
import Foundation
/// Holds the shelves and the loans out of them.
public final class Library {
    public private(set) var loans: [Loan] = []
    private var shelf = Shelf()
    private let limit: Int

    public init(limit: Int = 3) {
        self.limit = limit
    }

    public func stock(_ book: Book) {
        shelf.add(book)
    }

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

    public func giveBack(title: String) -> Bool {
        guard let index = loans.firstIndex(where: { $0.book.title == title }) else {
            return false
        }
        let loan = loans.remove(at: index)
        shelf.add(loan.book)
        return true
    }

    public func count(for borrower: String) -> Int {
        loans.filter { $0.borrower == borrower }.count
    }

    public func overdue(after days: Int) -> [Loan] {
        loans.filter { $0.days > days }
    }

    public var available: Int {
        shelf.books.count
    }

    public func longestLoan() -> Loan? {
        loans.max { $0.days < $1.days }
    }

    public func borrowers() -> [String] {
        Array(Set(loans.map(\.borrower))).sorted()
    }

    public func summary() -> String {
        "\(available) on the shelf, \(loans.count) out"
    }

    public func extend(title: String, by extra: Int) -> Bool {
        guard let index = loans.firstIndex(where: { $0.book.title == title }) else {
            return false
        }
        loans[index].days += extra
        return true
    }
}
EOF

cat > Tests/StacksTests/LibraryTests.swift <<'EOF'
import Testing
@testable import Stacks

struct LibraryTests {
    private func stocked() -> Library {
        let library = Library()
        library.stock(Book(title: "Tides", author: "Reyes", pages: 210))
        library.stock(Book(title: "Atlas", author: "Okafor", pages: 340))
        return library
    }

    @Test
    func lendingMovesABookToLoans() {
        let library = stocked()
        let loan = library.lend(title: "Tides", to: "Cleo", days: 7)
        #expect(loan?.borrower == "Cleo")
        #expect(library.available == 1)
    }

    @Test
    func givingBackRestocks() {
        let library = stocked()
        _ = library.lend(title: "Atlas", to: "Cleo", days: 7)
        #expect(library.giveBack(title: "Atlas"))
        #expect(library.available == 2)
    }

    @Test
    func overdueCountsLongLoans() {
        let library = stocked()
        _ = library.lend(title: "Tides", to: "Cleo", days: 30)
        #expect(library.overdue(after: 14).count == 1)
    }
}
EOF

# One commit, everything fixed: author, committer, date, message. The environment is scrubbed of GIT_*
# first and the repository gets no hooks and no signing, so the hash does not depend on the machine.
for name in $(env | sed -n 's/^\(GIT_[A-Za-z_]*\)=.*/\1/p'); do unset "$name"; done
git init -q -b main
export GIT_AUTHOR_NAME="Stacks Docs" GIT_AUTHOR_EMAIL="docs@example.com" GIT_AUTHOR_DATE="2026-01-01T00:00:00+0000"
export GIT_COMMITTER_NAME="Stacks Docs" GIT_COMMITTER_EMAIL="docs@example.com" GIT_COMMITTER_DATE="2026-01-01T00:00:00+0000"
git add -A
git -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "Stacks: the sample package for the Sift documentation"
if [ -n "$PAD" ]; then
    # Drop the class's closing brace, add sixty members of one shape, close it again.
    sed '$d' Sources/Stacks/Library.swift > Sources/Stacks/Library.swift.new
    n=1
    while [ "$n" -le 60 ]; do
        cat >> Sources/Stacks/Library.swift.new <<EOF

    public func holds$n(title: String) -> Bool {
        guard let loan = loans.first(where: { \$0.book.title == title }) else {
            return false
        }
        let longer = loan.days > $n
        let renewed = loan.days > $n * 2
        let known = borrowers().contains(loan.borrower)
        return longer && !renewed && known
    }
EOF
        n=$((n + 1))
    done
    echo "}" >> Sources/Stacks/Library.swift.new
    mv Sources/Stacks/Library.swift.new Sources/Stacks/Library.swift
fi
echo "docs-fixture: wrote $DIR at $(git rev-parse --short HEAD)"
