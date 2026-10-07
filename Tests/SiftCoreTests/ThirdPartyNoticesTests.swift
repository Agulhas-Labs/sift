//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// Covers the notices the bundle redistributes alongside the binary.
///
/// The binary links its dependencies statically, so every one of their license texts has to travel with it — and which dependencies those are is the resolution's to state, never a maintainer's to remember. The one that gets forgotten is the one that arrives transitively: `swift-lmdb` comes in with indexstore-db and links LMDB's compiled code, whose license requires a binary redistribution to reproduce its terms.
@Suite(.temporaryDirectories)
struct ThirdPartyNoticesTests {
    private static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent() // SiftCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // the repository root

    private static let checkouts = repository.appending(path: ".build/checkouts")

    /// The checkout a resolved identity was built from.
    ///
    /// `identity` is SwiftPM's lower-cased name, so `yams` has to find `Yams`.
    private static func checkout(for identity: String) -> URL? {
        try? FileManager.default.contentsOfDirectory(at: checkouts, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.lowercased() == identity }
    }

    /// Every license file in a checkout, by the rule the generator applies — spelled out here rather than shelled out to, so this is an independent statement of what is owed and not an echo of what was emitted.
    ///
    /// Name and extension both matter. `CopyrightHeader.swift`, in swift-syntax's code generator, matches the name and is source code; a license file is extensionless or plain text.
    private static func licenseFiles(in checkout: URL) -> [URL] {
        let walk = FileManager.default.enumerator(
            at: checkout,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return (walk?.allObjects as? [URL] ?? []).filter { url in
            let name = url.lastPathComponent.lowercased()
            guard ["license", "copyright", "notice"].contains(where: name.hasPrefix) else { return false }
            guard ["", "txt", "md", "rst"].contains(url.pathExtension.lowercased()) else { return false }
            guard relativePath(of: url, under: checkout).split(separator: "/").count <= 4 else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }.sorted { $0.path < $1.path }
    }

    private static func relativePath(of url: URL, under base: URL) -> String {
        String(url.resolvingSymlinksInPath().path.dropFirst(base.resolvingSymlinksInPath().path.count + 1))
    }

    /// Directories a license-shaped name would match, which are the shape both readers of that name are blind to.
    ///
    /// The REUSE convention puts a project's terms in `LICENSES/`, one file per SPDX identifier — `LICENSES/MIT.txt`, `LICENSES/Apache-2.0.txt`. Neither the generator's name pattern nor ``licenseFiles(in:)`` matches those filenames, so a dependency carrying one would have its terms omitted from a document that exists to reproduce them, and every check here would agree the document is complete — because both are the same rule, and a test that re-implements a rule inherits its blind spots exactly.
    private static func licenseDirectories(in checkout: URL) -> [URL] {
        let walk = FileManager.default.enumerator(at: checkout, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return (walk?.allObjects as? [URL] ?? []).filter { url in
            let name = url.lastPathComponent.lowercased()
            guard ["license", "copyright", "notice"].contains(where: name.hasPrefix) else { return false }
            guard relativePath(of: url, under: checkout).split(separator: "/").count <= 4 else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }.sorted { $0.path < $1.path }
    }

    /// The SwiftPM identities that carry a hand-written supplement.
    private static func supplementIdentities() -> [String] {
        let directory = repository.appending(path: "Distribution/third-party-supplements")
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// What SwiftPM actually resolved, which is what the built binary actually carries.
    private static func resolvedIdentities(sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
        let data = try Data(contentsOf: repository.appending(path: "Package.resolved"))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any], sourceLocation: sourceLocation)
        let pins = try #require(root["pins"] as? [[String: Any]], sourceLocation: sourceLocation)
        return pins.compactMap { $0["identity"] as? String }
    }

    /// Runs the generator the bundle runs.
    ///
    /// Named `checkouts` are passed the way the release scripts pass their build's; with none, the generator falls back to its default, the repository's `.build/checkouts` — which is this suite's own build.
    ///
    /// Its output goes to a file rather than a pipe: it is tens of kilobytes of license text, and a pipe that fills while nothing drains it deadlocks the wait.
    private static func notices(
        root: URL = repository,
        checkouts: URL? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String {
        let output = try TemporaryDirectory.make("notices").appending(path: "notices.txt")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }

        let handle = try FileHandle(forWritingTo: output)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [repository.appending(path: "Distribution/third-party-notices.sh").path, root.path] + (checkouts.map { [$0.path] } ?? [])
        process.standardOutput = handle
        try process.run()
        process.waitUntilExit()
        try handle.close()

        #expect(process.terminationStatus == 0, "the notices generator failed", sourceLocation: sourceLocation)
        return try String(contentsOf: output, encoding: .utf8)
    }

    /// Component name to license text, read back out of the generated file.
    private static func sections(of notices: String) -> [String: String] {
        let rule = "\(String(repeating: "=", count: 80))\n"
        // The split alternates from the preamble on: a heading, then the body it introduces.
        let parts = notices.components(separatedBy: rule).dropFirst()
        return stride(from: parts.startIndex, to: parts.endIndex - 1, by: 2).reduce(into: [:]) { sections, index in
            sections[parts[index].trimmingCharacters(in: .whitespacesAndNewlines)] = parts[index + 1]
        }
    }

    @Test
    func everyResolvedDependencyHasASection() throws {
        let sections = try Self.sections(of: Self.notices())

        let named = Set(sections.keys.map { $0.lowercased() })
        for identity in try Self.resolvedIdentities() {
            #expect(named.contains(identity.lowercased()), "no notice for \(identity)")
        }
    }

    /// The shape check: a section is a heading and enough text to be terms rather than a stub.
    ///
    /// It is deliberately weak and must not be read as the coverage claim — it stays green when indexstore-db's section carries the package's own license and none of LLVM Support's, because one present license is all it asks for. ``everyLicenseFileInAResolvedCheckoutReachesItsSection`` is the test that answers what is owed.
    @Test
    func everySectionCarriesTheLicenseTextAndTheFileItCameFrom() throws {
        let sections = try Self.sections(of: Self.notices())

        #expect(!sections.isEmpty)
        for (component, body) in sections {
            #expect(body.contains("---"), "\(component) names no license file")
            #expect(body.count > 500, "\(component) carries \(body.count) characters, too few to be a license")
        }
    }

    /// Every license the checkouts hold is reproduced, not just the first one found per package.
    ///
    /// A package's own terms sit at its root and the terms of what it vendors sit beside the vendored sources, and a package can have both: indexstore-db's root license is present *and* its `Sources/IndexStoreDB_LLVMSupport/LICENSE.TXT` carries Apache-2.0 with LLVM Exceptions, the legacy UIUC/NCSA terms, and a no-endorsement clause the root license does not grant. A generator that stops at the root whenever the root is non-empty never emits that file for a component the binary links. Asserting over what the checkouts hold rather than over what was emitted is what makes the next dependency bump unable to reopen it quietly.
    @Test
    func everyLicenseFileInAResolvedCheckoutReachesItsSection() throws {
        let sections = try Self.sections(of: Self.notices())

        for identity in try Self.resolvedIdentities() {
            let checkout = try #require(Self.checkout(for: identity), "no checkout for \(identity)")
            let section = try #require(sections.first { $0.key.lowercased() == identity }?.value, "no notice for \(identity)")
            let files = Self.licenseFiles(in: checkout)

            #expect(!files.isEmpty, "\(identity) has no license file in its checkout at all")
            for file in files {
                let relative = Self.relativePath(of: file, under: checkout)
                #expect(section.contains("--- \(relative) ---"), "\(identity)'s section does not name \(relative)")
                let terms = try String(contentsOf: file, encoding: .utf8)
                #expect(section.contains(terms), "\(identity)'s section omits the text of \(relative)")
            }
        }
    }

    /// A supplement is the one hand-written claim in a generated document, so it is checked rather than trusted.
    ///
    /// It cannot catch the gap the mechanism exists for: Yams vendors libyaml with its copyright headers stripped and no license file, so nothing derived from the resolution can know those terms are owed — a person has to notice. What this does catch is the two ways the claim rots afterwards: a supplement that stops being emitted, and one left behind by a dependency the resolution no longer names, which would ship a legal statement about code that is not in the binary.
    @Test
    func everySupplementIsReproducedUnderThePackageItTravelsIn() throws {
        let sections = try Self.sections(of: Self.notices())
        let resolved = try Set(Self.resolvedIdentities())
        let directory = Self.repository.appending(path: "Distribution/third-party-supplements")

        for identity in Self.supplementIdentities() {
            #expect(resolved.contains(identity), "a supplement for \(identity), which the resolution no longer names")
            let section = try #require(sections.first { $0.key.lowercased() == identity }?.value, "no notice for \(identity)")

            let files = try FileManager.default
                .contentsOfDirectory(at: directory.appending(path: identity), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "txt" }
            #expect(!files.isEmpty, "\(identity) has a supplement directory holding nothing")
            for file in files {
                let component = file.deletingPathExtension().lastPathComponent
                #expect(section.contains("--- supplement: \(component) ---"), "\(identity)'s section does not name the \(component) supplement")
                let terms = try String(contentsOf: file, encoding: .utf8)
                #expect(section.contains(terms), "\(identity)'s section omits the text of the \(component) supplement")
            }
        }
    }

    /// No resolved dependency lays its terms out in a shape this generator cannot see.
    ///
    /// Everything else here asks whether the document reproduces what the rule finds. This asks whether the rule is the right one, which nothing else can: the generator and ``licenseFiles(in:)`` implement the same rule, so a shape neither matches is a legal omission both would certify as complete. That is the LLVM Support omission above, one filename away — the terms are in the checkout, the search does not reach them, and the document says nothing is missing.
    ///
    /// A tripwire rather than a widened rule. Handling REUSE means emitting whatever a `LICENSES/` directory happens to hold, under a rule no dependency here would exercise and nothing could check — a guess about a legal document. Refusing is the honest half: the day a dependency arrives with one, this says so and a person decides what the notices owe, instead of the notices quietly owing it.
    @Test
    func noResolvedCheckoutLaysItsTermsOutInAShapeTheRuleCannotSee() throws {
        for identity in try Self.resolvedIdentities() {
            let checkout = try #require(Self.checkout(for: identity), "no checkout for \(identity)")
            let directories = Self.licenseDirectories(in: checkout).map { Self.relativePath(of: $0, under: checkout) }

            #expect(directories.isEmpty, "\(identity) carries \(directories) — a directory of terms, which the generator's file rule never reaches")
        }

        // The detection itself, against a checkout laid out the way the rule is blind to. Without this
        // the assertion above passes on a repository where no dependency has ever had one, which says
        // nothing about whether it would notice.
        let synthetic = try TestSources.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: synthetic) }
        try FileManager.default.createDirectory(at: synthetic.appending(path: "LICENSES"), withIntermediateDirectories: true)
        try "MIT terms\n".write(to: synthetic.appending(path: "LICENSES/MIT.txt"), atomically: true, encoding: .utf8)

        #expect(Self.licenseDirectories(in: synthetic).count == 1)
        #expect(Self.licenseFiles(in: synthetic).isEmpty, "the file rule matched a REUSE layout after all — this tripwire is the wrong shape")
    }

    /// The checkouts read are the ones named, not whichever `.build/checkouts` the repository happens to hold — including a stale one an old unscoped build left behind.
    ///
    /// The release scripts build into a scratch path of their own, so the checkouts the binary was linked against sit under it, and `.build/checkouts` is either absent — a fresh clone — or another build's resolution, which is the more serious of the two failures this fixes: the notices would then ship terms copied from a checkout the binary was never linked against. Absent alone does not pin that — a rewrite like `[ -d "$CHECKOUTS" ] || CHECKOUTS="$2"` still passes every test that only ever hands the script a root with no `.build` at all. So the fixture plants an *empty* `.build/checkouts` here, the shape of the stale case without needing a real second resolution to go wrong against, and the generator still has to produce exactly what the default run produces: the same resolution read from the same named checkouts is the same document, whatever sits at the unscoped default.
    @Test
    func theNamedCheckoutsWinOverAStaleCheckoutsDirectory() throws {
        let root = try TestSources.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: Self.repository.appending(path: "Package.resolved"), to: root.appending(path: "Package.resolved"))
        try FileManager.default.createDirectory(at: root.appending(path: "Distribution"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Self.repository.appending(path: "Distribution/third-party-supplements"),
            to: root.appending(path: "Distribution/third-party-supplements")
        )
        // Empty, not absent: this is the stale-checkout failure, and a script that fell back to
        // whatever is here would find nothing under it and fail loudly rather than reading it quietly.
        try FileManager.default.createDirectory(at: root.appending(path: ".build/checkouts"), withIntermediateDirectories: true)

        let named = try Self.notices(root: root, checkouts: Self.checkouts)
        let defaulted = try Self.notices()

        #expect(!defaulted.isEmpty)
        #expect(named.utf8.elementsEqual(defaulted.utf8), "\(named.utf8.count) bytes from the named checkouts, \(defaulted.utf8.count) from the default")
    }

    /// An explicit empty checkouts argument is refused, not read as "no argument".
    ///
    /// `${2:-...}` falls back to the default on an empty string exactly as it does on an unset one, so a caller that computed an empty path would get someone else's checkouts in silence — the same failure this whole fix removes, reintroduced one shell parameter expansion away. `${2-...}` falls back only when unset, so an explicit empty argument reaches the `[ -d ]` check and is refused by name.
    @Test
    func anEmptyCheckoutsArgumentIsRefused() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [Self.repository.appending(path: "Distribution/third-party-notices.sh").path, Self.repository.path, ""]
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        let output = String(data: sink.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        #expect(process.terminationStatus != 0, "an empty checkouts argument was accepted instead of refused")
        #expect(output.contains("no checkouts at"), "the refusal did not name what it was handed: \(output)")
    }

    /// Every `Distribution/*.sh` script that calls the notices generator — found by what it calls, not by name, so a future shipping script is covered the day it starts calling the generator rather than the day someone remembers to add it here.
    private static func scriptsCallingTheNoticesGenerator() throws -> [URL] {
        let distribution = repository.appending(path: "Distribution")
        let walk = FileManager.default.enumerator(at: distribution, includingPropertiesForKeys: nil)
        let scripts = (walk?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "sh" && $0.lastPathComponent != "third-party-notices.sh" }
        return try scripts
            .filter { try String(contentsOf: $0, encoding: .utf8).contains("third-party-notices.sh") }
            .sorted { $0.path < $1.path }
    }

    /// Each script that ships the binary hands the generator the checkouts of the build it has just made.
    ///
    /// Both build with `--scratch-path "$SCRATCH"`, so SwiftPM resolves their dependencies under that path; left to its default, the generator reads `.build/checkouts`, which on a fresh clone does not exist and elsewhere holds whatever an unscoped build resolved last. The release build takes minutes, so this pins the scripts' text rather than running them.
    ///
    /// The checkouts argument is matched against the harmless spellings of `$SCRATCH/checkouts` — quoted, braced, or not — rather than one exact string, so a rewrite that keeps the same value does not fail this for reasons that have nothing to do with what it checks.
    @Test
    func everyShippingScriptReadsTheNoticesFromTheCheckoutsItBuilt() throws {
        let scripts = try Self.scriptsCallingTheNoticesGenerator()
        // A glob that matched nothing would make every assertion below vacuously true, so the discovery
        // itself is checked against the two callers known to exist today.
        #expect(scripts.map(\.lastPathComponent).sorted() == ["build.sh", "make-dist.sh"], "expected to discover make-dist.sh and npm/build.sh, found \(scripts.map(\.lastPathComponent))")

        let checkoutsSpellings = ["$SCRATCH/checkouts", "\"$SCRATCH\"/checkouts", "${SCRATCH}/checkouts", "\"${SCRATCH}\"/checkouts"]

        for script in scripts {
            let text = try String(contentsOf: script, encoding: .utf8)
            let commands = text.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("#") }

            let builds = try #require(
                commands.firstIndex { $0.hasPrefix("swift build") && $0.contains(#"--scratch-path "$SCRATCH""#) },
                "\(script.lastPathComponent) calls the generator without a scoped build first"
            )
            let generates = try #require(commands.firstIndex { $0.contains("third-party-notices.sh") })

            #expect(builds < generates, "\(script.lastPathComponent) generates the notices before its scoped build runs")
            let call = commands[generates]
            #expect(
                checkoutsSpellings.contains { call.contains($0) },
                "\(script.lastPathComponent) does not hand the generator its own scratch checkouts: \(call)"
            )
        }
    }
}
