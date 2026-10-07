//
// Copyright © Agulhas Labs
//

/// What one target's untimed tests were actually charged, and which median that came from.
public struct EstimatedCharge: Sendable, Equatable {
    /// The seconds charged.
    public let seconds: Double

    /// Whether `seconds` is the target's own median or the plan's.
    public let source: EstimateSource

    public init(seconds: Double, source: EstimateSource) {
        self.seconds = seconds
        self.source = source
    }
}
