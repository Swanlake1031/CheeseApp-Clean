import Foundation
import XCTest
@testable import CheeseApp

final class SearchProfileResultTests: XCTestCase {
    func testCheeseIDBadgeDisplaysAndCopiesPublicID() {
        let publicID = "58310427"

        XCTAssertEqual(
            ProfileUIDPresentation.badgeText(for: publicID),
            L10n.tr("Cheese ID: 58310427", "奶酪 ID: 58310427")
        )
        XCTAssertEqual(
            ProfileUIDPresentation.clipboardText(for: publicID),
            "58310427"
        )
    }

    func testDecodesSearchProfileRPCFields() throws {
        let data = Data(
            """
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "public_uid": "58310427",
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
        XCTAssertEqual(profile.publicID, "58310427")
        XCTAssertTrue(profile.isFollowing)
        XCTAssertFalse(profile.isMutualFollow)
    }
}
