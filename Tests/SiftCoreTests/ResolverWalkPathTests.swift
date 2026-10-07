//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

struct ResolverWalkPathTests {
    @Test func derivedPathsEqualTheFilesystemsForEveryEntry() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent("walkpath-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: base) }
        let real = base.appendingPathComponent("real")
        try fileManager.createDirectory(at: real.appendingPathComponent("Mixed/inner"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: real.appendingPathComponent("target"), withIntermediateDirectories: true)
        try Data().write(to: real.appendingPathComponent("Mixed/inner/File.txt"))
        try Data().write(to: real.appendingPathComponent("target/inside.txt"))
        try Data().write(to: real.appendingPathComponent("plain.txt"))
        try fileManager.createSymbolicLink(at: real.appendingPathComponent("linkdir"), withDestinationURL: real.appendingPathComponent("target"))
        try fileManager.createSymbolicLink(at: real.appendingPathComponent("linkfile"), withDestinationURL: real.appendingPathComponent("plain.txt"))
        let viaLink = base.appendingPathComponent("rootlink")
        try fileManager.createSymbolicLink(at: viaLink, withDestinationURL: real)

        var checked = 0
        var frontier = [(logical: viaLink, base: CanonicalPath.of(viaLink.resolvingSymlinksInPath().path))]
        while let (logical, base) = frontier.popLast() {
            let listed = try fileManager.contentsOfDirectory(
                at: logical.resolvingSymlinksInPath(),
                includingPropertiesForKeys: [.isSymbolicLinkKey]
            )
            for entry in listed {
                let name = entry.lastPathComponent
                let entryLogical = logical.appendingPathComponent(name)
                let symbolic = try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink
                let derived = BuildFileScan.derivedPath(
                    of: entryLogical, name: name, parentCanonical: base, isSymbolicLink: symbolic
                )
                #expect(derived == CanonicalPath.of(entryLogical.path))
                checked += 1
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: entryLogical.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    let entryBase = symbolic == false ? derived : CanonicalPath.of(entryLogical.resolvingSymlinksInPath().path)
                    frontier.append((entryLogical, entryBase))
                }
            }
        }

        #expect(checked >= 9)
    }

    @Test func aMixedCaseSpellingIsTakenFromTheListingNotTheAsk() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent("walkcase-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: base) }
        try fileManager.createDirectory(at: base.appendingPathComponent("Upper"), withIntermediateDirectories: true)
        let parent = CanonicalPath.of(base.path)
        let entry = try #require(fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).first)
        let derived = BuildFileScan.derivedPath(
            of: entry, name: entry.lastPathComponent, parentCanonical: parent, isSymbolicLink: false
        )

        #expect(derived == parent + "/Upper")
        #expect(derived == CanonicalPath.of(entry.path))
    }
}
