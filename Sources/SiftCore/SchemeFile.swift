//
// Copyright © Agulhas Labs
//

import Foundation

/// One `.xcscheme` document as it is written on disk: what its test action names, and which container it belongs to.
///
/// A scheme is the other half of "what runs this test target": a plan states what one container's targets run, and a scheme's `TestAction` states whether anything invokes that plan at all — or, where it names no plan, runs the targets its `Testables` block lists directly.
///
/// Schemes are small XML and are read live rather than indexed, for the reason plans are: a scheme edited a minute ago is answered on, and no schema grows for them.
///
/// Only the `TestAction` is modelled. A scheme also carries build, launch, profile, analyse and archive actions, and none of them says anything about which tests are expected to run.
public struct SchemeFile: Sendable, Equatable {
    /// The file's basename without its extension — the name `xcodebuild -scheme` takes.
    public let name: String
    /// Where the file sits, relative to the root it was found under.
    public let path: String
    /// The `.xcodeproj` or `.xcworkspace` this scheme belongs to, relative to that root.
    public let container: String
    /// The directory holding that container, which is the scope this scheme's judgement is confined to; the empty string is the root itself, which confines nothing.
    public let containerScope: String
    /// Whether the scheme is shared (`xcshareddata`) rather than one developer's (`xcuserdata`), which is the difference between a scheme every checkout has and one that exists on a single machine.
    public let isShared: Bool
    /// The scheme's `TestAction`, and `nil` for a document that carries none.
    public let testAction: TestAction?
}

public extension SchemeFile {
    /// A scheme's `TestAction`, in the two shapes Xcode writes it: a list of test plans, or a list of testable targets.
    struct TestAction: Sendable, Equatable {
        /// Every `TestableReference`, in document order, whether or not test plans supersede them.
        public let testables: [Testable]
        /// Every `TestPlanReference`, in document order.
        public let planReferences: [PlanReference]

        /// The targets this action is read as running: the testables it does not skip, and none at all where test plans decide instead.
        ///
        /// **A `TestAction` that names test plans is read as running what those plans name, and its `Testables` block is not read as a run target.** That exclusivity is Xcode's documented behaviour and is not measured here, which is why a target named only in a superseded block is reported through ``supersededTargets`` instead: it is neither claimed to run nor claimed to be unrun.
        public var runTargets: [String] {
            planReferences.isEmpty ? testables.filter { !$0.isSkipped }.map(\.target) : []
        }

        /// The targets a `Testables` block names that test plans in the same action supersede, which this answer reads as evidence of nothing either way.
        public var supersededTargets: [String] {
            planReferences.isEmpty ? [] : testables.filter { !$0.isSkipped }.map(\.target)
        }
    }

    /// One `TestableReference`: the target it names, through the `BlueprintName` of the buildable inside it, and whether the scheme skips it.
    struct Testable: Sendable, Equatable {
        /// `BuildableReference.BlueprintName` — the target's own spelling, which is the one a plan and an enumeration both use.
        public let target: String
        /// `TestableReference.skipped`; an absent attribute means the target is not skipped.
        public let isSkipped: Bool
    }

    /// One `TestPlanReference`, as written.
    struct PlanReference: Sendable, Equatable {
        /// `reference`, verbatim (`container:TestPlans/Default.xctestplan`).
        public let reference: String
        /// `default = "YES"`, which names the plan a run that asks for no plan by name gets.
        public let isDefault: Bool
    }
}

public extension SchemeFile {
    /// The repository-relative path a `TestPlanReference` names, or `nil` where it cannot be read as one.
    ///
    /// A scheme's container reference is resolved against the directory holding the scheme's own container, which is where Xcode writes it from, so a reference climbing out with `..` names a plan in a sibling folder and one without names a plan beside the project.
    func planPath(of reference: PlanReference) -> String? {
        guard reference.reference.hasPrefix(Self.containerPrefix) else {
            return nil
        }
        let steps = reference.reference.dropFirst(Self.containerPrefix.count).split(separator: "/").map(String.init)
        guard !steps.isEmpty else {
            return nil
        }
        var components = containerScope.isEmpty ? [] : containerScope.split(separator: "/").map(String.init)
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
        return components.isEmpty ? nil : components.joined(separator: "/")
    }
}

public extension SchemeFile {
    /// Where a scheme sits: the container it belongs to, the directory holding that container, and whether it is shared.
    struct Location: Sendable, Equatable {
        public let container: String
        public let containerScope: String
        public let isShared: Bool
    }

    /// The location a repository-relative path describes, and `nil` for a `.xcscheme` sitting anywhere Xcode does not read one from.
    ///
    /// Xcode reads schemes from exactly two places inside a container: `xcshareddata/xcschemes` and `xcuserdata/<user>.xcuserdatad/xcschemes`. A file at this extension anywhere else — a template, a copy kept beside a document — is not a scheme anything runs, and reading it as one would put a target in the expected set on the strength of a file nothing opens.
    static func location(ofRepoRelativePath path: String) -> Location? {
        let steps = path.split(separator: "/").map(String.init)
        guard steps.count >= 4, steps[steps.count - 2] == "xcschemes" else {
            return nil
        }
        let shared = steps.count >= 4 && steps[steps.count - 3] == "xcshareddata"
        let user = steps.count >= 5 && steps[steps.count - 3].hasSuffix(".xcuserdatad") && steps[steps.count - 4] == "xcuserdata"
        let containerIndex = shared ? steps.count - 4 : steps.count - 5
        guard shared || user, containerIndex >= 0, isContainer(steps[containerIndex]) else {
            return nil
        }
        return Location(
            container: steps[0 ... containerIndex].joined(separator: "/"),
            containerScope: steps[0 ..< containerIndex].joined(separator: "/"),
            isShared: shared
        )
    }

    /// Whether one path component is a container a scheme lives inside.
    private static func isContainer(_ name: String) -> Bool {
        name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace")
    }

    /// The prefix Xcode writes before a container-relative path.
    private static var containerPrefix: String {
        "container:"
    }
}

public extension SchemeFile {
    /// Reads one scheme document, refusing rather than guessing when the bytes are not XML.
    ///
    /// `name` and `path` are stated by the caller rather than recovered from the document, exactly as a plan's are: a scheme carries no record of what it is called.
    ///
    /// A document that parses and holds no `TestAction` is a scheme that runs no tests, which is a fact about it rather than a failure to read it.
    static func read(_ data: Data, name: String, path: String, location: Location) throws -> SchemeFile {
        let reader = SchemeTestActionReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else {
            let reason = parser.parserError.map { "\($0)" } ?? "the document is not well-formed XML"
            throw SchemeError.unreadable(path: path, reason: reason)
        }
        return SchemeFile(
            name: name,
            path: path,
            container: location.container,
            containerScope: location.containerScope,
            isShared: location.isShared,
            testAction: reader.testAction
        )
    }
}
