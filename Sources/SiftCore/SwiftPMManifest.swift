//
// Copyright © Agulhas Labs
//

import Foundation
import SwiftParser
import SwiftSyntax

/// The target declarations a `Package.swift` states, read syntactically.
///
/// Parsed with SwiftSyntax rather than executed: `swift package dump-package` runs the manifest through the toolchain, which is slow, needs a toolchain beside the binary, and executes arbitrary code — all wrong for an indexer that may meet hundreds of manifests. Best-effort by design: only a literal `name:` and `path:` are readable this way, so a target whose values are computed contributes nothing here and the `Sources/<Target>` convention scan still covers it. A `.target(name:)` spelled as a *dependency* is indistinguishable from a bare target declaration, which is harmless — a target without an explicit path adds no mapping.
public struct SwiftPMManifest {
    let targets: [Target]
    /// The names of the targets declared with `.testTarget`, in the order the manifest states them.
    ///
    /// Kept apart from ``targets`` rather than as a flag on each, because the two are read for different questions: `targets` answers where a module's sources are, and this answers how many test bundles a `swift test` of this package owes a closing count — see ``RunTestBundles``.
    let testTargets: [String]
    /// Whether any `.testTarget` sits inside an `#if`, which makes ``testTargets`` a count of what the manifest *writes* rather than of what this platform builds.
    ///
    /// The parse is syntactic and deliberately so, and `#if os(Linux)` cannot be decided without the build that is being described — SwiftSyntax hands back every branch as written, so a manifest with a platform-only test target counts it everywhere. A consumer that needs the count to be a statement about *this* run reads this and declines; ``targets`` is unaffected, since mapping a source path wants every target the manifest names whatever the platform.
    let conditionalTestTargets: Bool
    /// Whether any target factory is called with a `name:` that is not a plain literal, which makes ``targets`` a partial list of what the manifest declares.
    let computedTargetNames: Bool
    /// The package's own name, as the `Package(name:)` call writes it in a plain literal, and `nil` where it is computed or no such call is read.
    let packageName: String?
    /// The names of the targets declared with `.plugin` or `.macro`, which SwiftPM compiles for the host with no index store, so no build of the package ever records a unit for them.
    let hostBuiltTargets: Set<String>

    /// `true` for a SwiftPM manifest at any depth — source to the build system, not to any module.
    ///
    /// The one predicate every layer shares: the indexer excludes these paths, `init` counts them apart, and the advice/measurement layers decline to treat reading one as a lookup the index lost — the index deliberately does not cover manifests, so a read of one is the right move, not a miss.
    public static func isManifestPath(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name == "Package.swift" || (name.hasPrefix("Package@swift-") && name.hasSuffix(".swift"))
    }

    /// Whether the `Package.swift` in `root` writes a `.testTarget` with a literal name, read syntactically like everything here; `false` for a manifest that cannot be read.
    public static func declaresTestTargets(inPackageAt root: URL) -> Bool {
        !parse(fileAt: root.appendingPathComponent("Package.swift")).testTargets.isEmpty
    }

    /// The name the `Package.swift` in `root` gives its package in a plain literal, read syntactically like everything here; `nil` for a manifest that cannot be read or computes the name.
    static func packageName(inPackageAt root: URL) -> String? {
        parse(fileAt: root.appendingPathComponent("Package.swift")).packageName
    }

    static func parse(fileAt url: URL) -> SwiftPMManifest {
        guard let data = FileManager.default.contents(atPath: url.path),
              let source = String(data: data, encoding: .utf8) else { return SwiftPMManifest(targets: [], testTargets: [], conditionalTestTargets: false, computedTargetNames: false, packageName: nil, hostBuiltTargets: []) }
        return parse(source: source)
    }

    static func parse(source: String) -> SwiftPMManifest {
        NestingGate.parseOrEmpty(source) { tree in
            let visitor = Visitor(viewMode: .sourceAccurate)
            visitor.walk(tree)
            return SwiftPMManifest(targets: visitor.targets, testTargets: visitor.testTargets, conditionalTestTargets: visitor.conditionalTestTargets, computedTargetNames: visitor.computedTargetNames, packageName: visitor.packageName, hostBuiltTargets: visitor.hostBuiltTargets)
        }
    }
}

extension SwiftPMManifest {
    struct Target: Equatable {
        let name: String
        /// The explicit `path:` argument, relative to the manifest's directory, when written as a literal.
        let path: String?
    }
}

private extension SwiftPMManifest {
    /// Source-bearing target factories; `binaryTarget` and `systemLibrary` carry no Swift to map.
    static let targetFactories: Set<String> = ["target", "executableTarget", "testTarget", "macro", "plugin"]

    final class Visitor: SyntaxVisitor {
        var targets: [SwiftPMManifest.Target] = []
        var testTargets: [String] = []
        var conditionalTestTargets = false
        var computedTargetNames = false
        /// The name the first `Package(name:)` call writes as a plain literal.
        var packageName: String?
        var hostBuiltTargets: Set<String> = []
        /// How many `#if` declarations enclose the node being visited, so a target inside one is known to be conditional whatever the condition says.
        private var ifConfigDepth = 0

        override func visit(_: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
            ifConfigDepth += 1
            return .visitChildren
        }

        override func visitPost(_: IfConfigDeclSyntax) {
            ifConfigDepth -= 1
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if packageName == nil, node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Package" {
                packageName = literal(labeled: "name", in: node)
            }
            guard let callee = node.calledExpression.as(MemberAccessExprSyntax.self),
                  callee.base == nil,
                  SwiftPMManifest.targetFactories.contains(callee.declName.baseName.text) else { return .visitChildren }
            guard let name = literal(labeled: "name", in: node) else {
                computedTargetNames = true
                return .visitChildren
            }
            targets.append(SwiftPMManifest.Target(name: name, path: literal(labeled: "path", in: node)))
            if ["plugin", "macro"].contains(callee.declName.baseName.text) {
                hostBuiltTargets.insert(name)
            }
            if callee.declName.baseName.text == "testTarget" {
                testTargets.append(name)
                conditionalTestTargets = conditionalTestTargets || ifConfigDepth > 0
            }
            return .visitChildren
        }

        /// The argument's string value when written as a plain single-segment literal, `nil` for anything computed.
        private func literal(labeled label: String, in node: FunctionCallExprSyntax) -> String? {
            guard let argument = node.arguments.first(where: { $0.label?.text == label }),
                  let literal = argument.expression.as(StringLiteralExprSyntax.self),
                  literal.segments.count == 1,
                  let segment = literal.segments.first?.as(StringSegmentSyntax.self) else { return nil }
            return segment.content.text
        }
    }
}
