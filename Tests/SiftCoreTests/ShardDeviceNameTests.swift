//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers the one name a sharded run's simulators carry, in both directions — and the names that merely look like it.
struct ShardDeviceNameTests {
    /// Composing and parsing are the same rule read twice, so a name this tool writes is a name it recognises.
    @Test
    func aComposedNameParsesBackToWhatComposedIt() throws {
        let name = ShardDeviceName(prefix: "a1b2c3", runID: "0f9e8d7c", index: 2)

        #expect(name.text == "sift-a1b2c3-0f9e8d7c-2")
        let parsed = try #require(ShardDeviceName(parsing: name.text))
        #expect(parsed == name)
    }

    /// A device somebody duplicated by hand carries the whole of one of these names and a suffix, and deleting it would be deleting a device this tool never created.
    @Test
    func aNameWithAnythingAfterTheIndexIsNotOneOfOurs() {
        #expect(ShardDeviceName(parsing: "sift-a1b2c3-0f9e8d7c-0-copy") == nil)
        #expect(ShardDeviceName(parsing: "sift-a1b2c3-0f9e8d7c-0 copy") == nil)
    }

    /// Every component is checked, because each one wrong is a different device belonging to somebody else.
    @Test
    func anythingNotExactlyTheShapeParsesToNothing() {
        for text in [
            "sift-a1b2c3-0f9e8d7c",
            "sift-a1b2c-0f9e8d7c-0",
            "sift-a1b2c3d-0f9e8d7c-0",
            "sift-A1B2C3-0f9e8d7c-0",
            "sift-a1b2c3-0f9e8d7-0",
            "sift-a1b2c3-0f9e8d7c-00",
            "sift-a1b2c3-0f9e8d7c--1",
            "sift-a1b2c3-0f9e8d7c-x",
            "sifty-a1b2c3-0f9e8d7c-0",
            "iPhone 17",
            "",
        ] {
            #expect(ShardDeviceName(parsing: text) == nil, "\(text) is not a name this tool wrote")
        }
    }

    /// Ten shards and more, so the index is read as a number rather than as one character.
    @Test
    func anIndexOfSeveralDigitsIsStillAnIndex() throws {
        let parsed = try #require(ShardDeviceName(parsing: "sift-a1b2c3-0f9e8d7c-12"))

        #expect(parsed.index == 12)
    }
}
