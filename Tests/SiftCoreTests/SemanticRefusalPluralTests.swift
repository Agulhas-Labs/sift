//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// The one-file refusal line that names its declarations states its fact in the number it names: several declarations are never "the declaration".
struct SemanticRefusalPluralTests {
    @Test
    func aNamedLineForSeveralDeclarationsUnderAnIfIsPlural() {
        let refusals = [
            SemanticRefusal(path: "Sources/Lib/Dogwood.swift", reason: .unrecordedUnderCondition("#if os(Linux)"), symbol: "Lib.mixed(x:)", kind: .function),
            SemanticRefusal(path: "Sources/Lib/Dogwood.swift", reason: .unrecordedUnderCondition("#if os(Linux)"), symbol: "Lib.mixed(y:)", kind: .function),
        ]
        let line = SemanticRefusal.lines(refusals).joined(separator: "\n")

        #expect(line.contains("Sources/Lib/Dogwood.swift has no occurrences recorded in this build; the declarations are under #if os(Linux)"), "\(line)")
        #expect(line.contains("(2 declarations: Lib.mixed(x:) (func), Lib.mixed(y:) (func))"), "\(line)")
    }

    @Test
    func aNamedLineForSeveralUncoveredDeclarationsIsPlural() {
        let refusals = [
            SemanticRefusal(path: "Sources/Lib/Dogwood.swift", reason: .noCoveringUnit, symbol: "Lib.mixed(x:)", kind: .function),
            SemanticRefusal(path: "Sources/Lib/Dogwood.swift", reason: .noCoveringUnit, symbol: "Lib.mixed(y:)", kind: .function),
        ]
        let line = SemanticRefusal.lines(refusals).joined(separator: "\n")

        #expect(line.contains("Sources/Lib/Dogwood.swift has no unit in the store covering these declarations"), "\(line)")
    }

    /// The file is the subject of an edit, so the verb stays singular over several declarations.
    @Test
    func aFileModifiedSinceTheBuildIsSingularOverSeveralDeclarations() {
        let refusals = [
            SemanticRefusal(path: "Sources/Lib/Dogwood.swift", reason: .modifiedSinceBuild, symbol: "Lib.mixed(x:)", kind: .function),
            SemanticRefusal(path: "Sources/Lib/Dogwood.swift", reason: .modifiedSinceBuild, symbol: "Lib.mixed(y:)", kind: .function),
        ]
        let named = SemanticRefusal.lines(refusals).joined(separator: "\n")
        let unnamed = SemanticRefusal.lines(refusals, namingDeclarations: false, declarationsSpanMultipleFiles: true).joined(separator: "\n")

        #expect(named.contains("Sources/Lib/Dogwood.swift was changed since the last build"), "\(named)")
        #expect(unnamed.contains("Sources/Lib/Dogwood.swift was changed since the last build"), "\(unnamed)")
    }

    @Test
    func aNamedLineForOneDeclarationStaysSingular() {
        let refusals = [SemanticRefusal(path: "Sources/Lib/Dogwood.swift", reason: .unrecordedUnderCondition("#if os(Linux)"), symbol: "Lib.mixed(x:)", kind: .function)]
        let line = SemanticRefusal.lines(refusals).joined(separator: "\n")

        #expect(line.contains("Sources/Lib/Dogwood.swift has no occurrence recorded in this build; the declaration is under #if os(Linux)"), "\(line)")
        #expect(line.contains("(1 declaration: Lib.mixed(x:) (func))"), "\(line)")
    }
}
