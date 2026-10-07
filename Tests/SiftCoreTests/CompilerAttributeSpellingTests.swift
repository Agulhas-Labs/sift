//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers the language's own attribute spellings that no other suite names: each marks no macro in the digest and keeps no line at file scope.
struct CompilerAttributeSpellingTests {
    /// Each of these attributes is the compiler's, so none is a custom attribute.
    @Test
    func eachCompilerSpellingMarksNoMacro() {
        let signatures = [
            "@UIApplicationMain final class Delegate",
            "@_implementationOnly import Foundation",
            "@_spiOnly import Foundation",
            "@IBSegueAction func make() -> Gizmo?",
            "@_cdecl(\"swift_demangle\") func home()",
            "@implementation extension Gizmo",
            "@safe func home()",
            "@unsafe func home()",
            "@nonexhaustive public enum Mode",
        ]
        for signature in signatures {
            #expect(AttributeScanner.customAttributeNames(in: signature).isEmpty, "\(signature)")
        }
    }
}
