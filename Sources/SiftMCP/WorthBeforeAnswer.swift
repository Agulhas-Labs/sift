//
// Copyright © Agulhas Labs
//

import Foundation

/// The judgement ``WholeReadWorth`` makes of a reading before its answer is built, carried from the hook to the answerer.
///
/// **The size bound alone.** An answer is never smaller than nothing, so where a reading would not be worth the turn even with an answer of no bytes, no answer built for it could be: a whole read of a Swift file, or windows a `Read` asks for printing at least ``WholeReadWorth/windowShare`` of its lines, where `margin(F, 0, C) ≤ 0`, and a narrower `Read` window where `W − 0 ≤ readWindowReRunShare · (W + turn)`. Such a reading is withheld as `notWorthTheTurn` without opening an engine, refreshing the store or building the answer (``settles(_:)``).
///
/// **Precedence.** Everything the answerer decides before it would open an engine — the repository, the back-off, a conflicted window, a fallback whose file is not there, a line whose other statements run — still decides first, and the bound outranks only the reasons decided while the answer is built: a parse error, an answer no smaller than its source, an unindexed file, an unwritable tree, a failure, an overrun. A shell window (`sed -n`, `head`) is never weighed here, nor a line of several reads, and a reading the bound does not settle is weighed after its answer is built as before (``WholeReadWorth/weighing(_:of:payload:)``).
///
/// The answerer's outcome reaches the hook through a closure tests replace, so the hook binds one of these around the answer for the duration of the call (``current``), as it binds ``InPlaceOverrun``, and the answerer asks it once the reading's repository and back-off are known. The context's size is read only once the reading is known to be one the bound weighs, so a call it does not weigh never reads a transcript.
public final class WorthBeforeAnswer: @unchecked Sendable {
    /// The judgement the in-place answer in progress is held to, where the hook bound one.
    @TaskLocal public static var current: WorthBeforeAnswer?

    /// The call's payload, which names the tool and leads to the context's size; never written after `init`.
    private let payload: [String: Any]

    public init(payload: [String: Any]) {
        self.payload = payload
    }

    /// Whether a whole read of a file of so many bytes, answered with a digest of so many, is worth the turn in this call's context: the judgement each file of a `cat` of several is held to (``InPlaceShape/Match/weighsEachRead``), with the context's size read once.
    func eachRead() -> @Sendable (_ fileBytes: Int, _ digestBytes: Int) -> Bool {
        let context = ContextSize.ofCall(payload)
        return { WholeReadWorth.isWorthTheTurn(fileBytes: $0, digestBytes: $1, contextTokens: context) }
    }

    /// Whether `reading` is withheld as `notWorthTheTurn` before its answer is built: it is a shape ``WholeReadWorth`` weighs, and an answer of no bytes would not be worth the turn.
    func settles(_ reading: InPlaceShape.Match) -> Bool {
        Self.settles(reading, payload: payload)
    }

    /// Whether `reading`, asked by the call `payload` describes, is never worth the turn whatever its answer: false for every reading ``WholeReadWorth/weighing(_:of:payload:)`` would not weigh, for a window a shell command asks for, and where the file or a window's lines cannot be read.
    public static func settles(_ reading: InPlaceShape.Match, payload: [String: Any]) -> Bool {
        if reading.weighsEachRead {
            // A `cat` of several files is let through only where no file's digest could be worth the turn.
            let files = reading.calls.map { $0.readPath.flatMap { OperandFile.onDisk($0, in: reading.directory) } }
            guard files.allSatisfy({ $0 != nil }) else { return false }
            let context = ContextSize.ofCall(payload)
            return files.compactMap(\.self).allSatisfy { WholeReadWorth.margin(fileBytes: $0.bytes, digestBytes: 0, contextTokens: context) <= 0 }
        }
        guard reading.calls.count == 1, case let .fileDigest(path, windows) = reading.calls[0] else { return false }
        if windows.isEmpty {
            guard !reading.windowed.contains(true), let file = OperandFile.onDisk(path, in: reading.directory) else { return false }
            return WholeReadWorth.margin(fileBytes: file.bytes, digestBytes: 0, contextTokens: ContextSize.ofCall(payload)) <= 0
        }
        guard payload["tool_name"] as? String == "Read", let file = OperandFile.onDisk(path, in: reading.directory) else { return false }
        if WholeReadWorth.printsMost(windows, ofFileAt: path, in: reading.directory) {
            return WholeReadWorth.margin(fileBytes: file.bytes, digestBytes: 0, contextTokens: ContextSize.ofCall(payload)) <= 0
        }
        // The windows' lines summed as the whole digest weighs them, each window's own, which is at least what the members answering them are weighed with.
        guard let window = OperandFile.windowBytes(of: windows, in: file.lines, byteLengths: file.byteLengths) else { return false }
        return WholeReadWorth.readWindowMargin(windowBytes: window, answerBytes: 0, contextTokens: ContextSize.ofCall(payload)) <= 0
    }
}
