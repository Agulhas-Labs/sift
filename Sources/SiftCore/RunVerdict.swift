//
// Copyright © Agulhas Labs
//

import Foundation

/// How a run ended, read from the line the toolchain prints to say so and checked against the line the invoked command owed.
///
/// Everything else in a build log describes something that happened *during* the run — a warning, a diagnostic, a test's own counts — and only this line says the run reached its end at all. So `sift run` answers with one of these or says out loud that it found none: the failure this whole path exists to prevent is a cheerful green over a log that was cut off mid-suite, and that is not a hypothetical — a truncated capture whose only surviving line is `Executed 0 tests` reads as `✔ xcodebuild` to anything that does not look for this line, over four thousand lines of a run that never finished.
///
/// It is read **against the invoked action**, never by scanning for whichever literal turns up. `xcodebuild build-for-testing` closes with `** TEST BUILD SUCCEEDED **`, so a log for that command carrying `** BUILD SUCCEEDED **` instead is an earlier phase's verdict standing where the one that was owed never came — reported as the anomaly it is rather than accepted as a pass.
public struct RunVerdict: Sendable, Equatable {
    public let state: State
    /// The line the tool printed to declare it, or `nil` where the tool declares this state by printing nothing — `swift build` announces failure only as the errors it emitted.
    public let line: String?
    /// The line the invoked command owed for this state, when its action is one the contract knows; `nil` leaves nothing to disagree with.
    public let owed: String?
    /// Whether this verdict was read from the wrapped command's exit code rather than from a line the log printed — `xcodebuild -quiet` suppresses the banner a `.declares` contract owes, so a clean exit with nothing this filter reads as a failure is read as success from the exit code alone.
    ///
    /// Only ever `true` for an invocation ``Contract/isQuietXcodebuild(_:)`` accepts: every other command prints its closing line when it finishes, so its silence is a log that stopped early.
    ///
    /// Kept apart from `line` being `nil` because that is already true of an ordinary `swift build` failure, which prints no closing line of its own and is not inferred from anything — `false` there, `true` only for the exit-code reading. The renderer words the two differently (Docs/AnswerContract.md §8): a claim read off a line the tool actually printed and a claim read off its exit code are different strengths of evidence, and the headline says which this is.
    public let inferredFromExitCode: Bool

    public init(state: State, line: String?, owed: String?, inferredFromExitCode: Bool = false) {
        self.state = state
        self.line = line
        self.owed = owed
        self.inferredFromExitCode = inferredFromExitCode
    }
}

public extension RunVerdict {
    /// Whether the run ended well, badly, or not at all.
    ///
    /// Three states rather than two, because `** BUILD INTERRUPTED **` is neither: the run was killed before it could judge itself, so calling it a failure blames the code for what the machine did and calling it a pass is the lie this type exists to prevent. The trap is real rather than theoretical — the interrupted capture's own suite line reads `failed`, so a two-state reader gets it wrong twice over.
    enum State: Sendable, Equatable {
        case succeeded
        case failed
        case interrupted
    }

    /// Whether the verdict in the log is the one the invoked command owed.
    ///
    /// A prefix rather than an equality, because `swift build` stamps its own duration into the line it owes (`Build complete! (0.36s)`) while `xcodebuild`'s is fixed; the part that identifies the action is the part in front either way.
    var answersTheInvokedCommand: Bool {
        guard let owed, let line else {
            return true
        }
        return line.hasPrefix(owed)
    }

    /// The lines SwiftPM closes a failed build on: `error: Build failed` from its own build system, `error: fatalError` from the older one, and both, in that order, where a link failed under Swift 6.4.
    ///
    /// Whole lines, compared after trimming: a compiler error's message that quotes either sentence is no closing line.
    static let buildFailureLines: Set<String> = ["error: Build failed", "error: fatalError"]

    /// The state `line` declares, or `nil` when the line is not a verdict at all.
    ///
    /// Read off the last word rather than the first, because the action changes the wording in front of it — `** TEST EXECUTE FAILED **`, `** TEST BUILD FAILED **`, `** BUILD FAILED **` — and the state is the one part every action spells the same way.
    static func state(of line: String) -> State? {
        if line.hasSuffix(" INTERRUPTED **") {
            .interrupted
        } else if line.hasSuffix(" SUCCEEDED **") {
            .succeeded
        } else if line.hasSuffix(" FAILED **") {
            .failed
        } else if line.hasPrefix("Build complete!") {
            .succeeded
        } else if buildFailureLines.contains(line) {
            .failed
        } else {
            nil
        }
    }
}

// MARK: - What the invocation owes

public extension RunVerdict {
    /// What an invocation commits to printing when it ends — the only thing that makes an absent verdict recognisable as absent.
    ///
    /// Read from argv and never from the output, for the reason `RunCommandKind` gives for reading argv: a contract inferred from what the log happens to contain can only ever agree with it, and agreeing with a truncated log is exactly the failure.
    enum Contract: Sendable, Equatable {
        /// A command that stamps its own closing line — every `xcodebuild` action, and `swift build`, whose failure carries no literal because the errors are the announcement.
        case declares(succeeded: String, failed: String?)
        /// `swift test`, which prints no closing line of its own: its Swift Testing run tally is the only thing in the output that says the run reached its end.
        case runTally
        /// A linter (``RunCommandKind/linter``), which prints one diagnostic per line and no closing verdict of its own at all — not even the silent-on-success shape `-quiet` gives `xcodebuild`.
        ///
        /// Its verdict is read from the exit code alone, always: a clean exit is a pass and anything else a failure, with no line in the log to disagree with.
        case diagnostics
        /// A command this reader knows by name but whose action it could not read out of argv, so nothing in the log may stand as this run's verdict.
        ///
        /// Distinct from *no contract at all*, and the distinction is the whole point. A command nobody modelled is never filtered, so its unread contract costs nothing; an `xcodebuild` whose action went unread **is** filtered, and answering it with no contract left `RunVerdict.state(of:)` free to accept whichever `** … **` literal turned up — a `** CLEAN SUCCEEDED **` reported as the whole run's pass, which is exactly the "scan for whichever literal happens to appear" the seventh rule forbids. Refusing is the only safe reading: an action this table cannot name is one whose owed wording is unknown, and an unknown expectation cannot be checked against anything.
        case unreadable
    }
}

public extension RunVerdict.Contract {
    /// The line this command owes when it ends in `state`, or `nil` when the state is one no action words for itself.
    func line(for state: RunVerdict.State) -> String? {
        switch self {
        case let .declares(succeeded, failed):
            // An interruption is stamped in the build phase's voice whatever `xcodebuild` was doing — the
            // captured `test-without-building` run that was killed mid-suite closes with
            // `** BUILD INTERRUPTED **` — so no action owes a wording here and there is nothing to disagree with.
            switch state {
            case .succeeded: succeeded
            case .failed: failed
            case .interrupted: nil
            }
        case .runTally, .unreadable, .diagnostics:
            nil
        }
    }

    /// What `arguments` commits its command to printing, or `nil` when the command is not one this tool wraps at all.
    ///
    /// The kind is asked of ``RunCommandKind/recognize(_:linters:)`` rather than read out of argv a second time. Both readings would answer the same question — which command is this — off the same array, and two copies of one rule are two places for it to drift; the launcher already chooses the filter from the first, so the contract hangs off exactly the reading that decided a filter would run at all. That is also why `linters` is carried this far: one reading of the same rule means the same inputs, and the configured names are one of them.
    static func of(_ arguments: [String], linters: Set<String> = []) -> RunVerdict.Contract? {
        switch RunCommandKind.recognize(arguments, linters: linters) {
        case .swiftBuild: .declares(succeeded: "Build complete!", failed: nil)
        case .swiftTest: .runTally
        case .xcodebuild: xcodebuild(arguments)
        case .linter: .diagnostics
        case .unrecognized: nil
        }
    }

    /// The verdict wording each `xcodebuild` action stamps on its own result.
    ///
    /// A table rather than a transformation because there is no transformation to write: `build-for-testing` prints `** TEST BUILD …`, `test-without-building` prints `** TEST EXECUTE …`, and `docbuild` prints `** BUILD DOCUMENTATION …` — none of the three is derivable from the action word that produced it, and the last is the one that settles the argument, since every plausible guess at it would have been `DOCBUILD`.
    ///
    /// **Every row was read off `xcodebuild` itself**, run twice over a throwaway package — once compiling and once with a type error in it — so both wordings are measured rather than inferred from the other. The actions are the ten the manual page lists; the one missing from the table is `installsrc`, which was measured to print **no closing line at all** and so belongs with the shapes ``actionsWithNoWording`` refuses.
    private static var stems: [String: String] {
        [
            "build": "BUILD",
            "build-for-testing": "TEST BUILD",
            "test": "TEST",
            "test-without-building": "TEST EXECUTE",
            "clean": "CLEAN",
            "analyze": "ANALYZE",
            "archive": "ARCHIVE",
            "install": "INSTALL",
            "docbuild": "BUILD DOCUMENTATION",
        ]
    }

    /// `xcodebuild` options that take no value of their own, so the word behind one is the invocation's own next argument.
    ///
    /// **The direction of the table is the safety property.** Listing the *valueless* flags means an option this list has never heard of is assumed to take a value, so the word behind it is skipped and an unread action ends as ``unreadable`` — loud, and never a verdict read off the wrong action. Listing the value-taking ones instead would make an unknown flag valueless, and then `-someNewFlag test` would have this command owe `** TEST SUCCEEDED **` on the strength of a scheme name.
    ///
    /// Read from `xcodebuild -help`'s own option list on Xcode 26.6 rather than assembled from memory. It will age, and aging costs a `⚠` on an invocation that could have been read — which is the failure this whole path is built to prefer.
    private static let valuelessFlags: Set<String> = [
        "-verbose", "-quiet", "-json", "-alltargets", "-parallelizeTargets", "-hideShellScriptEnvironment",
        "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "-showBuildTimingSummary",
        "-skipUnavailableActions", "-skipMacroValidation", "-skipPackagePluginValidation",
        "-skipPackageSignatureValidation", "-skipPackageUpdates", "-disablePackageRepositoryCache",
        "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
        "-retry-tests-on-failure", "-run-tests-until-failure", "-enumerate-tests",
    ]

    /// `xcodebuild` options observed to take a value, kept for ``standsAlone(in:)`` alone — the other readers here take the opposite direction on an option neither table names, so listing the value-taking ones for them would make an unrecognised flag swallow the word behind it instead of leaving it be.
    ///
    /// Not exhaustive over `-help`'s option list the way ``valuelessFlags`` tries to be: only the flags a pass-through was observed to carry legitimately, so a value-taking option this list has never heard of still gets the safe reading ``standsAlone(in:)`` gives it — treated as if it took no value, so the word behind it is checked rather than assumed to be somebody's value.
    ///
    /// Read from `xcodebuild -help`'s own option list on Xcode 27.0.
    private static let valueTakingFlags: Set<String> = [
        "-configuration", "-derivedDataPath", "-destination", "-scheme", "-project", "-workspace",
        "-testPlan", "-xctestrun", "-resultBundlePath", "-parallel-testing-enabled", "-collect-test-diagnostics",
        "-sdk", "-arch", "-toolchain", "-xcconfig", "-resultStreamPath", "-archivePath",
        "-clonedSourcePackagesDirPath", "-target", "-only-test-configuration", "-test-iterations",
        "-platform", "-osVersion", "-modelCode", "-architecture", "-downloadPlatform", "-importPlatform",
        "-downloadComponent", "-importComponent", "-deleteComponent", "-showComponent",
        "-destination-timeout", "-jobs", "-maximum-concurrent-test-device-destinations",
        "-maximum-concurrent-test-simulator-destinations", "-parallel-testing-worker-count",
        "-maximum-parallel-testing-workers", "-convert-project", "-find-executable", "-find-library",
        "-enableAddressSanitizer", "-enableThreadSanitizer", "-enableUndefinedBehaviorSanitizer",
        "-resultBundleVersion", "-exportOptionsPlist", "-enableCodeCoverage", "-enableCodesizeProfile",
        "-codesizeProfileOutputDir", "-exportPath", "-importPath", "-localizationPath", "-exportLanguage",
        "-defaultLanguage", "-testProductsPath", "-enablePerformanceTestsDiagnostics", "-only-testing",
        "-skip-testing", "-test-timeouts-enabled", "-default-test-execution-time-allowance",
        "-maximum-test-execution-time-allowance", "-test-repetition-relaunch-enabled",
        "-skip-test-configuration", "-testLanguage", "-testRegion", "-test-enumeration-style",
        "-test-enumeration-format", "-test-enumeration-output-path", "-packageCachePath",
        "-packageAuthorizationProvider", "-defaultPackageRegistryURL",
        "-packageDependencySCMToRegistryTransformation", "-packageFingerprintPolicy",
        "-packageSigningEntityPolicy", "-authenticationKeyPath", "-authenticationKeyID",
        "-authenticationKeyIssuerID", "-scmProvider",
    ]

    /// Arguments that put `xcodebuild` somewhere this table has no wording for, whichever action is named beside them.
    ///
    /// Two shapes, both ending in ``unreadable`` because both close on a line nobody here has measured. The flags are the modes from `-help`'s alternate usage lines — an export, an import, a package resolution, a component download — which replace the build entirely and stamp their own verdict (`** EXPORT SUCCEEDED **` and the like). `installsrc` is the other: an action the manual page lists that was measured to print nothing at all, so a contract naming any wording for it would be a claim about a line that never arrives.
    private static let actionsWithNoWording: Set<String> = [
        "-exportArchive", "-exportNotarizedApp", "-exportLocalizations", "-importLocalizations",
        "-resolvePackageDependencies", "-create-xcframework", "-downloadPlatform", "-downloadAllPlatforms",
        "-importPlatform", "-downloadComponent", "-importComponent", "-deleteComponent", "-showComponent",
        "-license", "-checkFirstLaunchStatus", "-runFirstLaunch", "-prepareDeviceSupport",
        "-find-executable", "-find-library",
        "installsrc",
    ]

    /// The contract of an `xcodebuild` invocation — the wording its action stamps, or ``unreadable`` when argv named no action this table can be sure of.
    ///
    /// The reading is ``xcodebuildAction(of:)``'s; all this adds is the wording, because the wording is the only part a verdict needs and the action itself is wanted somewhere else as well.
    private static func xcodebuild(_ arguments: [String]) -> RunVerdict.Contract {
        guard let action = xcodebuildAction(of: arguments), let stem = stems[action] else {
            return .unreadable
        }
        return .declares(succeeded: "** \(stem) SUCCEEDED **", failed: "** \(stem) FAILED **")
    }

    /// The action `xcodebuild` performs when an invocation names none, in the manual page's own words: *"build … is the default action, and is used if no action is given."*
    private static var defaultAction: String {
        "build"
    }
}

// MARK: - What the invocation is doing

extension RunVerdict.Contract {
    /// The action an `xcodebuild` invocation names — the last bare word this table knows — or `nil` when argv does not settle which one it is.
    ///
    /// **Two readers want this, and only one of them wants a wording.** ``xcodebuild(_:)`` turns it into the line the run owes; ``RunCommandKind/logKey(of:)`` writes it into the run log, so that `xcodebuild test` and `xcodebuild build` stop filing under one word and a per-test history has a population to count against. One reading serves both, because two copies of this rule would be two places for it to drift — and the safety properties below are worth exactly as much to the log as they are to the verdict.
    ///
    /// The **last** action, because `xcodebuild clean build` performs its actions in order and prints one verdict per action: the run's verdict is the final one, and a log whose last `** … **` is the *clean*'s is a run that stopped before the build could judge itself.
    ///
    /// **An action is a bare word that is not some option's value, and telling those apart needs the option table above.** Asking only whether the word in front begins with `-` makes every valueless flag swallow the action behind it: `-quiet test`, `-skipMacroValidation build`, `-allowProvisioningUpdates build` and `-showBuildTimingSummary build` would all lose their action, so the commonest invocations in a CI script would draw `⚠` on every run, green ones included. The `⚠` is the signal this whole path exists for and it cannot be spent on false alarms. A flag carrying its value in its own name (`-only-testing:AlphaTests/x`) takes nothing behind it either, which the colon says.
    ///
    /// **No action word at all is `build`**, in the manual page's own words: *"build … is the default action, and is used if no action is given."* Two refusals are what make that safe to say. An invocation that could be doing something other than building a target has already answered `nil`. And an action word swallowed as some option's value takes the whole reading down with it: `-scheme test` names a scheme and `-aFlagAddedAfterThisTableWasWritten test` names the action, and nothing in argv tells the two apart — so defaulting there would have this command owe `** BUILD SUCCEEDED **` over a log closing on `** TEST SUCCEEDED **`, and print that as *the log never reached the line this command ends on*. A fabricated claim about the log is precisely the fault this headline exists not to make, and it is not worth trading one spelling of it for another.
    ///
    /// **`nil` is what makes the whole reading safe**, and it is a refusal rather than an absence. An unread contract that claimed anything would let the reader downstream take whichever `** … **` the log carried, so moving `-quiet` one word to the left would turn a run whose only verdict was `** CLEAN SUCCEEDED **` from a reported anomaly into a green tick. The log inherits the same discipline: a run whose action went unread files under the bare tool name, where nothing can count it as a run that could have executed a test.
    ///
    /// **But a collision is doubt, not a verdict, and doubt a later word can settle is not doubt.** Refusing on the spot at an option value spelled like an action word would throw away every argument after it: `xcodebuild -derivedDataPath build -scheme App -destination … test` would stop at `build` and never see the bare `test` four words later, so a shape a CI script writes constantly would draw `⚠ … could not tell which verdict the command owed` over a log closing on `** TEST SUCCEEDED **` — the false alarm this reading exists to avoid, at the one spelling it is cheapest to avoid it. So the collision is recorded and read at the end. A later bare action word clears it, because the run's verdict is its last action's whichever way the doubted word was meant; a collision standing *after* the last bare action does not, because if the flag in front of it takes no value then that word is the last action and the wording owed is a different one.
    static func xcodebuildAction(of arguments: [String]) -> String? {
        var action = defaultAction
        var doubted = false
        var expectingValue = false
        for argument in arguments.dropFirst() {
            if expectingValue {
                expectingValue = false
                // An option's value spelled like an action word is doubt, not a verdict: this table can
                // be wrong about whether the flag in front of it takes one, so the word might be the
                // action. Recorded and read at the end, because a *later* bare action word settles it.
                doubted = doubted || stems[argument] != nil
                continue
            }
            if actionsWithNoWording.contains(argument) {
                return nil
            }
            guard !argument.hasPrefix("-") else {
                expectingValue = !valuelessFlags.contains(argument) && !argument.contains(":")
                continue
            }
            if stems[argument] != nil {
                action = argument
                doubted = false
            }
        }
        guard !doubted, stems[action] != nil else {
            return nil
        }
        return action
    }

    /// Whether `word` is an action `xcodebuild` performs, read from the same table ``xcodebuildAction(of:)`` reads one with.
    ///
    /// A caller that has to *refuse* an action word rather than read one asks here, so there is one list of them: `sift test` supplies the action itself, and a pass-through naming a second one is two spellings of one thing, which is how they come to disagree.
    static func isXcodebuildAction(_ word: String) -> Bool {
        stems[word] != nil
    }

    /// For an argument list that carries **no executable**, whether each argument stands on its own rather than filling the slot behind the option in front of it.
    ///
    /// **The pass-through after `sift test --` is a tail of options with no command at its head**, so neither ``xcodebuildAction(of:)`` nor ``isQuietXcodebuild(_:)`` answers about it: both drop the first argument, which there is the tool's own name and here is an option. This is the same walk over the option table, answering per argument, so a caller with its own list of words to refuse tells a word from a value exactly as the verdict does.
    ///
    /// **It walks the same option table the verdict reads, but the other way.** ``xcodebuildAction(of:)`` assumes an option it has never heard of takes a value, because swallowing the word behind an unrecognised flag is cheaper than misreading an action — a false `⚠` over a green run. A refused word hiding behind an unrecognised flag is the opposite mistake: nothing downstream ever sees it, so it rides straight through as a silent pass. **The safe direction here is to refuse more**: an option this table has never heard of — neither ``valuelessFlags`` nor ``valueTakingFlags`` — is treated as if it took no value, so the word behind it is still checked. `-configuration test` still names a configuration rather than drawing a refusal over an action nobody asked for, because ``valueTakingFlags`` knows `-configuration`; a flag neither table knows does not get the same benefit of the doubt.
    static func standsAlone(in arguments: [String]) -> [Bool] {
        var standing: [Bool] = []
        var expectingValue = false
        for argument in arguments {
            if expectingValue {
                expectingValue = false
                standing.append(false)
                continue
            }
            standing.append(true)
            if argument.hasPrefix("-") {
                expectingValue = valueTakingFlags.contains(argument) && !argument.contains(":")
            }
        }
        return standing
    }

    /// Whether `arguments` is an `xcodebuild` invocation asking for `-quiet` — the one flag that stops a clean run from printing the `** … SUCCEEDED **` line its contract owes.
    ///
    /// **This is what lets a silent log be read as a pass at all, so it errs toward no.** Without `-quiet`, `xcodebuild` prints its banner whenever it finishes, so a log with none is one that stopped early and stays `⚠`. `swift build` is never quiet in this sense, because it prints `Build complete!` whatever it was asked. `-quiet` is read with the option table ``xcodebuildAction(of:)`` reads the action with: a `-quiet` standing where an option's value goes, behind a flag this table does not know to be valueless, is not counted — the cost is a `⚠` over a clean run, which is the answer this tool gave before it could read `-quiet` at all.
    static func isQuietXcodebuild(_ arguments: [String]) -> Bool {
        guard RunCommandKind.recognize(arguments) == .xcodebuild else {
            return false
        }
        var expectingValue = false
        for argument in arguments.dropFirst() {
            if expectingValue {
                expectingValue = false
                continue
            }
            if argument == "-quiet" {
                return true
            }
            if argument.hasPrefix("-") {
                expectingValue = !valuelessFlags.contains(argument) && !argument.contains(":")
            }
        }
        return false
    }
}
