//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The git configuration a command is handed through the environment is appended after whatever the caller already put there.
struct GitConfigurationCarryTests {
    private static let rewrite = (key: "url.git@example.com:acme/.insteadof", value: "https://example.com/acme/")

    /// An environment with no configuration entries of its own gains a count and one key and value per entry, numbered from zero.
    @Test
    func entriesAreNumberedFromZeroWhenTheCallerSetNone() {
        let carried = ProcessEnvironment.carrying(gitConfiguration: [Self.rewrite], into: ["PATH": "/usr/bin"])

        #expect(carried == [
            "PATH": "/usr/bin",
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": Self.rewrite.key,
            "GIT_CONFIG_VALUE_0": Self.rewrite.value,
        ])
    }

    /// Entries the caller already set are kept where they are, and these are numbered on after them.
    @Test
    func theCallersEntriesAreKeptAndTheseAppendedAfterThem() {
        let source = [
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.askpass",
            "GIT_CONFIG_VALUE_0": "",
        ]
        let second = (key: "url.git@example.com:other/.insteadof", value: "https://example.com/other/")
        let carried = ProcessEnvironment.carrying(gitConfiguration: [Self.rewrite, second], into: source)

        #expect(carried == [
            "GIT_CONFIG_COUNT": "3",
            "GIT_CONFIG_KEY_0": "core.askpass",
            "GIT_CONFIG_VALUE_0": "",
            "GIT_CONFIG_KEY_1": Self.rewrite.key,
            "GIT_CONFIG_VALUE_1": Self.rewrite.value,
            "GIT_CONFIG_KEY_2": second.key,
            "GIT_CONFIG_VALUE_2": second.value,
        ])
    }

    /// With nothing to carry, or a count git itself would refuse, the environment is handed on untouched.
    @Test
    func nothingToCarryLeavesTheEnvironmentUntouched() {
        let source = ["PATH": "/usr/bin", "GIT_CONFIG_COUNT": "2"]

        #expect(ProcessEnvironment.carrying(gitConfiguration: [], into: source) == source)
        #expect(ProcessEnvironment.carrying(gitConfiguration: [Self.rewrite], into: ["GIT_CONFIG_COUNT": "many"]) == ["GIT_CONFIG_COUNT": "many"])
    }
}
