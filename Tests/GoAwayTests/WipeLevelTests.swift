import XCTest
@testable import GoAwayCore

final class WipeLevelTests: XCTestCase {
    func testPassCounts() {
        XCTAssertEqual(WipeLevel.simple.passCount, 1)
        XCTAssertEqual(WipeLevel.doe.passCount, 3)
        XCTAssertEqual(WipeLevel.dod.passCount, 7)
        XCTAssertEqual(WipeLevel.gutmann.passCount, 35)
    }

    func testDoDPattern() {
        XCTAssertEqual(
            WipeLevel.dod.passes,
            [
                .constant(0xF6),
                .constant(0x00),
                .constant(0xFF),
                .random,
                .constant(0x00),
                .constant(0xFF),
                .random
            ]
        )
    }

    func testSSDOverride() {
        let passes = WipeLevel.effectivePasses(level: .gutmann, isSSD: true, respectSSD: true)
        XCTAssertEqual(passes, WipeLevel.simple.passes)
        let full = WipeLevel.effectivePasses(level: .gutmann, isSSD: true, respectSSD: false)
        XCTAssertEqual(full.count, 35)
    }
}
