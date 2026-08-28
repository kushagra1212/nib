import XCTest
@testable import nib

final class ModelRankingTests: XCTestCase {
    func testPrefersQwenOverGemma270M() {
        let ranked = rankModels([
            "gemma-3-270m-it-Q8_0.gguf",
            "Qwen3-0.6B-Q8_0.gguf",
        ])
        XCTAssertEqual(ranked.first, "Qwen3-0.6B-Q8_0.gguf")
    }

    func testPrefersLargerQwenWhenPresent() {
        let ranked = rankModels([
            "Qwen3-0.6B-Q8_0.gguf",
            "Qwen3-1.7B-Q4_K_M.gguf",
        ])
        XCTAssertEqual(ranked.first, "Qwen3-1.7B-Q4_K_M.gguf")
    }

    func testUnknownModelBeatsKnownInadequateOne() {
        let ranked = rankModels([
            "gemma-3-270m-it-Q8_0.gguf",
            "some-unknown-model.gguf",
        ])
        XCTAssertEqual(ranked.first, "some-unknown-model.gguf")
    }

    func test270MStillUsedWhenItIsTheOnlyOption() {
        let ranked = rankModels(["gemma-3-270m-it-Q8_0.gguf"])
        XCTAssertEqual(ranked, ["gemma-3-270m-it-Q8_0.gguf"],
                       "a weak model beats no rewrite at all")
    }

    func testOrderingIsStableForEqualScores() {
        let ranked = rankModels(["b-model.gguf", "a-model.gguf"])
        XCTAssertEqual(ranked, ["a-model.gguf", "b-model.gguf"])
    }

    func testEmptyInput() {
        XCTAssertTrue(rankModels([]).isEmpty)
    }
}
