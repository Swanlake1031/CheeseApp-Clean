import XCTest
@testable import CheeseApp

final class ChatInboxPresentationStateTests: XCTestCase {
    func testBrowsingStateKeepsPrimaryConversationSectionsSeparateFromInboxCategories() {
        let direct = ChatConversationPreview.fixture(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000002")!,
            otherUserName: "阿哲",
            lastMessagePreview: "周末见"
        )
        let group = ChatGroupPreview.fixture(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000003")!,
            name: "周末羽毛球局"
        )

        let state = ChatInboxPresentationState(
            searchText: "",
            directConversations: [direct],
            groupConversations: [group],
            displayNamesByConversationId: [direct.id: "阿哲"]
        )

        XCTAssertEqual(state.visibleSections.map(\.kind), [.groups, .directMessages])
        XCTAssertEqual(state.visibleItemCount, 2)
    }

    func testSearchMatchesConversationRemark() {
        let direct = ChatConversationPreview.fixture(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000011")!,
            otherUserName: "Alex",
            lastMessagePreview: "晚点回你"
        )

        let state = ChatInboxPresentationState(
            searchText: "室友",
            directConversations: [direct],
            groupConversations: [],
            displayNamesByConversationId: [direct.id: "新室友"]
        )

        XCTAssertEqual(state.visibleSections.map(\.kind), [.directMessages])
        XCTAssertEqual(state.visibleItemCount, 1)

        guard let item = state.visibleSections.first?.items.first else {
            return XCTFail("Expected one matching direct conversation")
        }

        guard case .direct(let matchedConversation) = item else {
            return XCTFail("Expected search result to stay in direct conversation section")
        }

        XCTAssertEqual(matchedConversation.id, direct.id)
    }

    func testNotificationCategoryRoutesHaveStableDistinctIdentities() {
        XCTAssertEqual(
            ChatInboxRoute.systemMessages(.system).id,
            "system-messages:system"
        )
        XCTAssertEqual(
            ChatInboxRoute.systemMessages(.interaction).id,
            "system-messages:interaction"
        )
        XCTAssertNotEqual(
            ChatInboxRoute.systemMessages(.system).id,
            ChatInboxRoute.systemMessages(.interaction).id
        )
    }

    func testSearchMatchesGroupNameAndReportsEmptyStateWhenNothingMatches() {
        let group = ChatGroupPreview.fixture(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000021")!,
            name: "Markham 探店小分队"
        )

        let matchingState = ChatInboxPresentationState(
            searchText: "Markham",
            directConversations: [],
            groupConversations: [group],
            displayNamesByConversationId: [:]
        )

        XCTAssertEqual(matchingState.visibleSections.map(\.kind), [.groups])
        XCTAssertFalse(matchingState.showsSearchEmptyState)

        let emptyState = ChatInboxPresentationState(
            searchText: "Vancouver",
            directConversations: [],
            groupConversations: [group],
            displayNamesByConversationId: [:]
        )

        XCTAssertTrue(emptyState.showsSearchEmptyState)
        XCTAssertEqual(emptyState.visibleItemCount, 0)
    }
}

private extension ChatConversationPreview {
    static func fixture(
        id: UUID,
        otherUserId: UUID = UUID(uuidString: "80000000-0000-0000-0000-000000000001")!,
        otherUserName: String,
        lastMessagePreview: String?
    ) -> ChatConversationPreview {
        ChatConversationPreview(
            id: id,
            otherUserId: otherUserId,
            otherUserName: otherUserName,
            otherUserAvatar: nil,
            relatedPostId: nil,
            lastMessageAt: Date(),
            lastMessagePreview: lastMessagePreview,
            unreadCount: 0,
            isMuted: false
        )
    }
}

private extension ChatGroupPreview {
    static func fixture(
        id: UUID,
        name: String
    ) -> ChatGroupPreview {
        ChatGroupPreview(
            id: id,
            name: name,
            avatarURL: nil,
            lastMessageAt: Date(),
            lastMessagePreview: "准备出发",
            memberCount: 4,
            unreadCount: 0,
            isMuted: false
        )
    }
}
