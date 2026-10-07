//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// How a declaration a macro generated is named by the macro that made it, as the runtime's demangler reads the mangled name the store gives it.
struct ExpansionOriginTests {
    /// A mangled name built the way the grammar builds one: `prefix`, each name prefixed by its length, then the marker of a macro expansion of `kind` — `f`, `M`, the kind, and a discriminator.
    static func mangled(_ prefix: String, _ names: [String], kind: String) -> String {
        prefix + names.map { "\($0.count)\($0)" }.joined() + "f" + "M" + kind + "_"
    }

    /// `@Test func spans()` generates a function the store names by its mangling: the module, the attached declaration, the macro, and a peer macro's marker.
    @Test
    func anAttachedMacrosExpansionIsReadAsTheMacroAndTheDeclarationItIsAttachedTo() {
        let origin = ExpansionOrigin(mangled: Self.mangled("$s", ["GizmoTests", "spans", "Test"], kind: "p") + "()")

        #expect(origin == ExpansionOrigin(macro: "Test", attachedTo: "spans"))
        #expect(origin?.expansion == "@Test expansion of spans")
    }

    /// A freestanding macro's marker follows the macro's name alone, and a unique name's marker after it names no macro.
    @Test
    func aFreestandingMacrosExpansionIsReadAsTheMacroAlone() {
        let origin = ExpansionOrigin(mangled: Self.mangled("s:", ["GizmoApp", "Preview"], kind: "f") + Self.mangled("", ["Record"], kind: "u"))

        #expect(origin == ExpansionOrigin(macro: "Preview", attachedTo: nil))
        #expect(origin?.spelling == "#Preview")
        #expect(origin?.expansion == "#Preview expansion")
    }

    /// A declaration named with trailing digits runs them into the macro's length prefix — `test2` before `Test` puts `24` before `Test` — and the tail of that run still spells the macro's length.
    @Test
    func aDeclarationEndingInDigitsIsStillReadApartFromTheMacro() {
        let origin = ExpansionOrigin(mangled: Self.mangled("$s", ["GizmoTests", "test2", "Test"], kind: "p"))

        #expect(origin == ExpansionOrigin(macro: "Test", attachedTo: "test2"))
    }

    /// Letters that spell a marker inside a name are not one, and neither is a marker the demangler cannot read: a declaration counts as generated only where the demangler reads an expansion, since one wrongly counted can have a use of its own dropped as a macro's copy.
    @Test
    func onlyAnExpansionTheDemanglerReadsIsGeneratedCode() {
        let property = "s:4Dial4" + "f" + "Map" + "Si" + "vp"
        let unreadable = Self.mangled("$s", ["x"], kind: "p")

        #expect(!ExpansionOrigin.isGenerated(property))
        #expect(ExpansionOrigin(mangled: property) == nil)
        #expect(!ExpansionOrigin.isGenerated(unreadable))
        #expect(ExpansionOrigin(mangled: unreadable) == nil)
    }

    /// A function the user named `fMp_odd` spells a peer macro's marker and discriminator inside its own name — the USR a real store gives it — and is still the user's function: the demangler reads it as `GizmoApp.fMp_odd() -> Swift.Int`.
    @Test
    func aNameThatSpellsAMarkerIsNotGeneratedCode() {
        // Split only so the example-name gate reads no run of mangling as one name.
        let usr = "s:8GizmoApp" + "7fMp_odd" + "Si" + "yF"

        #expect(!ExpansionOrigin.isGenerated(usr))
        #expect(ExpansionOrigin(mangled: usr) == nil)
    }
}
