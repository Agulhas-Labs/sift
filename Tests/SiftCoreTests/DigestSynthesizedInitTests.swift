//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `digest Type.init` on a struct with no declared initializer answers with the memberwise initializer the compiler writes, not as a member that does not exist.
@Suite(.temporaryDirectories)
struct DigestSynthesizedInitTests {
    static var shapes: String {
        """
        struct Gadget {
            let id: Int
            let kind = "fixed"
            var weight: Int = 0
            var label: String?
            static var count = 0
            lazy var cache = [Int]()
            var area: Int { weight * 2 }
            var tags: [String] = []
        }

        struct Vault {
            private var secret = 1
            var open: Int
        }

        struct Locked {
            private var p: Int
            var q = 1
        }

        struct Ledger {
            fileprivate var entries: [Int]
            var owner: String
        }

        struct Own {
            var size: Int
            init(size: Int) {
                self.size = size
            }
        }

        struct Pair {
            var left: Int
            var right: Int
        }

        extension Pair {
            init(both: Int) {
                self.init(left: both, right: both)
            }
        }

        final class Boxed {
            var weight: Int = 0
        }

        enum Mode {
            case fast
        }
        """
    }

    static func answer(_ target: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(shapes, to: "Sources/App/Shapes.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return try engine.digest(target: target, options: DigestOptions())
    }

    /// The parameters are the stored properties in order: a `let` with a value, a static and a computed property take none, and a `var` with a value, a lazy one included, is defaulted.
    @Test
    func theParametersAreTheStoredPropertiesInDeclarationOrder() async throws {
        let answer = try await Self.answer("Gadget.init")

        #expect(!answer.contains("has no member"), "\(answer)")
        #expect(answer.contains("Gadget.init — initializer — Sources/App/Shapes.swift:2-9"), "\(answer)")
        #expect(answer.contains("compiler-synthesized"), "\(answer)")
        #expect(answer.contains("init(id: Int, weight: Int = 0, label: String? = nil, cache: <inferred> = [Int](), tags: [String] = [])"), "\(answer)")
        #expect(answer.contains("access: internal"), "\(answer)")
    }

    /// A private property that has a default is left out of the internal initializer instead of making it private.
    @Test
    func aDefaultedPrivatePropertyIsLeftOutAndTheInitializerStaysInternal() async throws {
        let answer = try await Self.answer("Vault.init")

        #expect(answer.contains("init(open: Int)"), "\(answer)")
        #expect(!answer.contains("secret"), "\(answer)")
        #expect(answer.contains("access: internal"), "\(answer)")
    }

    /// A private property without a default stays a parameter and makes the initializer private.
    @Test
    func aRequiredPrivatePropertyMakesTheInitializerPrivate() async throws {
        let answer = try await Self.answer("Locked.init")

        #expect(answer.contains("init(p: Int"), "\(answer)")
        #expect(answer.contains("access: private"), "\(answer)")
    }

    /// A fileprivate stored property makes it fileprivate.
    @Test
    func aFileprivatePropertyMakesTheInitializerFileprivate() async throws {
        let answer = try await Self.answer("Ledger.init")

        #expect(answer.contains("access: fileprivate"), "\(answer)")
    }

    /// A struct that declares an init in its body gets no memberwise one: the declared init is served, with nothing synthesized.
    @Test
    func aDeclaredInitSuppressesTheSynthesizedOne() async throws {
        let answer = try await Self.answer("Own.init")

        #expect(answer.contains("init(size: Int) {"), "\(answer)")
        #expect(!answer.contains("compiler-synthesized"), "\(answer)")
    }

    /// An init in an extension does not stop the compiler writing the memberwise one, so both are answered.
    @Test
    func anExtensionInitDoesNotSuppressTheSynthesizedOne() async throws {
        let answer = try await Self.answer("Pair.init")

        #expect(answer.contains("init(both: Int) {"), "\(answer)")
        #expect(answer.contains("compiler-synthesized"), "\(answer)")
        #expect(answer.contains("init(left: Int, right: Int)"), "\(answer)")
    }

    /// A class or an enum with no declared init is answered as it was: a miss, not a memberwise initializer.
    @Test
    func aClassOrEnumIsAnsweredAsBefore() async throws {
        for target in ["Boxed.init", "Mode.init"] {
            let answer = try await Self.answer(target)

            #expect(!answer.contains("compiler-synthesized"), "\(answer)")
            #expect(answer.contains("has no member init"), "\(answer)")
        }
    }
}
