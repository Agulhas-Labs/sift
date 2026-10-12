//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Pins that an Xcode project's collapsed prefix map does not depend on the order a dictionary happens to iterate in.
///
/// One dictionary iterates in one order for the life of its process, so each shape is built many times over with distinct names: unsorted, every copy would have to come out right by luck.
struct XcodeCollapseOrderTests {
    private static let copies = 8

    @Test
    func aParentLiftedBeforeItsOwnParentIsAlwaysKeptWhereSortedOrderKeepsIt() {
        var perFile: [String: String] = [:]
        var expected: [String: String] = [:]
        for copy in 0 ..< Self.copies {
            let module = "Module\(copy)"
            let top = "Top\(copy)"
            perFile["\(top)/Mid/own.swift"] = module
            perFile["\(top)/Mid/Left/one.swift"] = module
            perFile["\(top)/Mid/Right/two.swift"] = module
            perFile["\(top)/Side/three.swift"] = module
            // Sorted, the grandparent is lifted first and the parent is then lifted back in beside it.
            expected[top] = module
            expected["\(top)/Mid"] = module
        }

        #expect(XcodeProjectTargets.collapsed(perFile) == expected)
    }

    @Test
    func aMixedDirectoryResolvesToTheModuleOfItsLastSortedKey() {
        var perFile: [String: String] = [:]
        var expected: [String: String] = [:]
        for copy in 0 ..< Self.copies {
            let top = "Top\(copy)"
            perFile["\(top)/Folder"] = "Synced\(copy)"
            perFile["\(top)/Folder/inner.swift"] = "Inner\(copy)"
            perFile["\(top)/loose.swift"] = "Loose\(copy)"
            expected["\(top)/Folder"] = "Inner\(copy)"
            expected["\(top)/loose.swift"] = "Loose\(copy)"
        }

        #expect(XcodeProjectTargets.collapsed(perFile) == expected)
    }
}
