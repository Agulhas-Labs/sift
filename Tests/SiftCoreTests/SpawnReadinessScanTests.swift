//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers how the readiness marker is searched for as standard output arrives: across chunk boundaries, once, and without re-reading what was already searched.
struct SpawnReadinessScanTests {
    /// The streams over pipes that are never written to, so that every chunk is the one the test appends.
    private func streams(marker: String) -> (streams: SimulatorAccessibility.SpawnStreams, readiness: SimulatorAccessibility.SpawnStreams.Readiness) {
        let readiness = SimulatorAccessibility.SpawnStreams.Readiness(marker: Data(marker.utf8))
        return (SimulatorAccessibility.SpawnStreams(standardOutput: Pipe(), standardError: Pipe(), readiness: readiness), readiness)
    }

    /// Whether the readiness signal was raised since it was last taken.
    private func isSignalled(_ readiness: SimulatorAccessibility.SpawnStreams.Readiness) -> Bool {
        readiness.seen.wait(timeout: .now()) == .success
    }

    /// A marker whose halves arrive in different chunks is still seen.
    @Test
    func aMarkerSplitAcrossTwoChunksIsSeen() {
        let (streams, readiness) = streams(marker: "READY")
        defer { _ = streams.collected() }

        streams.append(Data("noise RE".utf8), isError: false)
        #expect(!isSignalled(readiness))
        streams.append(Data("ADY more".utf8), isError: false)

        #expect(isSignalled(readiness))
    }

    /// A marker that follows many chunks is signalled once, however much arrives after it.
    @Test
    func aMarkerAfterManyChunksIsSeenOnce() {
        let (streams, readiness) = streams(marker: "READY")
        defer { _ = streams.collected() }

        for _ in 0 ..< 200 {
            streams.append(Data("chatter ".utf8), isError: false)
        }
        #expect(!isSignalled(readiness))
        streams.append(Data("READY".utf8), isError: false)
        streams.append(Data("READY and more".utf8), isError: false)

        #expect(isSignalled(readiness))
        #expect(!isSignalled(readiness))
    }

    /// Each chunk costs the search its own length plus the marker's overlap, so the total grows linearly with the output.
    @Test
    func theSearchDoesNotReadOldBytesAgain() {
        let (streams, _) = streams(marker: "READY")
        defer { _ = streams.collected() }
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 100)
        let chunks = 500

        for _ in 0 ..< chunks {
            streams.append(chunk, isError: false)
        }

        // The first chunk reads itself; each later one itself and marker.count - 1 = 4 bytes before it.
        #expect(streams.scannedBytes == chunks * chunk.count + (chunks - 1) * 4, "\(streams.scannedBytes) bytes searched")
    }

    /// The slice a search reads is the new bytes and the marker's overlap before them, and nothing older.
    @Test(arguments: [1, 2, 5, 9])
    func theSearchWindowStartsAtTheOverlapBeforeTheNewBytes(markerLength: Int) {
        let window = SimulatorAccessibility.SpawnStreams.searchWindow(searchedThrough: 100, end: 160, markerLength: markerLength)

        #expect(window == (100 - (markerLength - 1)) ..< 160)
    }

    /// The overlap never reaches before the first byte.
    @Test
    func theSearchWindowDoesNotStartBeforeTheOutput() {
        let window = SimulatorAccessibility.SpawnStreams.searchWindow(searchedThrough: 2, end: 10, markerLength: 5)

        #expect(window == 0 ..< 10)
    }

    /// A marker that ended in bytes already searched lies outside the next window, so it cannot be found a second time.
    @Test
    func aMarkerInOldBytesIsOutsideTheNextWindow() {
        let output = Data("..READY..".utf8)
        let more = output + Data("abc".utf8)
        let window = SimulatorAccessibility.SpawnStreams.searchWindow(searchedThrough: output.count, end: more.count, markerLength: 5)

        #expect(more[window].range(of: Data("READY".utf8)) == nil)
    }

    /// A marker cut at any two points, so over three chunks, is seen.
    @Test(arguments: [[1, 2], [1, 3], [1, 4], [2, 3], [2, 4], [3, 4]])
    func aMarkerSplitAcrossThreeChunksIsSeen(cuts: [Int]) {
        let (streams, readiness) = streams(marker: "READY")
        defer { _ = streams.collected() }
        let marker = Array("READY".utf8)

        streams.append(Data("noise ".utf8) + Data(marker[..<cuts[0]]), isError: false)
        streams.append(Data(marker[cuts[0] ..< cuts[1]]), isError: false)
        #expect(!isSignalled(readiness))
        streams.append(Data(marker[cuts[1]...]) + Data("tail".utf8), isError: false)

        #expect(isSignalled(readiness))
    }

    /// A marker arriving a byte at a time, each chunk smaller than the marker, is seen on its last byte and not before.
    @Test(arguments: ["READY", "R", "RE", "a longer marker line"])
    func aMarkerArrivingOneByteAtATimeIsSeenOnItsLastByte(marker: String) {
        let (streams, readiness) = streams(marker: marker)
        defer { _ = streams.collected() }
        let bytes = Array(marker.utf8)

        for byte in "pre".utf8 {
            streams.append(Data([byte]), isError: false)
        }
        for byte in bytes.dropLast() {
            streams.append(Data([byte]), isError: false)
        }
        #expect(!isSignalled(readiness))
        streams.append(Data([bytes[bytes.count - 1]]), isError: false)

        #expect(isSignalled(readiness))
    }

    /// Bytes arriving after the marker has been seen are not searched at all.
    @Test
    func theSearchStopsOnceTheMarkerIsSeen() {
        let (streams, _) = streams(marker: "READY")
        defer { _ = streams.collected() }

        streams.append(Data("READY".utf8), isError: false)
        let atSighting = streams.scannedBytes
        streams.append(Data(repeating: UInt8(ascii: "x"), count: 1000), isError: false)

        #expect(streams.scannedBytes == atSighting)
    }
}
