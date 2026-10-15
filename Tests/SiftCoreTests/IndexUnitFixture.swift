//
// Copyright © Agulhas Labs
//

import Foundation

/// Unit files in the index store's own format — an info block, a block the reader skips, and a paths block — so a test can stand up a units directory without a build.
struct IndexUnitFixture {
    /// Writes a unit recording the one file `file` under `path`, relative to `workingDirectory`, as `named` in `units`.
    static func write(workingDirectory: String, path: String, file: String, named: String, in units: URL) throws {
        try unit(workingDirectory: workingDirectory, paths: [Path(kind: 1, directory: path, file: file)]).write(to: units.appendingPathComponent(named))
    }

    /// The bytes of a unit recording `paths`.
    static func unit(workingDirectory: String, sdkRoot: String = "/SDK", paths: [Path]) -> Data {
        var buffer = Array(workingDirectory.utf8) + Array(sdkRoot.utf8)
        var pathFields: [[UInt64]] = []
        for path in paths {
            let directory = UInt64(buffer.count)
            buffer += Array(path.directory.utf8)
            let file = UInt64(buffer.count)
            buffer += Array(path.file.utf8)
            pathFields.append([path.kind, directory, UInt64(path.directory.utf8.count), file, UInt64(path.file.utf8.count)])
        }
        let workingDirectoryCount = UInt64(workingDirectory.utf8.count)
        var writer = BitWriter()
        writer.block(9) { $0.unabbreviated(1, [0, 0, workingDirectoryCount, 0, 0, workingDirectoryCount, UInt64(sdkRoot.utf8.count)]) }
        writer.block(10) { $0.unabbreviated(2, [1, 2, 3]) }
        writer.block(12) { block in
            for fields in pathFields {
                block.unabbreviated(4, fields)
            }
            block.blobRecord(5, buffer)
        }
        return Data("IDXU".utf8) + Data(writer.bytes)
    }

    /// The bits `body` writes, from a 32-bit boundary, to append to a unit as the blocks after its own.
    static func bits(_ body: (inout BitWriter) -> Void) -> Data {
        var writer = BitWriter()
        body(&writer)
        return Data(writer.bytes)
    }
}

extension IndexUnitFixture {
    /// One path record: its prefix kind (0 none, 1 the working directory, 2 the SDK root), its directory after that prefix, and its file name.
    struct Path {
        let kind: UInt64
        let directory: String
        let file: String
    }
}

extension IndexUnitFixture {
    /// The bitstream writing ``IndexUnitFixture`` needs: blocks of abbreviation width 3, unabbreviated records, and one abbreviated record carrying a blob; a crafted unit writes its own bits with `emit` and `vbr`.
    struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var bit = 0

        mutating func block(_ id: UInt64, _ body: (inout Self) -> Void) {
            emit(1, width: 2)
            vbr(id, width: 8)
            vbr(3, width: 4)
            align()
            let lengthAt = bytes.count
            emit(0, width: 32)
            body(&self)
            emit(0, width: 3)
            align()
            let words = UInt32((bytes.count - lengthAt - 4) / 4)
            for index in 0 ..< 4 {
                bytes[lengthAt + index] = UInt8(truncatingIfNeeded: words >> (8 * index))
            }
        }

        mutating func unabbreviated(_ code: UInt64, _ fields: [UInt64]) {
            emit(3, width: 3)
            vbr(code, width: 6)
            vbr(UInt64(fields.count), width: 6)
            for field in fields {
                vbr(field, width: 6)
            }
        }

        /// Defines an abbreviation of a literal code then a blob, and writes `blob` with it.
        mutating func blobRecord(_ code: UInt64, _ blob: [UInt8]) {
            emit(2, width: 3)
            vbr(2, width: 5)
            emit(1, width: 1)
            vbr(code, width: 8)
            emit(0, width: 1)
            emit(5, width: 3)
            emit(4, width: 3)
            vbr(UInt64(blob.count), width: 6)
            align()
            bytes += blob
            bit = bytes.count * 8
            align()
        }

        mutating func emit(_ value: UInt64, width: Int) {
            for index in 0 ..< width {
                if bit >> 3 == bytes.count {
                    bytes.append(0)
                }
                if (value >> UInt64(index)) & 1 == 1 {
                    bytes[bit >> 3] |= 1 << UInt8(bit & 7)
                }
                bit += 1
            }
        }

        mutating func vbr(_ value: UInt64, width: Int) {
            var rest = value
            let payload = UInt64(width - 1)
            repeat {
                let chunk = rest & ((1 << payload) - 1)
                rest >>= payload
                emit(rest == 0 ? chunk : chunk | (1 << payload), width: width)
            } while rest != 0
        }

        private mutating func align() {
            while bit % 32 != 0 {
                emit(0, width: 1)
            }
        }
    }
}
