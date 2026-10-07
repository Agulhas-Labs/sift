//
// Copyright © Agulhas Labs
//

/// Recognises a test function by the same shape rule `TestSymbolReader` applies against the live index — `@Test`, or a `test…` instance method in a file importing XCTest.
///
/// Without that type's cross-file walk to a base class declared elsewhere, since a diff parses only the two revisions of the files the range itself touches (Docs/Design.md §2). The narrower rule is a stated trade, not a silent one: see `DiffRenderer`'s test-files section.
struct TestFileRecognition {
    static func isTestFile(imports: [String]) -> Bool {
        imports.contains("Testing") || imports.contains("XCTest")
    }

    /// Whether a function's `name`/`signature` looks like a test.
    ///
    /// `name`/`signature` come from either side — a caller checks both where they differ — and `isTestFile` says whether either side's file is a test file at all.
    static func isTestFunction(name: String, signature: String, isTestFile: Bool) -> Bool {
        if AttributeScanner.attributeNames(in: signature).contains("Test") {
            return true
        }
        return isTestFile && name.hasPrefix("test") && name.hasSuffix("()")
    }

    /// The same judgement over a `.function` addition, removal, or change, from whichever side's signature and file it has.
    static func isTestFunction(_ change: DeclarationChange, oldImports: [String], newImports: [String]) -> Bool {
        guard change.symbolKind == .function else { return false }
        let isTestFile = isTestFile(imports: newImports) || isTestFile(imports: oldImports)
        if let signature = change.newSignature, isTestFunction(name: change.name, signature: signature, isTestFile: isTestFile) {
            return true
        }
        if let signature = change.oldSignature, isTestFunction(name: change.name, signature: signature, isTestFile: isTestFile) {
            return true
        }
        return false
    }
}
