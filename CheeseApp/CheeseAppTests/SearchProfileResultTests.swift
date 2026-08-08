import Foundation
import XCTest
@testable import CheeseApp

final class SearchProfileResultTests: XCTestCase {
    func testUIDBadgeUsesShortDisplayAndCopiesCanonicalUUID() {
        let userID = UUID(
            uuidString: "ABCDEF12-3456-4789-ABCD-EF1234567890"
        )!

        XCTAssertEqual(
            ProfileUIDPresentation.badgeText(for: userID),
            "UID abcdef12…"
        )
        XCTAssertEqual(
            ProfileUIDPresentation.clipboardText(for: userID),
            "abcdef12-3456-4789-abcd-ef1234567890"
        )
    }

    func testDecodesSearchProfileRPCFields() throws {
        let data = Data(
            """
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "full_name": "Ada Lovelace",
              "avatar_url": "https://example.com/avatar.jpg",
              "university": "McMaster University",
              "bio": "Builder",
              "is_following": true,
              "is_mutual_follow": false
            }
            """.utf8
        )

        let profile = try JSONDecoder().decode(SearchProfileResult.self, from: data)

        XCTAssertEqual(profile.fullName, "Ada Lovelace")
        XCTAssertTrue(profile.isFollowing)
        XCTAssertFalse(profile.isMutualFollow)
    }
}
