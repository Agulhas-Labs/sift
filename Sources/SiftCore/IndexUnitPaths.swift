//
// Copyright © Agulhas Labs
//

import Foundation

/// The absolute paths an index-store unit file records, read from its bytes rather than through an opened store.
///
/// A unit is an LLVM bitstream after the four bytes `IDXU`. Its info block holds the build's working directory and SDK root; its paths block holds one record per path — a prefix kind (none, the working directory, the SDK root), the directory after that prefix and the file name, each an offset and a length into one buffer of path text — and that buffer. SwiftPM (native or `swift-build`) and Xcode all write it so; they differ only in the working directory and in which kind a source directory gets (Xcode records one outside its working directory whole, as kind none). Only those two blocks are read, the rest skipped by their stored lengths, and a unit that does not read as this shape records nothing.
struct IndexUnitPaths {
    /// The paths the unit `data` records, each joined from its prefix, directory and file name as the store's own reader joins them; empty when `data` is not a unit this can read.
    static func of(_ data: Data) -> [String] {
        guard data.starts(with: Array("IDXU".utf8)), let parts = try? Parts.read(from: BitReader(bytes: Array(data), bit: 32)) else {
            return []
        }
        return parts.paths
    }
}

private extension IndexUnitPaths {
    /// The block and record numbers a unit file uses, as the toolchain's index writer defines them.
    struct Number {
        static let blockInfo: UInt64 = 0
        static let infoBlock: UInt64 = 9
        static let pathsBlock: UInt64 = 12
        static let setBlockID: UInt64 = 1
        static let unitInfo: UInt64 = 1
        static let unitPath: UInt64 = 4
        static let unitPathBuffer: UInt64 = 5
        static let workingDirectoryKind: UInt64 = 1
        static let sdkRootKind: UInt64 = 2
    }

    struct Malformed: Error {}

    /// One record: its code, its fields after the code, and its blob where its abbreviation carries one.
    struct Record {
        let code: UInt64
        let fields: [UInt64]
        let blob: ArraySlice<UInt8>?
    }

    /// One operand of an abbreviation, the bitstream's declared encoding of a record's next field.
    enum Operand {
        case literal(UInt64)
        case fixed(Int)
        case vbr(Int)
        case array
        case char6
        case blob
    }

    /// The pieces of a unit the paths are joined from: the info record's fields, each path record's fields, and the buffer they all point into.
    struct Parts {
        var info: [UInt64] = []
        var pathRecords: [[UInt64]] = []
        var buffer: ArraySlice<UInt8> = []

        /// The paths, each joined as `prefix/directory/fileName` with empty parts left out; a record pointing outside the buffer is left out.
        var paths: [String] {
            let workingDirectory = info.count > 2 ? text(at: info[1], count: info[2]) : nil
            let sdkRoot = info.count > 6 ? text(at: info[5], count: info[6]) : nil
            return pathRecords.compactMap { fields in
                guard fields.count >= 5, let directory = text(at: fields[1], count: fields[2]), let file = text(at: fields[3], count: fields[4]) else {
                    return nil
                }
                let prefix: String? = switch fields[0] {
                case Number.workingDirectoryKind: workingDirectory
                case Number.sdkRootKind: sdkRoot
                default: ""
                }
                return prefix.map { Self.joined([$0, directory, file]) }
            }
        }

        /// Walks the top-level blocks, reading the info and paths blocks and skipping every other one by its length.
        static func read(from start: BitReader) throws -> Self {
            var reader = start
            var parts = Self()
            var blockInfo: [UInt64: [[Operand]]] = [:]
            while !reader.atEnd {
                guard try reader.fixed(2) == 1 else { throw Malformed() }
                let block = try reader.vbr(8)
                let width = try reader.int(reader.vbr(4))
                reader.alignTo32()
                let words = try reader.int(reader.fixed(32))
                guard (1 ... 32).contains(width) else { throw Malformed() }
                guard [Number.blockInfo, Number.infoBlock, Number.pathsBlock].contains(block) else {
                    try reader.skip(words: words)
                    continue
                }
                for record in try reader.records(width: width, abbreviations: blockInfo[block] ?? [], into: &blockInfo, defining: block == Number.blockInfo) {
                    parts.take(record, in: block)
                }
            }
            return parts
        }

        mutating func take(_ record: Record, in block: UInt64) {
            switch (block, record.code) {
            case (Number.infoBlock, Number.unitInfo): info = record.fields
            case (Number.pathsBlock, Number.unitPath): pathRecords.append(record.fields)
            case (Number.pathsBlock, Number.unitPathBuffer): buffer = record.blob ?? []
            default: break
            }
        }

        private func text(at offset: UInt64, count: UInt64) -> String? {
            guard let offset = Int(exactly: offset), let count = Int(exactly: count), offset <= buffer.count, count <= buffer.count - offset else { return nil }
            let start = buffer.startIndex + offset
            return String(bytes: buffer[start ..< start + count], encoding: .utf8)
        }

        private static func joined(_ parts: [String]) -> String {
            parts.filter { !$0.isEmpty }.reduce(into: "") { path, part in
                path += path.isEmpty || path.hasSuffix("/") ? part : "/" + part
            }
        }
    }

    /// A position in a bitstream's bits, read least significant bit first, as the format stores them.
    ///
    /// Every count and width is a value the file states, so each is converted only where it fits an `Int` and compared with the bits left before any arithmetic on it: a unit this does not read as its shape throws rather than trapping, whatever its bytes say.
    struct BitReader {
        let bytes: [UInt8]
        var bit: Int
        /// How many field values the records read so far decoded.
        ///
        /// Each value takes at least a bit of the unit, but for the literal code an abbreviated record's id already paid for, so a unit a toolchain writes never decodes more than it has bits; a crafted abbreviation of literals or zero-width fields, which take none, would otherwise repeat them without bound.
        private var decoded = 0

        init(bytes: [UInt8], bit: Int) {
            self.bytes = bytes
            self.bit = bit
        }

        var atEnd: Bool {
            remaining == 0
        }

        /// The bits after the current position, none once an alignment has passed the end.
        private var remaining: Int {
            max(0, bytes.count * 8 - bit)
        }

        /// `value` as an `Int`, throwing where it does not fit one.
        func int(_ value: UInt64) throws -> Int {
            guard let converted = Int(exactly: value) else { throw Malformed() }
            return converted
        }

        mutating func fixed(_ width: Int) throws -> UInt64 {
            guard (0 ... 64).contains(width), width <= remaining else { throw Malformed() }
            var value: UInt64 = 0
            var taken = 0
            while taken < width {
                let offset = bit & 7
                let count = min(8 - offset, width - taken)
                let chunk = (UInt64(bytes[bit >> 3]) >> UInt64(offset)) & ((1 << UInt64(count)) - 1)
                value |= chunk << UInt64(taken)
                taken += count
                bit += count
            }
            return value
        }

        mutating func vbr(_ width: Int) throws -> UInt64 {
            guard (2 ... 32).contains(width) else { throw Malformed() }
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let chunk = try fixed(width)
                value |= (chunk & ((1 << UInt64(width - 1)) - 1)) << shift
                guard chunk >> UInt64(width - 1) == 1 else { return value }
                shift += UInt64(width - 1)
                guard shift < 64 else { throw Malformed() }
            }
        }

        mutating func alignTo32() {
            bit = (bit + 31) & ~31
        }

        mutating func skip(words count: Int) throws {
            guard count >= 0, count <= remaining / 32 else { throw Malformed() }
            bit += count * 32
        }

        /// The records of the block just entered, up to its end, any block nested in it skipped; in the block-info block, `defining` files each abbreviation under the block its last `SETBID` named instead.
        mutating func records(width: Int, abbreviations inherited: [[Operand]], into blockInfo: inout [UInt64: [[Operand]]], defining: Bool) throws -> [Record] {
            var abbreviations = inherited
            var records: [Record] = []
            var target: UInt64?
            while true {
                let id = try fixed(width)
                switch id {
                case 0:
                    alignTo32()
                    return records
                case 1:
                    _ = try vbr(8)
                    _ = try vbr(4)
                    alignTo32()
                    try skip(words: int(fixed(32)))
                case 2:
                    let abbreviation = try abbreviation()
                    if defining {
                        guard let target else { throw Malformed() }
                        blockInfo[target, default: []].append(abbreviation)
                    } else {
                        abbreviations.append(abbreviation)
                    }
                case 3:
                    let code = try vbr(6)
                    let count = try vbr(6)
                    try decode(count)
                    let fields = try (0 ..< count).map { _ in try vbr(6) }
                    if defining, code == Number.setBlockID {
                        target = fields.first
                    }
                    records.append(Record(code: code, fields: fields, blob: nil))
                default:
                    let index = try int(id - 4)
                    guard index < abbreviations.count else { throw Malformed() }
                    try records.append(record(abbreviations[index]))
                }
            }
        }

        private mutating func abbreviation() throws -> [Operand] {
            let count = try vbr(5)
            guard count <= UInt64(remaining) else { throw Malformed() }
            return try (0 ..< count).map { _ in
                if try fixed(1) == 1 {
                    return try .literal(vbr(8))
                }
                switch try fixed(3) {
                case 1: return try .fixed(int(vbr(5)))
                case 2: return try .vbr(int(vbr(5)))
                case 3: return .array
                case 4: return .char6
                case 5: return .blob
                default: throw Malformed()
                }
            }
        }

        private mutating func record(_ abbreviation: [Operand]) throws -> Record {
            var values: [UInt64] = []
            var blob: ArraySlice<UInt8>?
            var index = 0
            while index < abbreviation.count {
                switch abbreviation[index] {
                case .array:
                    guard index + 1 < abbreviation.count else { throw Malformed() }
                    let count = try vbr(6)
                    try decode(count)
                    let element = abbreviation[index + 1]
                    values += try (0 ..< count).map { _ in try scalar(element) }
                    index += 1
                case .blob:
                    let count = try int(vbr(6))
                    alignTo32()
                    guard bit <= bytes.count * 8, count <= remaining / 8 else { throw Malformed() }
                    blob = bytes[(bit >> 3) ..< (bit >> 3) + count]
                    bit += count * 8
                    alignTo32()
                case let operand:
                    try decode(1)
                    try values.append(scalar(operand))
                }
                index += 1
            }
            guard let code = values.first else { throw Malformed() }
            return Record(code: code, fields: Array(values.dropFirst()), blob: blob)
        }

        /// Counts `count` more decoded values, throwing past one per bit of the unit.
        private mutating func decode(_ count: UInt64) throws {
            guard count <= UInt64(bytes.count * 8 - decoded) else { throw Malformed() }
            decoded += try int(count)
        }

        private mutating func scalar(_ operand: Operand) throws -> UInt64 {
            switch operand {
            case let .literal(value): value
            case let .fixed(width): try fixed(width)
            case let .vbr(width): try vbr(width)
            case .char6: try fixed(6)
            case .array, .blob: throw Malformed()
            }
        }
    }
}
