//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// Until the Homebrew tap and the npm package exist, every command in the README and the Guide that installs or launches through them says it is not published yet, so no reader copies a line that cannot work.
///
/// Delete this suite, and the markers, once each channel has been published and verified on a clean machine.
struct UnpublishedInstallLinesTests {
    /// What a command line uses a channel that is not published yet by.
    static let unpublishedChannels = ["brew install agulhas-labs/tap/", "npx -y @agulhas-labs/sift"]

    /// The comment each such command line ends with.
    static var marker: String {
        "# not published yet"
    }

    /// The documents a reader installs from.
    static let documents = ["README.md", "Docs/Guide.md"]

    /// Every fenced command line naming an unpublished channel ends with the marker, and there is at least one such line in each document.
    @Test(arguments: documents)
    func everyUnpublishedInstallCommandIsMarked(_ document: String) throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent() // SiftMCPTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(document), encoding: .utf8)
        var inFence = false
        var commands: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                inFence.toggle()
            } else if inFence, Self.unpublishedChannels.contains(where: { line.contains($0) }) {
                commands.append(line)
            }
        }

        #expect(!commands.isEmpty, "\(document) shows no install command through an unpublished channel")
        for command in commands {
            #expect(command.hasSuffix(Self.marker), "\(document): \(command)")
        }
    }

    /// With every packaged channel marked, each document still shows the one route that works today: a source build from the public repository.
    @Test(arguments: documents)
    func everyInstallDocumentShowsTheSourceBuild(_ document: String) throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent() // SiftMCPTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(document), encoding: .utf8)
        var inFence = false
        var fenced: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                inFence.toggle()
            } else if inFence {
                fenced.append(line)
            }
        }

        #expect(fenced.contains("git clone https://github.com/Agulhas-Labs/sift.git"), "\(document) shows no clone")
        #expect(fenced.contains("swift build -c release"), "\(document) shows no source build")
    }
}
