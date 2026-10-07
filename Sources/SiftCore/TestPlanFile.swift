//
// Copyright © Agulhas Labs
//

import Foundation

/// One `.xctestplan` document as it is written on disk: the facts a plan states, and nothing about what Xcode will do with them.
///
/// A plan is small JSON and is read live rather than indexed, so a plan edited a minute ago is answered on, there is nothing stored to go stale, and no schema grows for it.
///
/// Nothing here claims a plan is attached to a scheme: that lives in `.xcscheme` XML inside an `.xcodeproj` a generated project may not even have committed, and a plan that cannot be proved wired up is still a plan whose contents are a fact.
///
/// Whether an exclusion has any effect depends on which framework declared the test it names, which only the index knows, so every entry is carried in the exact form the plan spells it and that judgement is left to the caller that holds both halves.
public struct TestPlanFile: Sendable, Equatable {
    /// The file's basename without its extension — the name `--plan` matches.
    public let name: String
    /// Where the file sits, relative to the root it was found under.
    public let path: String
    /// Every entry of `testTargets`, in the order the document lists them.
    public let targets: [Target]
    /// `defaultOptions.testRepetitionMode`, verbatim: `retryOnFailure` is the setting that makes XCTest count attempts rather than tests in its own tally.
    public let repetitionMode: String?
    /// `defaultOptions.maximumTestRepetitions`, verbatim.
    public let maximumRepetitions: Int?
}

public extension TestPlanFile {
    /// One `testTargets` entry: a target the plan runs, and how it narrows that target.
    struct Target: Sendable, Equatable {
        /// `target.name` — the spelling `-enumerate-tests` prints and `-only-testing:` takes.
        public let name: String
        /// `target.containerPath`, verbatim (`container:TestDemo.xcodeproj`), which says which container declares the target and nothing about a scheme, and which ``TestPlanFile/containerScope(of:)`` reads into the directory this plan's judgement of that target is confined to.
        public let containerPath: String?
        /// Whether the plan runs this target at all; an absent `enabled` key means it does.
        public let isEnabled: Bool
        /// `skippedTests`, each entry as written.
        public let skipped: [Entry]
        /// `selectedTests`, each entry as written.
        public let selected: [Entry]
    }

    /// One `skippedTests`/`selectedTests` entry as written, kept in its written form because the form decides whether Xcode honours it.
    ///
    /// Every `/` divides a step of the identifier, so the nested class Xcode writes as `AlphaTests/NamedSuite/testX()` is read as the suite `AlphaTests.NamedSuite` and the function `testX()` rather than as a suite called `AlphaTests`.
    struct Entry: Sendable, Equatable {
        /// Exactly as the plan spells it.
        public let written: String
        /// The dotted suite path the entry names, and empty for an entry that could not be read.
        public let type: String
        /// The function the entry names, `nil` for an entry that names a whole type.
        public let function: String?
        /// Whether ``function`` ends in `)`, which is the half of the form a caller needs to tell an entry Xcode honours from one it ignores.
        public let carriesParentheses: Bool

        /// Whether the entry could be read at all — an entry with an empty step in it is neither a suite path nor a function and is answered on as unreadable rather than guessed at.
        public var isReadable: Bool {
            !type.isEmpty
        }

        init(written: String) {
            self.written = written
            let steps = written.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !steps.contains(where: \.isEmpty) else {
                type = ""
                function = nil
                carriesParentheses = false
                return
            }
            let last = steps[steps.count - 1]
            let namesAFunction = steps.count > 1 && Entry.namesAFunction(last)
            type = (namesAFunction ? steps.dropLast() : steps[...]).joined(separator: ".")
            function = namesAFunction ? last : nil
            carriesParentheses = namesAFunction && last.hasSuffix(")")
        }

        /// Whether the last step of an entry names a function rather than one more step of the suite path.
        ///
        /// This is a reading of Swift's naming convention and not a measurement: a function identifier either carries its argument list or opens lowercase, where every step of a type's path opens with something else.
        private static func namesAFunction(_ step: String) -> Bool {
            step.hasSuffix(")") || (step.first?.isLowercase ?? false)
        }
    }
}

public extension TestPlanFile {
    /// The directory a target's `containerPath` confines it to, relative to the root this plan was found under, or `nil` where that path cannot be read as one.
    ///
    /// The empty string is the root itself, which confines nothing; a target whose declaring files sit outside the answer is a target this plan says nothing about, because a plan states what one container's targets run and names no target of any other.
    ///
    /// A container written without `..` is ambiguous between two layouts Xcode writes alike — the plan beside its container, and the plan in a folder of plans beside it — so the wider of the two is taken, since widening only judges a target the plan may not name where narrowing would drop one it does.
    func containerScope(of target: Target) -> String? {
        guard let written = target.containerPath, written.hasPrefix(Self.containerPrefix) else {
            return nil
        }
        let steps = written.dropFirst(Self.containerPrefix.count).split(separator: "/").map(String.init)
        guard !steps.isEmpty else {
            return nil
        }
        let planDirectory = path.split(separator: "/").dropLast().map(String.init)
        guard steps.contains("..") else {
            return planDirectory.dropLast().joined(separator: "/")
        }
        guard let container = Self.resolving(steps, under: planDirectory) else {
            return nil
        }
        return container.dropLast().joined(separator: "/")
    }
}

private extension TestPlanFile {
    /// The prefix Xcode writes before a container's path, and the one form of `containerPath` this reads.
    static var containerPrefix: String {
        "container:"
    }

    /// The path steps resolved against the plan's own directory, or `nil` where they climb past the root the plan was found under.
    static func resolving(_ steps: [String], under directory: [String]) -> [String]? {
        var components = directory
        for step in steps {
            switch step {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(step)
            }
        }
        return components.isEmpty ? nil : components
    }
}

extension TestPlanFile {
    /// Reads one plan document, refusing rather than guessing when the bytes are not one.
    ///
    /// `name` and `path` are stated by the caller rather than recovered from the document, because neither is written inside it: a plan knows nothing of what it is called or where it lives.
    ///
    /// **The retry settings are read from `defaultOptions` alone.** A configuration may carry its own `testRepetitionMode`, and answering from one would mean choosing a configuration, which nothing here does — the plans this was measured against set both alike, and "which configuration" is a different question from "what does this plan state".
    public static func read(_ data: Data, name: String, path: String) throws -> TestPlanFile {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw TestPlanError.unreadable(path: path, reason: "\(error)")
        }
        let targets = document.testTargets.map { entry in
            Target(
                name: entry.target.name,
                containerPath: entry.target.containerPath,
                isEnabled: entry.enabled ?? true,
                skipped: (entry.skippedTests ?? []).map(Entry.init(written:)),
                selected: (entry.selectedTests ?? []).map(Entry.init(written:))
            )
        }
        return TestPlanFile(
            name: name,
            path: path,
            targets: targets,
            repetitionMode: document.defaultOptions?.testRepetitionMode,
            maximumRepetitions: document.defaultOptions?.maximumTestRepetitions
        )
    }

    /// The document as Xcode writes it, modelled only where this answers from it.
    ///
    /// A key that is not modelled — `version`, `configurations`, `codeCoverage`, `parallelizable` — is ignored rather than refused, because a plan carries options this does not read and a reader that rejected them would refuse every plan a later Xcode writes.
    ///
    /// `testTargets` is the one required key: a JSON document without it is some other document that happens to sit at this extension, and reading it as a plan with no targets would answer "this plan runs nothing" about a file that is not a plan at all.
    fileprivate struct Document: Decodable {
        let defaultOptions: Options?
        let testTargets: [TargetEntry]
    }
}

extension TestPlanFile.Document {
    struct Options: Decodable {
        let testRepetitionMode: String?
        let maximumTestRepetitions: Int?
    }

    struct TargetEntry: Decodable {
        let target: Reference
        let enabled: Bool?
        let skippedTests: [String]?
        let selectedTests: [String]?
    }
}

extension TestPlanFile.Document.TargetEntry {
    struct Reference: Decodable {
        let name: String
        let containerPath: String?
    }
}
