import Foundation
import XCTest
@testable import Searoom

final class GPUUtilizationTests: XCTestCase {
    func testGPUUtilizationReadsWholePercentages() {
        // Searoom once guessed the scale from the magnitude, so a raw 1 passed
        // through as the fraction 1.0 and an idle GPU reported 100%.
        for (raw, expected) in [(0.0, 0.0), (1, 0.01), (2, 0.02), (50, 0.5), (100, 1)] {
            XCTAssertEqual(
                GPUCollector.parseUtilization(["Device Utilization %": raw]),
                expected,
                "raw \(raw)"
            )
        }
    }

    func testGPUUtilizationTakesTheBusiestKeyAndClamps() {
        XCTAssertEqual(
            GPUCollector.parseUtilization(["Device Utilization %": 1, "Renderer Utilization %": 40]),
            0.4
        )
        XCTAssertEqual(GPUCollector.parseUtilization(["Device Utilization %": 140]), 1)
        XCTAssertEqual(GPUCollector.parseUtilization(["Device Utilization %": -3]), 0)
    }

    func testGPUUtilizationIsUnavailableWithoutAPercentageKey() {
        XCTAssertNil(GPUCollector.parseUtilization([:]))
        XCTAssertNil(GPUCollector.parseUtilization(["In use system memory": 631_635_968]))
        // Names no unit, so its scale cannot be established.
        XCTAssertNil(GPUCollector.parseUtilization(["GPU Core Utilization": 1]))
    }
}
