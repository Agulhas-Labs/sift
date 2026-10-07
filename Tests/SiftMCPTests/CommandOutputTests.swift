//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

struct CommandOutputTests {
    private static let markedLine = "\(SourcePassthrough.partMarker)second.swift — module: TestDemo"

    @Test
    func plainOutputReceivesNoPartMarker() {
        let recorded = RecordedOutput(keepsPartMarker: false)
        recorded.output.emit(Self.markedLine)

        #expect(!recorded.printed.contains(SourcePassthrough.partMarker))
    }

    @Test
    func outputThatKeepsTheMarkerReceivesIt() {
        let recorded = RecordedOutput(keepsPartMarker: true)
        recorded.output.emit(Self.markedLine)

        #expect(recorded.printed.contains(SourcePassthrough.partMarker))
    }

    @Test
    func aTerminalPassesRawBytesThroughUndecoded() {
        let recorded = RecordedOutput(keepsPartMarker: false)
        let checkmark = Data([0xE2, 0x9C, 0x94]) // ✔, split across two chunks below.

        recorded.output.emitRaw(Data([0x61, 0xFF, 0x62]))
        recorded.output.emitRaw(checkmark.prefix(2))
        recorded.output.emitRaw(checkmark.suffix(1))

        #expect(recorded.printedBytes == Data([0x61, 0xFF, 0x62]) + checkmark)
    }
}
