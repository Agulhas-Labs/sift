//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// A property wrapper's `@T` attribute in a file written since the build is judged by nothing the store says about that file, whose lines have moved, so `where` heads its answer stale and never drops the site under a fresh header.
@Suite(.temporaryDirectories)
struct WrapperStaleSiteTests {
    /// The wrapper, whose one initializer the attribute calls.
    static var wrapper: String {
        """
        @propertyWrapper struct Clamp {
            var wrappedValue: Int
            init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
        }
        """
    }

    /// The `where` answer for the wrapper's initializer once `use` is built and then written again one line lower.
    static func shiftedAnswer(_ use: String) async throws -> String {
        let root = try ProjectedValueCallTests.repo(["Sources/Probe/Clamp.swift": wrapper, "Sources/Probe/Use.swift": use])
        try TestSources.swiftBuild(packageAt: root)
        try TestSources.write("\n" + use, to: "Sources/Probe/Use.swift", in: root)
        return try await ProjectedValueCallTests.lookup("Clamp.init", in: root, built: false)
    }

    /// An attribute on a function's parameter, which the store records no call at, is listed at its line in the tree and marked as the store's rows in that file are.
    @Test
    func aStaleFilesParameterAttributeIsListedMarked() async throws {
        let output = try await Self.shiftedAnswer(
            """
            func clamped(@Clamp _ x: Int) -> Int { x }
            let y = clamped(3)
            """
        )

        #expect(output.contains("semantic: stale"), "\(output)")
        #expect(!output.contains("no callers"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Use.swift:2  in clamped(_:)  (file changed since last build)"), "\(output)")
    }

    /// An attribute on a stored property the store records as a call is listed by name at its moved line too, since the store's row names the line it was on at the build.
    @Test
    func aStaleFilesPropertyAttributeIsListedAtItsLine() async throws {
        let output = try await Self.shiftedAnswer(
            """
            struct Box {
                @Clamp var v = 1
            }
            """
        )

        #expect(output.contains("semantic: stale"), "\(output)")
        #expect(output.contains("Use.swift (1):  (file changed since last build)\n    :2  v\n"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Use.swift:3  in Box.v  (file changed since last build)"), "\(output)")
    }

    /// The `where` answer for the wrapper's initializers once `built` is built as the file of uses, beside `others`, and that file is then written as `later`, its sites one per line.
    static func rewrittenAnswer(_ built: String, then later: String, others: [String: String] = [:]) async throws -> String {
        let wrapper = ProjectedValueInitCallerTests.recorded["Sources/Probe/Clamp.swift"] ?? ""
        let files = others.merging(["Sources/Probe/Clamp.swift": wrapper, "Sources/Probe/Use.swift": built]) { $1 }
        let root = try ProjectedValueCallTests.repo(files)
        try TestSources.swiftBuild(packageAt: root)
        try TestSources.write(later, to: "Sources/Probe/Use.swift", in: root)
        let answer = try await ProjectedValueCallTests.lookup("Clamp.init", in: root, built: false)
        return WhereAnswerRepetitionTests.sitesOnePerLine(answer)
    }

    /// Two parameters' attributes on lines of their own, which the store records as calls counted in one folded row.
    static var folded: String {
        """
        func f(
            @Clamp x: Int,
            @Clamp y: Int
        ) -> Int { x + y }
        """
    }

    /// An attribute written since the build at a line and column where the store recorded another is listed at its own line, since the recorded position no longer says which site it was.
    @Test
    func anAttributeAtAReusedPositionIsListed() async throws {
        let later = """
        let z = 0
        func g(
            @Clamp y: Int
        ) -> Int { y }
        """
        let output = try await Self.rewrittenAnswer(Self.folded, then: later)

        #expect(output.contains("semantic: stale"), "\(output)")
        #expect(output.contains("Use.swift:3  in g(y:)"), "\(output)")
    }

    /// A recorded attribute counted only in its caller's folded row, in a file written again since the build, is listed at its own line.
    @Test
    func aFoldedAttributeInAWrittenFileIsListed() async throws {
        let output = try await Self.rewrittenAnswer(Self.folded, then: Self.folded)

        #expect(output.contains("Use.swift:2"), "\(output)")
        #expect(output.contains("Use.swift:3  in f(x:y:)"), "\(output)")
    }

    /// Seven stored properties' attributes in a file whose callers are listed ahead of the file of uses.
    static var boxes: String {
        """
        struct Box {
        \(["a", "b", "c", "d", "e", "f", "g"].map { "    @Clamp var \($0) = 1" }.joined(separator: "\n"))
        }
        """
    }

    /// Each recorded attribute within the cap on name-matched sites, in a file written again since the build whose callers run past the cap on callers, is listed at its own line.
    @Test
    func attributesPastTheCapInAWrittenFileAreListed() async throws {
        let many = (1 ... 45).map { "func m\($0)(@Clamp x: Int) -> Int { x }" }.joined(separator: "\n")
        let output = try await Self.rewrittenAnswer(many, then: many, others: ["Sources/Probe/Box.swift": Self.boxes])

        for line in 1 ... 40 {
            let listed = output.contains("Use.swift:\(line)  in m\(line)(x:)") || output.contains("m\(line)(x:) — Sources/Probe/Use.swift:\(line) ")
            #expect(listed, "m\(line) at Use.swift:\(line) is missing: \(output)")
        }
    }

    /// An attribute on a stored property written since the build, which the store holds no record of, is listed at its own line.
    @Test
    func aPropertyAttributeWrittenSinceTheBuildIsListed() async throws {
        let built = "struct Box { @Clamp var a = 1 }"
        let output = try await Self.rewrittenAnswer(built, then: built + "\nstruct Crate { @Clamp var t = 2 }")

        #expect(output.contains("semantic: stale"), "\(output)")
        #expect(output.contains("Use.swift:2  in Crate.t"), "\(output)")
    }

    /// An attribute written with a qualifier that spells no owner of this wrapper is kept, never dropped: a typealias of the owner makes Swift read it as this module's wrapper, and the line is marked as written since the build, as every unjudged site of the file is.
    @Test
    func aStaleFilesQualifiedParameterAttributeIsKeptAndMarkedModified() async throws {
        let root = try ProjectedValueCallTests.repo(["Sources/Probe/Clamp.swift": Self.wrapper, "Sources/Probe/Use.swift": Self.qualifiedUse])
        try TestSources.swiftBuild(packageAt: root)
        try TestSources.write("\n" + Self.qualifiedUse, to: "Sources/Probe/Use.swift", in: root)
        let output = try await ProjectedValueCallTests.lookup("Probe.Clamp.init", in: root, built: false)

        #expect(output.contains("semantic: stale"), "\(output)")
        #expect(output.contains("in scoped(_:)"), "\(output)")
        #expect(output.contains("in scoped(_:)  (file changed since last build)"), "\(output)")
    }

    /// A generic outer type's arguments are no part of the scope a qualifier names, so an attribute written with them is still this wrapper's.
    @Test
    func aStaleFilesGenericQualifiedParameterAttributeIsListed() async throws {
        let root = try ProjectedValueCallTests.repo(["Sources/Probe/Clamp.swift": Self.genericWrapper, "Sources/Probe/Use.swift": Self.genericUse])
        try TestSources.swiftBuild(packageAt: root)
        try TestSources.write("\n" + Self.genericUse, to: "Sources/Probe/Use.swift", in: root)
        let output = try await ProjectedValueCallTests.lookup("App.Gen.Clamp.init", in: root, built: false)

        #expect(output.contains("semantic: stale"), "\(output)")
        #expect(output.contains("in App.generic(x:)"), "\(output)")
    }

    /// The same attribute is kept where the wrapper's own file was written since the build and the name scan judges the site.
    @Test
    func aWrittenDeclaringFileKeepsAGenericQualifiedParameterAttribute() async throws {
        let root = try ProjectedValueCallTests.repo(["Sources/Probe/Clamp.swift": Self.genericWrapper, "Sources/Probe/Use.swift": Self.genericUse])
        try TestSources.swiftBuild(packageAt: root)
        try TestSources.write("\n" + Self.genericWrapper, to: "Sources/Probe/Clamp.swift", in: root)
        let output = try await ProjectedValueCallTests.lookup("App.Gen.Clamp.init", in: root, built: false)

        #expect(output.contains("in App.generic(x:)"), "\(output)")
    }

    /// A wrapper nested in a generic type of an enum.
    static var genericWrapper: String {
        """
        enum App {
            struct Gen<T> {
                @propertyWrapper struct Clamp {
                    var wrappedValue: Int
                    init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
                }
            }
        }
        """
    }

    /// A function of the enum taking it, written with the outer type's generic arguments.
    static var genericUse: String {
        """
        extension App {
            func generic(@Gen<Int>.Clamp x: Int) -> Int { x }
        }
        """
    }

    /// A nested wrapper of the same short name, and a function taking it written with its qualifier.
    static var qualifiedUse: String {
        """
        struct Outer {
            @propertyWrapper struct Clamp {
                var wrappedValue: Int
                init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
            }
        }
        func scoped(@Outer.Clamp _ x: Int) -> Int { x }
        """
    }
}
