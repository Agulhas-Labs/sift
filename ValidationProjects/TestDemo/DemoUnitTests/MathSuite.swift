import Testing

@Suite("Math")
struct MathSuite {
    @Test func addsTwoNumbers() {
        #expect(1 + 1 == 2)
    }

    @Test func subtractsTwoNumbers() {
        #expect(3 - 1 == 2)
    }

    @Test(arguments: [1, 2, 3])
    func doublingIsEven(_ value: Int) {
        #expect((value * 2).isMultiple(of: 2))
    }

    @Test(.disabled("not ready"))
    func multipliesLargeNumbers() {
        #expect(1_000_000 * 1_000_000 == 1_000_000_000_000)
    }
}
