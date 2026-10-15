//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a unit whose bytes state a count or a width no unit a toolchain writes has: the reader throws, so the whole unit records nothing and `status` falls back to the ledger's own dating rather than trapping on the conversion or the arithmetic.
///
/// Each crafted part follows a unit that reads on its own, so a unit reading as empty is the throw, not a part read past.
struct IndexUnitMalformedTests {
    /// A block header stating an abbreviation width of 2^63, past an `Int`.
    @Test
    func aBlockWidthPastAnIntIsMalformed() {
        let crafted = IndexUnitFixture.bits { writer in
            writer.emit(1, width: 2)
            writer.vbr(12, width: 8)
            writer.vbr(1 << 63, width: 4)
        }

        #expect(Self.paths(followedBy: crafted).isEmpty)
    }

    /// A blob stating a length of 2^63 bytes, past an `Int`.
    @Test
    func aBlobLengthPastAnIntIsMalformed() {
        #expect(Self.paths(followedBy: Self.blob(stating: 1 << 63)).isEmpty)
    }

    /// A blob stating a length of 2^62 bytes, an `Int` whose count of bits is not.
    @Test
    func aBlobLengthWhoseBitsOverflowIsMalformed() {
        #expect(Self.paths(followedBy: Self.blob(stating: 1 << 62)).isEmpty)
    }

    /// An abbreviation whose fixed-width operand states a width of 2^63, past an `Int`.
    @Test
    func anOperandWidthPastAnIntIsMalformed() {
        let crafted = IndexUnitFixture.bits { writer in
            writer.block(12) { block in
                block.emit(2, width: 3)
                block.vbr(1, width: 5)
                block.emit(0, width: 1)
                block.emit(1, width: 3)
                block.vbr(1 << 63, width: 5)
            }
        }

        #expect(Self.paths(followedBy: crafted).isEmpty)
    }

    /// An abbreviation of a literal code and an array of literals, used over and over: each use takes a few bits and decodes hundreds of values, which repeated would hold far more values than the unit has bits, so the reader stops at one value per bit.
    @Test
    func recordsDecodingMoreValuesThanTheUnitHasBitsAreMalformed() {
        let crafted = IndexUnitFixture.bits { writer in
            writer.block(12) { block in
                block.emit(2, width: 3)
                block.vbr(3, width: 5)
                block.emit(1, width: 1)
                block.vbr(4, width: 8)
                block.emit(0, width: 1)
                block.emit(3, width: 3)
                block.emit(1, width: 1)
                block.vbr(7, width: 8)
                for _ in 0 ..< 64 {
                    block.emit(4, width: 3)
                    block.vbr(200, width: 6)
                }
            }
        }

        #expect(Self.paths(followedBy: crafted).isEmpty)
    }

    private static let valid = IndexUnitFixture.unit(workingDirectory: "/work", paths: [IndexUnitFixture.Path(kind: 1, directory: "Sources/Lib", file: "Caller.swift")])

    /// The paths the unit reading `/work/Sources/Lib/Caller.swift` records once `crafted` follows it.
    private static func paths(followedBy crafted: Data, sourceLocation: SourceLocation = #_sourceLocation) -> [String] {
        #expect(IndexUnitPaths.of(valid) == ["/work/Sources/Lib/Caller.swift"], sourceLocation: sourceLocation)
        return IndexUnitPaths.of(valid + crafted)
    }

    /// A paths block defining an abbreviation of a literal code and a blob, then a record of it stating a blob of `count` bytes.
    private static func blob(stating count: UInt64) -> Data {
        IndexUnitFixture.bits { writer in
            writer.block(12) { block in
                block.emit(2, width: 3)
                block.vbr(2, width: 5)
                block.emit(1, width: 1)
                block.vbr(5, width: 8)
                block.emit(0, width: 1)
                block.emit(5, width: 3)
                block.emit(4, width: 3)
                block.vbr(count, width: 6)
            }
        }
    }
}
