//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the competitor the metric could not see: `grep`/`sed` on Swift source, in a shell.
struct ShellInspectionTests {
    @Test
    func grepAndSedOnASwiftFileAreLookups() {
        #expect(ShellInspection.isSwiftLookup(#"grep -n "func body" Sources/App/View.swift"#))
        #expect(ShellInspection.isSwiftLookup("sed -n '10,40p' Sources/App/View.swift"))
        #expect(ShellInspection.isSwiftLookup("rg 'some View' Sources/App/View.swift | head"))
        #expect(ShellInspection.isSwiftLookup("cat Sources/App/View.swift"))
    }

    /// Editing a file is ordinary work, not a lookup that avoided the index — and a script that rewrites a source file usually greps it on the way, so the write forms have to win.
    @Test
    func editingASwiftFileIsNotALookup() {
        #expect(!ShellInspection.isSwiftLookup("sed -i '' 's/a/b/' Sources/App/View.swift"))
        #expect(!ShellInspection.isSwiftLookup("python3 - <<'PY'\ns=open('View.swift').read()\nPY"))
        #expect(!ShellInspection.isSwiftLookup("grep -c foo x.txt > Generated.swift"))
        #expect(!ShellInspection.isSwiftLookup("cp Sources/App/View.swift /tmp/View.swift"))
    }

    /// An edit followed by the check that it landed is an edit, in every spelling of the in-place flag.
    ///
    /// The flag usually sits inside a cluster — `-0pi`, `-pi.bak`, `-Ei` — where a phrase list cannot see it, and a line read as the grep beside the edit is refused, holding the edit up with it.
    @Test(arguments: [
        "perl -0pi -e 's/a/b/' Sources/App/View.swift && grep -n 'b' Sources/App/View.swift",
        "perl -pi.bak -e 's/a/b/' Sources/App/View.swift && grep -n b Sources/App/View.swift",
        "perl -p -i -e 's/a/b/' Sources/App/View.swift; grep -n b Sources/App/View.swift",
        "perl -pe 's/a/b/' -i Sources/App/View.swift && grep -n b Sources/App/View.swift",
        "sed -Ei 's/a/b/' Sources/App/View.swift && grep -n b Sources/App/View.swift",
        "sed -E -i '' 's/a/b/' Sources/App/View.swift && grep -n b Sources/App/View.swift",
        "sed --in-place=.bak 's/a/b/' Sources/App/View.swift && grep -n b Sources/App/View.swift",
        #"ruby -pi -e 'gsub(/a/, "b")' Sources/App/View.swift && grep -n b Sources/App/View.swift"#,
        "gawk -i inplace '{ print }' Sources/App/View.swift && grep -n b Sources/App/View.swift",
        "sed '1d' -i Sources/App/View.swift && grep -n b Sources/App/View.swift",
        "sed 's/-> Int/-> Int?/' -i Sources/App/View.swift && grep -n b Sources/App/View.swift",
        "find Sources -name '*.swift' -exec perl -pi -e 's/a/b/' {} + && grep -n b Sources/App/View.swift",
        "git ls-files '*.swift' | xargs perl -pi -e 's/a/b/' && grep -n b Sources/App/View.swift",
    ])
    func anEditInAnyFlagSpellingIsNotALookup(command: String) {
        #expect(!ShellInspection.isSwiftLookup(command))
        #expect(ShellAdvice.suggestion(for: command, holdsSource: nil) == nil)
    }

    /// The same editors reading rather than writing are still lookups: an `i` inside a script, a value or a word searched for is not the flag.
    @Test(arguments: [
        "sed -n -e '/init/p' Sources/App/View.swift",
        "sed -n '/func/p' Sources/App/View.swift",
        "awk -F: '/init/ { print $1 }' Sources/App/View.swift",
        "grep -rn perl Sources/App/View.swift",
        "grep -n 'sed -Ei' Sources/App/View.swift",
    ])
    func anEditorThatOnlyReadsIsStillALookup(command: String) {
        #expect(ShellInspection.isSwiftLookup(command))
    }

    /// Building and linting mention Swift files constantly and inspect nothing.
    @Test
    func buildingAndLintingAreNotLookups() {
        #expect(!ShellInspection.isSwiftLookup("swift build 2>&1 | grep error"))
        #expect(!ShellInspection.isSwiftLookup("swift test --filter ViewOutlineTests"))
        #expect(!ShellInspection.isSwiftLookup("swiftformat Sources/App/View.swift"))
    }

    /// Taking the `sift run` advice must not move the share metric — a wrapped build is still a build, and a build was never a lookup.
    ///
    /// The reason to pin it is that a wrapped command carries the words a lookup rule keys on — `sift run -- swift test` spells `swift`, and `sift run -- xcodebuild …` names no `.swift` path at all — so each form here, wrapped and unwrapped, must read as no lookup. If a wrapped call were ever counted raw, the statusline would punish the session that took the advice.
    @Test
    func aCommandWrappedInSiftRunIsNotALookup() {
        #expect(!ShellInspection.isSwiftLookup("sift run -- swift test"))
        #expect(!ShellInspection.isSwiftLookup("sift run -- swift build -c release"))
        #expect(!ShellInspection.isSwiftLookup("sift run -- xcodebuild -scheme Gizmo test"))
        #expect(!ShellInspection.isSwiftLookup("sift run -- swift test 2>&1 | tail -40"))
        // The unwrapped forms score identically, which is the property that keeps the metric's meaning fixed.
        #expect(!ShellInspection.isSwiftLookup("xcodebuild -scheme Gizmo test"))
        #expect(ShellInspection.windowedReadPath("sift run -- swift test", in: nil) == nil)
    }

    /// Co-occurrence is not application.
    ///
    /// A commit names Swift files and pipes through `tail`, and reads nothing — the segment naming the files does not inspect, and the one inspecting reads command output.
    @Test
    func aVerbAppliedToCommandOutputIsNotALookupOfTheFileNamedElsewhere() {
        #expect(!ShellInspection.isSwiftLookup("git add Sources/App/View.swift && git commit -m x | tail -1"))
        #expect(!ShellInspection.isSwiftLookup("git checkout main Sources/App/View.swift | head"))
        // But the same verbs applied to the file itself still count.
        #expect(ShellInspection.isSwiftLookup("grep -n foo Sources/App/View.swift | head -20"))
    }

    /// A command that merely names a Swift file is not a lookup either.
    @Test
    func merelyNamingASwiftFileIsNotALookup() {
        #expect(!ShellInspection.isSwiftLookup("ls -la Sources/App/View.swift"))
        #expect(!ShellInspection.isSwiftLookup("git add Sources/App/View.swift"))
        #expect(!ShellInspection.isSwiftLookup("wc -l Sources/App/View.swift"))
    }

    /// Nothing outside Swift counts — the metric is about Swift lookups, and a shell is used for everything.
    @Test
    func nonSwiftCommandsAreIgnored() {
        #expect(!ShellInspection.isSwiftLookup("grep -n TODO README.md"))
        #expect(!ShellInspection.isSwiftLookup("cat package.json"))
    }

    /// A `git grep` handed a revision searches a tree the index never held, so it is not a lookup that went around it — the measurement and the advice must agree on that, or the audit counts misses no call could have served.
    @Test
    func aRevisionScopedGitGrepIsNotALookup() {
        #expect(!ShellInspection.isSwiftLookup(#"git grep -n "func signedDelta" origin/feature-branch -- Sources/Trend.swift"#))
        #expect(!ShellInspection.isSwiftLookup(#"git grep -n "applyCoupon" HEAD -- Sources/Catalogue.swift"#))
        #expect(!ShellInspection.isSwiftLookup(#"git grep --cached "applyCoupon" -- Sources/Catalogue.swift"#))
        // The working tree is exactly what the index holds, so that one still counts.
        #expect(ShellInspection.isSwiftLookup(#"git grep -n "func signedDelta" -- Sources/Trend.swift"#))
    }

    /// A verb inside a quoted argument is prose, not an invocation — but inside a substitution it runs, quoted or not.
    @Test
    func quotedTextIsOpaqueAndSubstitutionsStayVisible() {
        #expect(!ShellInspection.isSwiftLookup(#"claude -p "First run this exact bash command: grep -n func Thing.swift . Then reply DONE.""#))
        #expect(ShellInspection.isSwiftLookup(#"echo "$(grep -n func Thing.swift)""#))
        // An escaped quote is a literal, not the end of the masked run.
        #expect(!ShellInspection.isSwiftLookup(#"claude -p "note the \" character, then grep -n func Thing.swift is what we avoid""#))
    }

    /// The deliberate half of the advice/measurement divergence, pinned so it cannot drift: a command that invokes sift draws no advice, but its grep half still counts as going around the index.
    @Test
    func aSiftInvokingCommandStillCountsItsGrepHalf() {
        #expect(ShellInspection.isSwiftLookup(#"sift digest Sources/App 2>/dev/null | head -5; grep -rn "protocol Localizable" Sources/View.swift | head"#))
    }

    /// A relative pathspec searches the working tree — `..` in a path is not a revision range, and `git grep` does not even accept ranges.
    @Test
    func aRelativePathspecGitGrepIsStillALookup() {
        #expect(ShellInspection.isSwiftLookup(#"git grep -n "func signedDelta" ../Sources/Trend.swift"#))
    }

    /// The verb has to be a command word: a path containing one is not an invocation of it.
    @Test
    func aVerbInsideAPathIsNotAnInvocation() {
        #expect(!ShellInspection.isSwiftLookup("ls Tools/ripgrep/Sources/Main.swift"))
        #expect(!ShellInspection.isSwiftLookup("ls Sources/Catalog/Item.swift"))
    }

    /// Segmenting must not split on the `|` *inside* an alternation pattern: that strands the file in a piece with no read verb, so every `grep "a\|b" File.swift` goes uncounted, in a metric whose whole value is that it does not flatter.
    @Test
    func anAlternationPatternDoesNotSplitTheCommand() {
        #expect(ShellInspection.isSwiftLookup(#"grep -n "slateDim\|case sm\|slate" Sources/App/Theme.swift"#))
        #expect(ShellInspection.isSwiftLookup(#"grep -n "let type|var type" Sources/App/Model.swift"#))
    }

    /// The quotes are what stop a quoted command from reading as an invocation, so segmenting has to keep them.
    @Test
    func aQuotedCommandIsStillNotAnInvocation() {
        #expect(!ShellInspection.isSwiftLookup(#"echo "grep Sources/App/View.swift""#))
    }

    /// `rm ` sits inside `perform `, `confirm ` and `transform `, so matched as a substring a grep for any of them reads as a write and vanishes from the count — a three-character marker matches English.
    @Test
    func aPatternContainingAWriteVerbAsASubstringIsStillALookup() {
        #expect(ShellInspection.isSwiftLookup(#"grep -n "perform " Sources/App/Runner.swift"#))
        #expect(ShellInspection.isSwiftLookup(#"grep -rn "confirm " Sources/App/Dialog.swift"#))
        // And the write verbs themselves still win, which is the whole reason they are checked first.
        #expect(!ShellInspection.isSwiftLookup("rm Sources/App/View.swift"))
        #expect(!ShellInspection.isSwiftLookup("cat Sources/App/View.swift | tee /tmp/copy"))
    }

    /// A tree sweep names no `.swift` at all, so no reading of the command text can see it — and it is one of the commonest shapes a lookup takes.
    @Test
    func aDirectorySweepIsALookupOnlyWhenTheTreeCanBeResolved() {
        let command = "grep -rn UsageLog Sources/"
        // Text alone: unanswerable, and it answers "no" rather than guessing.
        #expect(!ShellInspection.isSwiftLookup(command))
        #expect(ShellInspection.isSwiftLookup(command) { $0 == "Sources/" })
    }

    /// A recursive grep that names no path sweeps the working directory, so it is a lookup where that directory holds Swift source.
    @Test
    func aRecursiveGrepWithNoPathSweepsTheWorkingDirectory() {
        #expect(ShellInspection.isSwiftLookup("grep -rn UsageLog") { $0 == "." })
        #expect(ShellInspection.isSwiftLookup("grep -Rn -e UsageLog") { $0 == "." })
        #expect(ShellInspection.isSwiftLookup("grep --recursive UsageLog") { $0 == "." })
        #expect(!ShellInspection.isSwiftLookup("grep -rn UsageLog") { $0 == "Sources/" })
        // Without a recursive flag a grep given no path reads its standard input, which is no tree.
        #expect(!ShellInspection.isSwiftLookup("grep -n UsageLog") { _ in true })
    }

    /// A redirection names where the output goes, not a path searched, so a recursive grep given no path but one still sweeps the working directory.
    @Test(arguments: [
        "grep -rn UsageLog 2>/dev/null", "grep -rn UsageLog 2>/dev/null | head", "grep -rn UsageLog 2>&1",
        "grep -rn UsageLog > out.txt", "grep -rn UsageLog 2> /dev/null",
    ])
    func aRedirectionIsNoPathForARecursiveGrep(command: String) {
        #expect(ShellInspection.isSwiftLookup(command) { $0 == "." })
    }

    /// A flag cluster is recursive where an `r` comes before its first letter that takes a value, so a count after it reads as the search of `.` does.
    @Test
    func aFlagClusterWithACountIsStillRecursive() {
        for cluster in ["-rnA3", "-rnC2", "-Rn5", "-rm1"] {
            #expect(ShellInspection.isSwiftLookup("grep \(cluster) UsageLog") { $0 == "." })
            #expect(ShellInspection.isSwiftLookup("grep \(cluster) UsageLog .") { $0 == "." })
        }
        // The `r` after a letter that takes a value is that value, and the search reads its standard input.
        #expect(!ShellInspection.isSwiftLookup("grep -nm1r UsageLog") { $0 == "." })
    }

    /// A language filter names Swift without naming a file, and needs no filesystem to see.
    @Test
    func aSwiftTypeFilterIsEnoughOnItsOwn() {
        #expect(ShellInspection.isSwiftLookup("rg -t swift UsageLog Sources/"))
        #expect(ShellInspection.isSwiftLookup("grep -rn --include=*.swift UsageLog Sources/"))
        #expect(!ShellInspection.isSwiftLookup("rg -t md UsageLog Docs/"))
    }

    /// The identifier gate on the unmarked case, which is what stops a whole-repo text search being called a miss the index could have served.
    @Test
    func aTreeSweepForSomethingThatIsNotASymbolIsNotALookup() {
        #expect(!ShellInspection.isSwiftLookup(#"grep -rn "revisit this later" Sources/"#) { _ in true })
        // A `cat` of a directory is not a thing anyone types, and resolving one would be pure cost.
        #expect(!ShellInspection.isSwiftLookup("cat Sources/") { _ in true })
        #expect(ShellInspection.isSwiftLookup("rg QueueSubscriber Sources/") { _ in true })
    }

    /// Reading this tool's own state is not a lookup of Swift source, and `.swift` has to be a whole extension, not the head of a longer one.
    ///
    /// The usage log, the roots registry and the advice ledger under `~/.sift/` name no Swift file, and a build product such as `.swiftmodule` or `.swiftinterface` only begins like one; classifying either as a lookup would spend a nudge — and the mechanism's credibility — before it meets a real one. A `.swift` path reached through `~/.sift/` still reads as the lookup it is.
    @Test
    func theToolsOwnStateDirectoryIsNotSwiftSource() {
        #expect(!ShellInspection.isSwiftLookup("cat ~/.sift/usage.jsonl"))
        #expect(!ShellInspection.isSwiftLookup("cat ~/.sift/roots.json"))
        #expect(!ShellInspection.isSwiftLookup("head -c 900 ~/.sift/advice/session.json"))
        #expect(!ShellInspection.isSwiftLookup("ls -la ~/.sift/advice && cat ~/.sift/roots.json"))
        // Build products are not source either.
        #expect(!ShellInspection.isSwiftLookup("cat .build/Modules/SiftCore.swiftmodule"))
        #expect(!ShellInspection.isSwiftLookup("cat Foo.swiftinterface"))
        // The real thing still reads as one.
        #expect(ShellInspection.isSwiftLookup("cat Sources/SiftCore/RootResolver.swift"))
        #expect(ShellInspection.isSwiftLookup("grep -n Depot ~/.sift/../Sources/Lib.swift"))
    }

    /// A substitution is one value, not a place where a new command starts.
    ///
    /// A `|` inside `$( … )` or backticks belongs to the substitution, so `cat ~/.cache/swift-advice/$(ls -t ~/.cache/swift-advice | head -1)` is one segment reading one `.json` file, and neither it nor the backtick form reads as a Swift lookup. Split inside the substitution instead, `-t` and the path after it would land among `cat`'s arguments and read as ripgrep's `-t swift` — which is why the directory spells "swift": a path that did not would pass either way. A substitution that genuinely reads Swift source still counts.
    @Test
    func aCommandSubstitutionStaysInsideItsSegment() {
        #expect(!ShellInspection.isSwiftLookup("cat ~/.cache/swift-advice/$(ls -t ~/.cache/swift-advice | head -1)"))
        #expect(!ShellInspection.isSwiftLookup("cat `ls -t ~/.cache/swift-advice`"))
        // A substitution that genuinely reads Swift source still counts.
        #expect(ShellInspection.isSwiftLookup("echo $(grep -c Depot Sources/Foo.swift)"))
    }

    /// The write side reads `.swift` the same way, so a redirect into the state directory is not "writing Swift" either.
    @Test
    func aRedirectIntoTheStateDirectoryIsNotAWriteOfSwiftSource() {
        // Not a write of source — and since nothing here reads source, not a lookup either.
        #expect(!ShellInspection.isSwiftLookup("echo x > ~/.sift/roots.json"))
        // A genuine redirect into a Swift file is still a write, so still not a lookup.
        #expect(!ShellInspection.isSwiftLookup("cat Template.swift > Generated.swift"))
    }

    /// What is searched decides, never what the pattern mentions.
    ///
    /// A `.swift` inside a pattern is text being hunted for — a test's file name through a build log, a path through a document — and a log, a document or a pipe is not Swift source whatever is being looked for in it. A verb that takes no pattern is the other side of the same rule: every word `cat` is handed is a file.
    @Test
    func aSwiftNameInThePatternIsNotAFileBeingRead() {
        #expect(!ShellInspection.isSwiftLookup(#"grep -n "CommentHistoryTests.swift:3[0-9]…" file.log"#))
        #expect(!ShellInspection.isSwiftLookup(#"grep -n "CommentHistoryTests.swift:3[0-9]\|failed" file.log"#))
        #expect(!ShellInspection.isSwiftLookup("tail -200 build.log | grep CommentHistoryTests.swift"))
        #expect(!ShellInspection.isSwiftLookup(#"rg "Sources/App/View.swift" Docs/Notes.md"#))
        #expect(!ShellInspection.isSwiftLookup("grep -n CommentHistoryTests.swift file.log"))
        // The same verbs pointed at Swift source still are, whatever the pattern says.
        #expect(ShellInspection.isSwiftLookup("grep -n foo Sources/X.swift"))
        #expect(ShellInspection.isSwiftLookup(#"grep -n "View.swift" Sources/App/View.swift"#))
        #expect(ShellInspection.isSwiftLookup("grep -rn MyType Sources/") { $0 == "Sources/" })
        #expect(ShellInspection.isSwiftLookup("cat Sources/App/View.swift README.md"))
        #expect(ShellInspection.isSwiftLookup("cat README.md Sources/App/View.swift"))
    }

    /// A glob naming Swift restricts a command to Swift source across every file it matches, so it is a sweep and never one file — not even for a window, whose whole meaning is a range of one file's lines.
    @Test
    func aSwiftGlobIsASweepNotOneFile() {
        #expect(ShellInspection.isSwiftLookup("git grep -n -i \"…\" -- '*.md' '*.swift'"))
        #expect(ShellInspection.isSwiftLookup("head -50 Sources/App/*.swift"))
        #expect(ShellInspection.windowedReadPath("head -50 Sources/App/*.swift", in: nil) == nil)
        #expect(ShellInspection.windowedReadPath("head -50 Sources/App/View.swift", in: nil) == "Sources/App/View.swift")
    }

    /// An escaped `;`, `|` or `&` is an argument, not a separator, so the command it sits in stays one command.
    ///
    /// `find … -exec grep … {} \;` ends its `-exec` with a literal `;`, and is judged as its `xargs` twin is: the files reach the grep from `find`, so its own operands name no Swift source and neither spelling is a lookup. An escaped `|` in an unquoted pattern keeps the file after it in the grep's command, where it is read.
    @Test
    func anEscapedSeparatorDoesNotSplitTheCommand() {
        let exec = #"find Sources -name '*.swift' -exec grep -n foo {} \;"#
        let holdsSource: (String) -> Bool = { $0 == "Sources" }

        #expect(ShellSyntax.segments(of: exec) == [exec])
        #expect(ShellSyntax.statements(of: exec) == [exec])
        #expect(!ShellInspection.isSwiftLookup(exec, holdsSource: holdsSource))
        #expect(!ShellInspection.isSwiftLookup("find Sources -name '*.swift' | xargs grep -n foo", holdsSource: holdsSource))
        #expect(ShellInspection.isSwiftLookup(#"grep -n slateDim\|slate Sources/App/Theme.swift"#))
        #expect(ShellInspection.isSwiftLookup(#"grep -n rows\&columns Sources/App/Theme.swift"#))
        // Single quotes have no escapes: the backslash is literal there and the quote still closes.
        #expect(ShellSyntax.tokens(of: #"grep 'a\' Sources/App/Theme.swift"#) == [#"grep"#, #"a\"#, "Sources/App/Theme.swift"])
    }

    /// An unquoted `)` ends a word, and a quoted or escaped one is part of it.
    ///
    /// A subshell closes against its last argument, so read as part of the word, the file in `(grep -n foo View.swift)` is `View.swift)`, which names no Swift file. A pattern that spells a parenthesis inside quotes is still that pattern.
    @Test
    func aClosingParenthesisEndsAWordOnlyOutsideQuotes() {
        #expect(ShellSyntax.tokens(of: "(grep -n foo Sources/App/View.swift)") == ["(grep", "-n", "foo", "Sources/App/View.swift"])
        #expect(ShellQuery("(grep -n 'run()' Sources/App/View.swift)").pattern == "run()")
        #expect(ShellQuery(#"(grep -n "a)b" Sources/App/View.swift)"#).pattern == "a)b")
        #expect(ShellQuery(#"(grep -n a\)b Sources/App/View.swift)"#).pattern == #"a\)b"#)
        #expect(ShellQuery("(grep -n 'run()' Sources/App/View.swift)").swiftFiles == ["Sources/App/View.swift"])
        // A substitution stays one word to the command around it.
        #expect(ShellSyntax.tokens(of: "cat $(ls -t | head -1)") == ["cat", "$(ls -t | head -1)"])
    }

    /// A command substitution is a command of its own, and is read as statements ahead of the statement holding it — never inside single quotes or behind a backslash, where `$(` is text.
    @Test
    func aCommandSubstitutionIsReadAsStatementsAheadOfItsHost() {
        #expect(ShellSyntax.executedStatements(of: #"echo "$(cd Kit; grep -n foo X.swift)" done"#)
            == ["cd Kit", " grep -n foo X.swift", #"echo "$(cd Kit; grep -n foo X.swift)" done"#])
        #expect(ShellSyntax.executedStatements(of: "echo `head -3 X.swift`") == ["head -3 X.swift", "echo `head -3 X.swift`"])
        #expect(ShellSyntax.executedStatements(of: "echo $(cat $(ls X.swift))") == ["ls X.swift", "cat $(ls X.swift)", "echo $(cat $(ls X.swift))"])
        #expect(ShellSyntax.executedStatements(of: #"grep -n "a)b" $(ls X.swift)"#) == ["ls X.swift", #"grep -n "a)b" $(ls X.swift)"#])
        #expect(ShellSyntax.executedStatements(of: "echo '$(grep -n foo X.swift)'") == ["echo '$(grep -n foo X.swift)'"])
        #expect(ShellSyntax.executedStatements(of: #"echo \$(grep -n foo X.swift)"#) == [#"echo \$(grep -n foo X.swift)"#])
        #expect(ShellSyntax.executedStatements(of: "echo $((1 + 2))") == ["echo $((1 + 2))"])
    }

    /// An escaped `$` is a literal dollar sign, so the `(` after it opens no substitution: the splitter does not hold a separator after it as though inside one, and a verb after it is quoted text rather than something the shell runs.
    @Test
    func anEscapedDollarOpensNoSubstitution() {
        #expect(ShellSyntax.statements(of: #"echo \$(date; grep -n foo X.swift)"#) == [#"echo \$(date"#, " grep -n foo X.swift)"])
        #expect(ShellSyntax.segments(of: #"echo \$(date | grep -n foo X.swift)"#) == [#"echo \$(date "#, " grep -n foo X.swift)"])
        #expect(!ShellSyntax.executableText(of: #"echo "\$(grep -n foo X.swift)""#).contains("grep"))
        #expect(!ShellQuery(#"echo "\$(grep -n foo X.swift)""#).reads)
        // An escaped backslash leaves the dollar after it real.
        #expect(ShellSyntax.executableText(of: #"echo "\\$(grep -n foo X.swift)""#).contains("$(grep -n foo X.swift)"))
        #expect(ShellSyntax.statements(of: #"echo \\$(date; grep -n foo X.swift)"#) == [#"echo \\$(date; grep -n foo X.swift)"#])
    }

    /// For choosing the lookup a command makes, every statement outside a substitution comes ahead of every one inside, so a window in a body names the command only where nothing around it reads Swift.
    @Test
    func aSubstitutionsWindowIsTheLookupOnlyWhereItsHostReadsNoSwift() {
        let sweep = #"grep -rn Name --include='*.swift' Sources --exclude="$(head -1 Sources/App/Names.swift)""#

        #expect(ShellSyntax.hostStatementsFirst(of: #"echo "$(cd Kit; grep -n foo X.swift)"; ls"#)
            == [#"echo "$(cd Kit; grep -n foo X.swift)""#, " ls", "cd Kit", " grep -n foo X.swift"])
        #expect(ShellInspection.windowedReadPath(sweep, in: nil) == nil)
        #expect(ShellInspection.isSwiftLookup(sweep))
        #expect(ShellInspection.windowedReadPath("echo `head -1 Sources/App/Names.swift`", in: nil) == "Sources/App/Names.swift")
    }

    /// An `awk` program that picks its lines by number is a window, as `sed -n '486,493p'` is, and is advised as the read of its file.
    ///
    /// One that matches text still searches.
    @Test
    func anAwkProgramPickingLinesByNumberIsAWindow() {
        let window = #"awk 'NR==486,NR==493{print NR": "length($0)" chars"}' Sources/App/Alpha.swift"#

        #expect(ShellInspection.windowedReadPath(window, in: nil) == "Sources/App/Alpha.swift")
        #expect(ShellAdvice.suggestion(for: window, holdsSource: nil)?.call == "digest Alpha")
        #expect(ShellInspection.windowedReadPath("awk 'NR>=10 && NR<=20' Sources/App/Alpha.swift", in: nil) != nil)
        #expect(ShellInspection.windowedReadPath("awk '/func go/' Sources/App/Alpha.swift", in: nil) == nil)
        #expect(ShellAdvice.suggestion(for: "awk '/func go/' Sources/App/Alpha.swift", holdsSource: nil) != nil)
    }

    /// A `sed` spelled with `-n` still edits where it also carries `-i`, or a script that is more than a print range, and neither is a window.
    @Test
    func aSedThatEditsIsNotAWindowEvenSpelledWithN() {
        #expect(ShellInspection.windowedReadPath("sed -n '1,30p' -i Sources/App/Alpha.swift", in: nil) == nil)
        #expect(ShellInspection.windowedReadPath("sed -n -e '1,30p' -e 's/x/y/w out' Sources/App/Alpha.swift", in: nil) == nil)
    }

    /// A `sed` range opening on line 0 names no line, so no script holding one is a window, however the script is handed over.
    @Test(arguments: ["0p", "00p", "0,5p", "0,+2p", "0,$p", "5,3p;0p", "1,5p;0p"])
    func aSedRangeOpeningOnLineZeroIsNotAWindow(script: String) {
        #expect(ShellInspection.windowedReadPath("sed -n '\(script)' Sources/App/Alpha.swift", in: nil) == nil)
        #expect(ShellInspection.windowedReadPath("sed -n -e '\(script)' Sources/App/Alpha.swift", in: nil) == nil)
        #expect(ShellInspection.windowedReadPath("sed -n '5p' Sources/App/Alpha.swift", in: nil) == "Sources/App/Alpha.swift")
        #expect(ShellInspection.windowedReadPath("sed -n '05p' Sources/App/Alpha.swift", in: nil) == "Sources/App/Alpha.swift")
    }

    /// What `/usr/bin/sed` does with a range opening on line 0, recorded because the refusal above rests on it: the range prints nothing and the run still exits 0.
    @Test
    func theSystemSedPrintsNothingForARangeOpeningOnLineZero() throws {
        let text = (1 ... 8).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let silent = try ["0p", "00p", "0,5p", "0,+2p", "0,$p"].filter { script in
            let run = try Self.systemSed(script, text)
            return run.status == 0 && run.output.isEmpty
        }
        let mixed = try Self.systemSed("5,3p;0p", text)

        #expect(silent == ["0p", "00p", "0,5p", "0,+2p", "0,$p"])
        #expect(mixed.status == 0 && mixed.output == "line 5\n")
    }

    /// What `/usr/bin/sed -n` prints for `script` over `text` handed on its standard input, and its exit status.
    private static func systemSed(_ script: String, _ text: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sed")
        process.arguments = ["-n", script]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
    }

    /// The host-first order holds at every depth: a body's own statements come ahead of the bodies nested in it, so a window two or three substitutions down never names a command whose enclosing body sweeps.
    @Test
    func aBodysOwnStatementsComeAheadOfTheBodiesNestedInIt() {
        let sweep = #"grep -rn Name --include='*.swift' Sources --exclude="$(head -1 Sources/App/Names.swift)""#
        let twoLevels = "echo \"$(\(sweep))\""
        let threeLevels = "echo \"$(echo \"$(\(sweep))\")\""

        #expect(ShellSyntax.hostStatementsFirst(of: twoLevels) == [twoLevels, sweep, "head -1 Sources/App/Names.swift"])
        #expect(ShellSyntax.hostStatementsFirst(of: threeLevels)
            == [threeLevels, "echo \"$(\(sweep))\"", sweep, "head -1 Sources/App/Names.swift"])
        #expect(ShellInspection.windowedReadPath(twoLevels, in: nil) == nil)
        #expect(ShellInspection.windowedReadPath(threeLevels, in: nil) == nil)
        #expect(ShellInspection.isSwiftLookup(threeLevels))
    }

    /// A substitution spelled where it does not run — in single quotes, or behind a backslash — is characters, so a verb beside it is still only a printer's argument; one that runs is read from its body.
    @Test
    func aSubstitutionThatDoesNotRunReadsNothing() {
        #expect(!ShellInspection.isSwiftLookup("echo grep '$(grep -n foo X.swift)'"))
        #expect(!ShellInspection.isSwiftLookup(#"echo grep "\$(grep -n foo X.swift)""#))
        #expect(!ShellInspection.isSwiftLookup("echo cat '`cat X.swift`'"))
        #expect(ShellInspection.isSwiftLookup(#"echo "$(grep -n foo X.swift)""#))
        #expect(ShellInspection.isSwiftLookup("echo grep $(grep -n foo X.swift)"))
        #expect(ShellInspection.isSwiftLookup("echo cat `cat X.swift`"))
    }

    /// A backslash escapes one character and no more: `\\;` is an escaped backslash followed by a real separator.
    ///
    /// Treated as one escape, the pair would hide the `;` and fuse two commands; treated as two, the second backslash would swallow the separator. Either misreading hands a command's arguments to its neighbour.
    @Test
    func anEscapedBackslashLeavesTheSeparatorAfterItReal() {
        #expect(ShellSyntax.segments(of: #"echo a\\; grep -n foo Sources/App/X.swift"#) == [#"echo a\\"#, " grep -n foo Sources/App/X.swift"])
        #expect(ShellSyntax.statements(of: #"echo a\\; ls"#) == [#"echo a\\"#, " ls"])
        #expect(ShellSyntax.segments(of: #"echo a\\\; ls"#) == [#"echo a\\\; ls"#])
    }

    /// A `||` runs the next command only where the last one failed, and hands it nothing the last one printed: it separates statements, as `&&` does, and is no pipe.
    ///
    /// Read as two pipes, the `true` after a read became a stage filtering what the read printed, and the read was withheld as filtered output rather than answered.
    @Test
    func anOrSeparatesStatementsAndPipesNothing() {
        #expect(ShellSyntax.statements(of: "grep -n Alpha Sources/App/Alpha.swift||true") == ["grep -n Alpha Sources/App/Alpha.swift", "true"])
        #expect(ShellSyntax.statements(of: "grep -n 'a||b' X.swift | sort||true") == ["grep -n 'a||b' X.swift | sort", "true"])
        #expect(ShellSyntax.statements(of: #"echo a\||wc"#) == [#"echo a\||wc"#])
        #expect(ShellAdvice.textSearchReason("grep -n Alpha Sources/App/Alpha.swift || true", holdsSource: nil) == nil)
    }

    /// A verb is an invocation unless the command running it only prints its words.
    ///
    /// `echo` handed the words `grep -n foo X.swift` prints them, escaped quotes or none, and opens nothing. Every other command in front runs what follows or may, so a wrapper nobody listed — `watch`, `ionice`, `caffeinate`, `unbuffer`, `sudo -n` — keeps the lookup it wraps rather than taking it out of the share.
    @Test
    func aVerbIsAnInvocationUnlessThePrinterRunsIt() {
        #expect(!ShellInspection.isSwiftLookup(#"echo \" grep -n foo Sources/App/X.swift \""#))
        #expect(!ShellInspection.isSwiftLookup("echo grep -n foo Sources/App/X.swift"))
        #expect(!ShellInspection.isSwiftLookup("printf '%s' grep -n foo Sources/App/X.swift"))
        #expect(ShellAdvice.suggestion(for: #"echo \" grep -n foo Sources/App/X.swift \""#) == nil)

        for wrapped in ["watch -n 2", "ionice -c3", "caffeinate", "unbuffer", "sudo -n"] {
            let command = "\(wrapped) grep -rn UsageWindow Sources --include=*.swift"
            #expect(ShellInspection.isSwiftLookup(command), "\(command)")
            #expect(ShellAdvice.suggestion(for: command)?.call == "where UsageWindow", "\(command)")
        }

        #expect(ShellInspection.isSwiftLookup("xargs grep -n foo Sources/App/X.swift"))
        #expect(ShellInspection.isSwiftLookup("xargs -I {} grep -n foo Sources/App/X.swift"))
        #expect(ShellInspection.isSwiftLookup("sudo -u dev grep -n foo Sources/App/X.swift"))
        #expect(ShellInspection.isSwiftLookup("LC_ALL=C timeout 5s grep -n foo Sources/App/X.swift"))
        #expect(ShellInspection.isSwiftLookup("git -C repo grep -n foo -- Sources/App/X.swift"))
        #expect(ShellInspection.isSwiftLookup("for f in a b; do grep -n foo Sources/App/X.swift; done"))
        #expect(ShellInspection.isSwiftLookup("if grep -q foo Sources/App/X.swift; then echo yes; fi"))
        #expect(ShellInspection.isSwiftLookup(#"echo "$(grep -n func Thing.swift)""#))
    }

    /// A heredoc's body is text on a command's standard input, not commands — in every spelling of the operator — and the line after its terminator is a command again.
    @Test
    func aHeredocsBodyIsNotACommand() {
        let bodies = [
            "cat > check.sh <<'EOF'\ngrep -rn \"TODO\" Sources --include=*.swift\nEOF",
            "cat > check.sh <<EOF\ngrep -rn UsageWindow Sources --include=*.swift\nEOF",
            "cat > check.sh <<\"EOF\"\ngrep -rn UsageWindow Sources --include=*.swift\nEOF",
            "cat > check.sh <<-EOF\n\tgrep -rn UsageWindow Sources --include=*.swift\n\tEOF",
            "cat > check.sh <<EOF\ngrep -rn UsageWindow Sources --include=*.swift",
        ]
        let after = "cat > check.sh <<'EOF'\necho written\nEOF\ngrep -rn UsageWindow Sources --include=*.swift"

        for body in bodies {
            #expect(!ShellInspection.isSwiftLookup(body), "\(body)")
            #expect(ShellAdvice.suggestion(for: body) == nil, "\(body)")
        }

        #expect(ShellAdvice.suggestion(for: after)?.call == "where UsageWindow")
        // A here-string is one word, so what follows it on the next line is still a command.
        #expect(ShellInspection.isSwiftLookup("grep Depot <<< \"x\"\ngrep -n foo Sources/App/X.swift"))
        // And a `<<` inside arithmetic is a shift, which opens no body either.
        #expect(ShellAdvice.suggestion(for: "echo $((1<<3))\ngrep -rn UsageWindow Sources --include=*.swift")?.call == "where UsageWindow")
        #expect(ShellAdvice.suggestion(for: "((flags <<= 2))\ngrep -rn UsageWindow Sources --include=*.swift")?.call == "where UsageWindow")
    }

    /// A heredoc feeds the verb inline text, so prose *about* source is not a lookup of it.
    ///
    /// A commit message describing a `grep` of a `.swift` file would otherwise classify as that grep. Quoted text is safe by other means — segmenting strips quotes, and a quoted command is not an invocation — but a heredoc body is not quoted, so nothing else protects it.
    @Test
    func aHeredocBodyIsTextNotAFileBeingRead() {
        #expect(!ShellInspection.isSwiftLookup("git commit -m \"$(cat <<'EOF'\nreplaced grep -n x Foo.swift with a digest\nEOF\n)\""))
        #expect(!ShellInspection.isSwiftLookup("cat <<'EOF' > /tmp/note.txt\nsee Sources/Foo.swift\nEOF"))
        // A here-string is the same idea in one line.
        #expect(!ShellInspection.isSwiftLookup("grep Depot <<< \"struct Depot {} // Foo.swift\""))
        // An actual read of the same file is untouched.
        #expect(ShellInspection.isSwiftLookup("grep -n Depot Sources/Foo.swift"))
    }

    /// A quote in one heredoc's body is prose, so it leaves the next heredoc a body too.
    ///
    /// A command filing issues wrote three bodies with `cat > i1.md <<'EOF'` and was refused: an apostrophe in the first body opened a quote that ran on into the text after it, so the second `<<` read as quoted and opened nothing, and the third body's `sed -n '/X/p' F.swift` was judged as a command. The shell reads no quotes inside a body, and neither may the scan that finds the operators after it.
    @Test
    func aQuoteInOneHeredocsBodyLeavesTheNextOneABody() {
        let lookup = "sed -n '/UsageWindow/p' Sources/App/X.swift | sort -u"
        let openers = ["it's", "a \"quoted", "a `ticked"]
        for opener in openers {
            let command = "cat > a.md <<'EOF'\n\(opener) line\nEOF\ngh issue create --body-file a.md\ncat > b.md <<'EOF'\n\(lookup)\nEOF\ngh issue create --body-file b.md"
            #expect(!ShellInspection.isSwiftLookup(command), "\(command)")
            #expect(ShellAdvice.suggestion(for: command) == nil, "\(command)")
            // The line after the last terminator is a command again.
            let after = command + "\ngrep -rn UsageWindow Sources --include=*.swift"
            #expect(ShellAdvice.suggestion(for: after)?.call == "where UsageWindow", "\(after)")
        }
        // The same text passed as one quoted argument was never a command either.
        #expect(!ShellInspection.isSwiftLookup("gh issue create --body \"\(lookup)\""))
        #expect(ShellAdvice.suggestion(for: "gh issue create --body \"grep -n UsageWindow Sources/App/X.swift\"") == nil)
        // A body with no terminator runs to the end, so nothing after its opener is judged: the safe direction.
        #expect(ShellAdvice.suggestion(for: "cat > a.md <<'EOF'\nit's\n\(lookup)\ngrep -rn UsageWindow Sources --include=*.swift") == nil)
    }

    /// A quoted empty argument is still a token, so `arguments` and `rawArguments` never drift apart in length — a cut at a later redirection lands on the same position in both.
    ///
    /// Stripping the quotes off `""` leaves nothing, and a splitter that drops a piece whenever what survives is empty loses the argument entirely — cutting `where A "" 2>&1` to `[where, A, 2>&1]` instead of keeping the empty argument before the redirection.
    @Test
    func aQuotedEmptyArgumentIsKeptAsAnEmptyToken() {
        let query = ShellQuery(#"where A "" 2>&1"#)

        #expect(query.arguments == ["where", "A", "", "2>&1"])
        #expect(query.rawArguments == [#"where"#, #"A"#, #""""#, "2>&1"])
        #expect(query.arguments.count == query.rawArguments.count)
    }
}
