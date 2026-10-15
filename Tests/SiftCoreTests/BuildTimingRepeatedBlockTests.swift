//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// The native build system prints a batch frontend job's output under each file heading of the batch; the parser reads that output once.
struct BuildTimingRepeatedBlockTests {
    private static var slow: String {
        "/Users/dev/Widget/Sources/Widget/Slow.swift"
    }

    private static var ledger: String {
        "/Users/dev/Widget/Sources/Widget/Ledger.swift"
    }

    private static func block(_ milliseconds: String) -> String {
        """
        \(milliseconds)ms\t\(slow):4:10\tinstance method Widget.(file).Ledger.total()@\(slow):4:10
        \(milliseconds)ms\t\(ledger):9:12
        """
    }

    @Test
    func aBlockPrintedUnderThreeConsecutiveFileHeadingsIsReadOnce() {
        let block = Self.block("7.42")
        let output = """
        [1/3] Compiling Widget A.swift
        \(block)
        [2/3] Compiling Widget B.swift
        \(block)
        [3/3] Compiling Widget C.swift
        \(block)
        """

        #expect(BuildTimingParser.timings(in: output).count == 2)
    }

    @Test
    func theSameSiteInTwoDifferentBlocksIsReadTwice() {
        let output = """
        [1/2] Compiling Widget A.swift
        \(Self.block("7.42"))
        [2/2] Compiling Widget B.swift
        \(Self.block("3.10"))
        """

        let timings = BuildTimingParser.timings(in: output)

        #expect(timings.count == 4)
        #expect(timings.map(\.milliseconds) == [7.42, 7.42, 3.10, 3.10])
    }

    @Test
    func anOutputWithNoRepeatedBlockReadsEveryLineInOrder() {
        let output = """
        [1/2] Compiling Widget A.swift
        1.00ms\t\(Self.slow):1:1
        2.00ms\t\(Self.slow):2:1
        [2/2] Compiling Widget B.swift
        3.00ms\t\(Self.ledger):3:1
        """

        #expect(BuildTimingParser.timings(in: output).map(\.milliseconds) == [1.0, 2.0, 3.0])
    }
}
