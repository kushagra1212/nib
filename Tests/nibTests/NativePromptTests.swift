import XCTest
@testable import nib

/// The Native instruction, and the one thing about it that is load-bearing.
///
/// Reported as nib rewriting worse than ChatGPT on:
///
///     Then I will test on the APK and event in  the Events Manager.
///
/// The second half has no verb. nib dropped it -- "Then I'll test it on the
/// APK and in the Events Manager" -- leaving the events with nothing happening
/// to them. ChatGPT supplied a verb.
///
/// Two plausible explanations were measured against the installed 4B and both
/// were wrong. Removing "Do not add information that is not there" changed the
/// output not at all. And the model is not short of the ability: asked for
/// three rewrites rather than one it produced "run the test on the APK and
/// verify it within the Events Manager" as its second.
///
/// What fixed it was moving the rule to the front of the instruction. Appended
/// at the end it was ignored, which is why these tests pin the position and
/// not merely the presence of the words.
final class NativePromptTests: XCTestCase {

    private var native: String { RewriteMode.native.systemPrompt() }

    /// The rule is present, and says what to do rather than what not to.
    func testNativeAsksForTheMissingVerb() {
        XCTAssertTrue(native.contains("verb and preposition it needs"))
        XCTAssertTrue(native.contains("rather than dropping the clause"))
    }

    /// And comes before the general instructions.
    ///
    /// The same sentence placed after "Keep every fact and every point"
    /// produced the clause-dropping output it exists to prevent. Position is
    /// the fix; presence alone is not.
    func testTheVerbRuleComesBeforeTheGeneralInstructions() throws {
        let rule = try XCTUnwrap(native.range(of: "verb and preposition it needs"))
        let general = try XCTUnwrap(native.range(of: "Fix the grammar"))
        let facts = try XCTUnwrap(native.range(of: "Keep every fact"))
        XCTAssertLessThan(rule.lowerBound, general.lowerBound)
        XCTAssertLessThan(rule.lowerBound, facts.lowerBound)
    }

    /// Inventing facts is still barred. The rule licenses completing a clause
    /// the writer started, not adding a claim they did not make.
    func testNativeStillBarsNewFacts() {
        XCTAssertTrue(native.contains("Do not introduce a new fact, name or number"))
    }

    /// Only Native gets it. Fix and Clearer are applied as corrections to what
    /// someone typed, and a mode that supplies missing words is the wrong thing
    /// to run over a sentence uninvited.
    func testOnlyNativeSuppliesMissingWords() {
        for mode in RewriteMode.allCases where mode != .native {
            XCTAssertFalse(mode.systemPrompt().contains("verb and preposition it needs"),
                           "\(mode.rawValue) should not supply missing words")
        }
    }

    /// Native may restructure, which is what lets a completed clause through
    /// the content guard rather than being refused as a rewrite that dropped
    /// something. Only Fix is held to the mid-sentence rule.
    func testNativeMayRestructure() {
        XCTAssertTrue(RewriteMode.native.mayRestructure)
        XCTAssertFalse(RewriteMode.fixGrammar.mayRestructure)
    }
}
