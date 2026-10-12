//
// Copyright © Agulhas Labs
//

import Foundation

/// What ran out of the in-place time budget, carried from the answerer back to the hook that logs the withholding.
///
/// ``InPlaceAnswerer/Withholding`` is a raw-value enum the logs and the audit read by name, so `overTime` cannot carry which shape overran without breaking every reader of those names. The answerer's outcome reaches the hook through a closure tests replace, so the shape cannot ride on the outcome either. So the hook binds one of these around the answer for the duration of the call (``current``), and the answerer fills it at the moment it notes the overrun in the back-off: the shapes it charged, and the window it armed. Bound for the call and read synchronously on the caller's thread, which is where the answerer notes its overrun.
///
/// An `overTime` the hook logs with nothing recorded here is one where no answer ran out of time: the line's budget was already spent before a line's Swift leg was asked on its own, so nothing was charged and no window armed.
public final class InPlaceOverrun: @unchecked Sendable {
    /// The record the in-place answer in progress fills, where the hook bound one.
    @TaskLocal public static var current: InPlaceOverrun?

    private let lock = NSLock()
    private var recorded: (shapes: [InPlaceCall.Shape], window: TimeInterval)?

    public init() {}

    /// Records that answering `shapes` ran out of time and armed a back-off of `window` seconds against each; the latest overrun stands, since it is the one whose `overTime` the call ends in.
    func record(shapes: [InPlaceCall.Shape], window: TimeInterval) {
        lock.withLock { recorded = (shapes, window) }
    }

    /// What an `overTime` suppression row carries beside its standard fields: `shapes`, the shapes that overran by name, sorted, and `backoff`, the seconds of back-off that armed; `shapes` empty and no `backoff` where nothing overran.
    public var suppressionFields: [String: Any] {
        lock.withLock {
            guard let recorded else { return ["shapes": [String]()] }
            return ["shapes": recorded.shapes.map(\.rawValue).sorted(), "backoff": Int(recorded.window)]
        }
    }
}
