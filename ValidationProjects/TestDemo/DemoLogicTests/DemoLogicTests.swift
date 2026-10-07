import Testing

@Suite("Logic")
struct DemoLogicTests {
    @Test func evenNumbersAreEven() {
        #expect(4.isMultiple(of: 2))
    }

    @Test func oddNumbersAreOdd() {
        #expect(!5.isMultiple(of: 2))
    }

    @Test func sortingIsStable() {
        #expect([3, 1, 2].sorted() == [1, 2, 3])
    }

    @Test func filteringKeepsMatches() {
        #expect([1, 2, 3, 4].filter { $0.isMultiple(of: 2) } == [2, 4])
    }

    @Test func mappingTransformsEachElement() {
        #expect([1, 2, 3].map { $0 * 2 } == [2, 4, 6])
    }

    @Test func reducingSumsElements() {
        #expect([1, 2, 3].reduce(0, +) == 6)
    }

    @Test func emptyCollectionsHaveNoElements() {
        #expect([Int]().isEmpty)
    }

    /// `fail-always`: fails every run the trigger is set for.
    @Test func alwaysFailsWhenTriggered() {
        #expect(!Triggers.isSet("fail-always"))
    }
}
