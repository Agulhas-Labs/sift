//
// Copyright © Agulhas Labs
//

import Foundation

/// In-place answers to reads of a file, and those of them the same context read whole anyway, by answer shape.
public struct AnswerMissTally: Sendable, Equatable, Codable {
    /// Answers given, by shape.
    public var answers: [AnswerShape: Int] = [:]

    /// Answers followed by a whole read of their file within ``AnswerThenRead/window`` calls, by shape.
    public var misses: [AnswerShape: Int] = [:]

    public init() {}

    /// Every answer counted, whatever its shape.
    public var answerCount: Int {
        answers.values.reduce(0, +)
    }

    /// Every miss counted, whatever its shape.
    public var missCount: Int {
        misses.values.reduce(0, +)
    }

    public static func += (lhs: inout AnswerMissTally, rhs: AnswerMissTally) {
        lhs.answers.merge(rhs.answers, uniquingKeysWith: +)
        lhs.misses.merge(rhs.misses, uniquingKeysWith: +)
    }
}
