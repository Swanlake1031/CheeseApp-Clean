import XCTest
@testable import CheeseApp

final class MentionTextLogicTests: XCTestCase {
    func testQueryUsesTheActiveTrailingMention() {
        let text = "谢谢 @Alice，麻烦 @Bo"
        let query = MentionTextLogic.query(in: text)

        XCTAssertEqual(query?.value, "Bo")
        XCTAssertEqual(
            query.map { String(text[$0.range]) },
            "@Bo"
        )
    }

    func testWhitespaceClosesMentionSuggestions() {
        XCTAssertNil(MentionTextLogic.query(in: "你好 @Alice 明天见"))
    }

    func testInsertReplacesOnlyActiveMentionQuery() {
        let candidate = MentionCandidate(
            id: UUID(),
            fullName: "Bob Chen",
            avatarURL: nil,
            university: "McMaster University"
        )

        XCTAssertEqual(
            MentionTextLogic.insert(
                candidate,
                into: "谢谢 @Alice，麻烦 @Bo"
            ),
            "谢谢 @Alice，麻烦 @Bob Chen "
        )
    }

    func testActiveIDsAreStableDeduplicatedAndRemovedWithText() {
        let aliceID = UUID()
        let bobID = UUID()
        let alice = MentionCandidate(
            id: aliceID,
            fullName: "Alice",
            avatarURL: nil,
            university: nil
        )
        let duplicateAlice = alice
        let bob = MentionCandidate(
            id: bobID,
            fullName: "Bob",
            avatarURL: nil,
            university: nil
        )

        XCTAssertEqual(
            MentionTextLogic.activeUserIDs(
                in: "@Alice 你好",
                selected: [alice, duplicateAlice, bob]
            ),
            [aliceID]
        )
    }
}
