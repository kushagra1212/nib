import XCTest
@testable import nib

/// Covers turning a model's rewritten sentence back into localized edits.
/// A wrong range here underlines the wrong word or replaces the wrong span,
/// which is worse than showing nothing.
final class WordDiffTests: XCTestCase {
    private func edits(_ from: String, _ to: String) -> [TextEdit] {
        WordDiff.edits(from: from, to: to)
    }

    // MARK: - tokenizing

    func testTokenizesWordsWithRanges() {
        let tokens = WordDiff.tokenize("Their is many")
        XCTAssertEqual(tokens.map(\.text), ["Their", "is", "many"])
        XCTAssertEqual(tokens[0].range, NSRange(location: 0, length: 5))
        XCTAssertEqual(tokens[1].range, NSRange(location: 6, length: 2))
        XCTAssertEqual(tokens[2].range, NSRange(location: 9, length: 4))
    }

    func testPunctuationSeparatesTokens() {
        XCTAssertEqual(WordDiff.tokenize("Hi, there!").map(\.text), ["Hi", "there"])
    }

    func testApostrophesStayInsideWords() {
        XCTAssertEqual(WordDiff.tokenize("don't stop").map(\.text), ["don't", "stop"])
    }

    func testHyphenatedAndUnderscoredWordsStayWhole() {
        XCTAssertEqual(WordDiff.tokenize("UTF-16 and snake_case").map(\.text),
                       ["UTF-16", "and", "snake_case"])
    }

    func testDigitsAreWordCharacters() {
        XCTAssertEqual(WordDiff.tokenize("RN 86 build").map(\.text), ["RN", "86", "build"])
    }

    func testEmptyAndWhitespaceOnly() {
        XCTAssertTrue(WordDiff.tokenize("").isEmpty)
        XCTAssertTrue(WordDiff.tokenize("   \n ").isEmpty)
    }

    func testTokenRangesSurviveEmoji() {
        let tokens = WordDiff.tokenize("😀 bad")
        XCTAssertEqual(tokens.map(\.text), ["bad"])
        XCTAssertEqual(tokens[0].range, NSRange(location: 3, length: 3),
                       "emoji is two UTF-16 units, so 'bad' starts at 3")
    }

    // MARK: - single-word edits

    func testNoChangeYieldsNoEdits() {
        XCTAssertTrue(edits("There are many", "There are many").isEmpty)
    }

    func testSingleWordSubstitution() {
        let result = edits("Their is many", "There is many")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].range, NSRange(location: 0, length: 5))
        XCTAssertEqual(result[0].replacement, "There")
        XCTAssertEqual(result[0].expected, "Their")
    }

    func testSubstitutionInTheMiddle() {
        let result = edits("the cat sat", "the dog sat")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].expected, "cat")
        XCTAssertEqual(result[0].replacement, "dog")
    }

    func testSubstitutionAtTheEnd() {
        let result = edits("the cat sat", "the cat stood")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].expected, "sat")
    }

    func testTwoSeparateSubstitutions() {
        let result = edits("Their is many erors", "There is many errors")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].expected, "Their")
        XCTAssertEqual(result[1].expected, "erors")
    }

    // MARK: - multi-word edits

    func testAdjacentChangesMergeIntoOneEdit() {
        // "could of" -> "could have" must read as one suggestion, not two.
        let result = edits("it could of worked", "it could have worked")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].expected, "of")
        XCTAssertEqual(result[0].replacement, "have")
    }

    func testTwoWordsBecomeOne() {
        let result = edits("work t he end", "work the end")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].expected, "t he")
        XCTAssertEqual(result[0].replacement, "the")
    }

    func testOneWordBecomesTwo() {
        let result = edits("this kind of bugs", "this kind of bug reports")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].expected, "bugs")
        XCTAssertEqual(result[0].replacement, "bug reports")
    }

    func testDeletionOfAWord() {
        let result = edits("this is very very long", "this is very long")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].replacement, "")
    }

    func testPureInsertionIsDropped() {
        // Nothing to anchor an underline to, and a zero-width mark cannot be
        // hovered, so insertions are not surfaced as inline suggestions.
        XCTAssertTrue(edits("cat sat", "the cat sat").isEmpty)
    }

    // MARK: - ranges stay usable

    func testEditRangesApplyCleanly() {
        let original = "Their is many erors here"
        let result = edits(original, "There is many errors here")
        XCTAssertEqual(result.count, 2)
        for edit in result {
            XCTAssertTrue(EditPlanner.isValid(edit, in: original),
                          "\(edit.expected) must still sit at its range")
        }
    }

    func testApplyingEveryEditReproducesTheRewrite() {
        let original = "Their is many erors here"
        var text = original
        // Apply right to left so earlier ranges stay valid.
        for edit in edits(original, "There is many errors here").reversed() {
            text = EditPlanner.apply(edit, to: text) ?? text
        }
        XCTAssertEqual(text, "There is many errors here")
    }

    func testRangesAreCorrectAfterAnEmoji() {
        let original = "😀 Their is here"
        let result = edits(original, "😀 There is here")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].range, NSRange(location: 3, length: 5))
        XCTAssertTrue(EditPlanner.isValid(result[0], in: original))
    }

    // MARK: - technical text must survive

    func testTechnicalTermsAreLeftAloneWhenTheModelLeavesThem() {
        let original = "UTF-16 traps with NSString.length here"
        // A good model returns these untouched, so no edits should appear.
        XCTAssertTrue(edits(original, original).isEmpty)
    }

    func testOnlyTheChangedWordIsFlaggedInTechnicalText() {
        let original = "UTF-16 traps and NSString erors"
        let result = edits(original, "UTF-16 traps and NSString errors")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].expected, "erors")
    }

    // MARK: - suggestions

    func testSuggestionsCarryTheReplacement() {
        let result = WordDiff.suggestions(from: "Their is", to: "There is")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].replacements, ["There"])
        XCTAssertEqual(result[0].range, NSRange(location: 0, length: 5))
    }

    func testNoSuggestionsWhenNothingChanged() {
        XCTAssertTrue(WordDiff.suggestions(from: "fine text", to: "fine text").isEmpty)
    }

    // MARK: - LCS

    func testLongestCommonSubsequence() {
        XCTAssertEqual(WordDiff.longestCommonSubsequence(["a", "b", "c"], ["a", "c"]),
                       ["a", "c"])
        XCTAssertEqual(WordDiff.longestCommonSubsequence(["a"], ["b"]), [])
        XCTAssertEqual(WordDiff.longestCommonSubsequence([], ["a"]), [])
    }

    func testRepeatedWordsDoNotConfuseTheDiff() {
        let result = edits("the the the cat", "the the the dog")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].expected, "cat")
    }

    func testCompleteRewriteProducesOneEdit() {
        let result = edits("aaa bbb", "xxx yyy")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].replacement, "xxx yyy")
    }

    func testCaseChangeIsAnEdit() {
        let result = edits("the cat", "The cat")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].replacement, "The")
    }
}
