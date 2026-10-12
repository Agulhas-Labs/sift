//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A wrapper attribute site a stale build recorded is counted per file against that build's lines, since an edit above it moves today's line from the one recorded.
@Suite(.temporaryDirectories)
struct WhereSetAsideMovedTests {
    /// Two attributes no store records, in a file whose one set-aside initializer call matches neither, count one site; an attribute in a file with no set-aside line counts none.
    @Test
    func aFileCountsUpToItsSetAsideLinesAndNoneWithoutOne() async throws {
        let found = try await Self.find { _ in ["Sources/Lib/Box.swift:9"] }

        #expect(found.setAside.line?.hasPrefix("1 site in Sources/Lib/Box.swift set aside") == true, "\(found.setAside.line ?? "nil")")
    }

    /// A set-aside line recording only the wrapper type, with no initializer call, may be any other use of the type, so it stands for no moved attribute.
    @Test
    func aTypeOnlySetAsideLineStandsForNoMovedSite() async throws {
        let found = try await Self.find { $0.kind == .initializer ? [] : ["Sources/Lib/Box.swift:9"] }

        #expect(found.setAside.line == nil, "\(found.setAside.line ?? "nil")")
    }

    /// The wrapper sites of `Clamp`, whose attributes in `Box.swift` and `Crate.swift` no store records, with `setAside` giving each symbol's set-aside lines.
    private static func find(sourceLocation: SourceLocation = #_sourceLocation, setAside: (SymbolRow) -> Set<String>) async throws -> WrapperAttributeSites {
        let root = try TestSources.makeTempRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let clamp = "@propertyWrapper struct Clamp {\n    var wrappedValue: Int\n    init(wrappedValue: Int) { self.wrappedValue = wrappedValue }\n}\n"
        try TestSources.write("struct Box {\n    @Clamp var a = 1\n    @Clamp var b = 2\n}\n", to: "Sources/Lib/Box.swift", in: root)
        try TestSources.write("struct Crate {\n    @Clamp var c = 3\n}\n", to: "Sources/Lib/Crate.swift", in: root)
        let store = try TestSources.makeStore()
        try store.replaceFiles([TestSources.parsed(clamp, path: "Sources/Lib/Clamp.swift", in: root)]) { _ in ("Lib", false) }
        let initializers = try store.symbols(inFile: "Sources/Lib/Clamp.swift").filter { $0.kind == .initializer }
        let scanner = CallSiteScanner(repoRoot: root, enumerator: FileEnumerator(repoRoot: root, config: SiftConfig()))

        let found = try await WrapperAttributeSites.find(
            for: initializers,
            in: store,
            callSites: { await scanner.callSites(named: $0) },
            recorded: { _ in [] },
            setAside: setAside,
            modifiedSinceBuild: { _ in false }
        )

        #expect(!initializers.isEmpty, sourceLocation: sourceLocation)
        return found
    }

    /// A moved wrapper site stands as a set-aside line no symbol counted, so the merged tally does not fold it into that symbol's reference.
    @Test
    func aMovedSiteStandsAsALineNoSymbolCounted() {
        var own = SetAsideSites()
        own.note(ofUSR: "s:x", inStore: "one", ["/r/A.swift": [3: 1]]) { $0.replacingOccurrences(of: "/r/", with: "") }
        var wrapper = SetAsideSites()
        wrapper.noteWrapperSites(path: "A.swift", unexplained: [10], setAside: [3, 7])
        own.merge(wrapper)

        #expect(own.line?.hasPrefix("2 sites in A.swift") == true, "\(own.line ?? "nil")")
    }

    /// A file with more set-aside lines than attributes no store records counts only those attributes.
    @Test
    func aFileCountsNoMoreThanItsUnexplainedAttributes() {
        var wrapper = SetAsideSites()
        wrapper.noteWrapperSites(path: "A.swift", unexplained: [10], setAside: [3, 7, 12])

        #expect(wrapper.line?.hasPrefix("1 site in A.swift") == true, "\(wrapper.line ?? "nil")")
    }
}
