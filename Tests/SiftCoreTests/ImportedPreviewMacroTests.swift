//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `#Preview` at file scope, which declares no name in a file importing a module that declares it, SwiftUI, UIKit, AppKit or WidgetKit, so a bare name outside every type is still counted apart, while the same macro without the import, and every other freestanding macro, keeps the lines a use.
@Suite(.temporaryDirectories)
struct ImportedPreviewMacroTests {
    /// The verdict's clause for two lines set apart as outside every type.
    private static var setApartTwo: String {
        "; 2 more lines writing \"URL\" bare outside every type, extension and protocol, where the name cannot mean a type nested in another, so not use"
    }

    /// A top-level function writing Foundation's `URL` bare twice, and one writing the nested type's whole path.
    private static var plain: String {
        """
        import Foundation
        enum Net { struct URL { func fetched() {} } }
        func home() -> URL? {
            URL(string: "https://example.com")
        }
        func check(_ x: Net.URL) { x.fetched() }

        """
    }

    /// `Net.URL` asked of an unbuilt repo holding the plain fixture beside `file`.
    private static func answer(beside file: String) async throws -> String {
        try await WhereNestedTypeOutsideTests.answer("Net.URL", files: ["Sources/Lib/Entry.swift": file, "Sources/Lib/Lib.swift": plain])
    }

    /// A file-scope `#Preview`, inside `#if DEBUG` too, under an import of a module declaring it adds no name.
    @Test
    func aPreviewUnderItsImportLeavesTheLinesCountedApart() async throws {
        let files = [
            "import SwiftUI\n#Preview { Text(\"a\") }\n",
            "import SwiftUI\n#if DEBUG\n#Preview(\"named\") { Text(\"a\") }\n#endif\n",
            "import UIKit\n#Preview { UIViewController() }\n",
            "import AppKit\n#Preview { Gizmo() }\n",
            "import WidgetKit\n#Preview { Gizmo() }\n",
        ]
        for file in files {
            let url = try await Self.answer(beside: file)

            #expect(url.contains(Self.setApartTwo), "\(file): \(url)")
        }
    }

    /// Without an import that declares it, `#Preview` may be anyone's macro; another freestanding macro keeps the lines even under SwiftUI.
    @Test
    func aPreviewWithoutItsImportOrAnotherMacroKeepsTheLines() async throws {
        let files = [
            "#Preview { Text(\"a\") }\n",
            "import Foundation\n#Preview { Text(\"a\") }\n",
            "import SwiftUI\n#Stamp { Text(\"a\") }\n",
            "import SwiftUI\n#Stamp(\"a\")\n",
        ]
        for file in files {
            let url = try await Self.answer(beside: file)

            #expect(url.contains("\n    :3  | func home() -> URL? {"), "\(file): \(url)")
            #expect(!url.contains("bare outside every type"), "\(file): \(url)")
        }
    }

    /// An import in another file brings nothing into this one.
    @Test
    func anImportInAnotherFileDoesNotCountForAPreview() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("#Preview { Text(\"a\") }\n", to: "Sources/Lib/Entry.swift", in: root)
        try TestSources.write("import SwiftUI\n", to: "Sources/Lib/Other.swift", in: root)

        #expect(await BareNameOutsideTypes.expandsAtFileScope(paths: ["Sources/Lib/Entry.swift", "Sources/Lib/Other.swift"], under: root))
    }

    /// `Preview` is known under each module and no other freestanding macro is.
    @Test
    func theFreestandingMacrosKnownFollowTheImports() {
        #expect(AttributeScanner.nonIntroducingFreestandingMacros(importing: ["SwiftUI"]) == ["Preview"])
        #expect(AttributeScanner.nonIntroducingFreestandingMacros(importing: ["Foundation"]).isEmpty)
    }
}
