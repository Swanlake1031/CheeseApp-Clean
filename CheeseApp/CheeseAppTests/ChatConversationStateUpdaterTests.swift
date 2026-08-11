import XCTest
@testable import CheeseApp

final class ChatConversationStateUpdaterTests: XCTestCase {
    func testMarkConversationReadClearsUnread() {
        let updater = ChatConversationStateUpdater()
        let conversationId = UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
        var conversations = [
            ChatConversationPreview.fixture(
                id: conversationId,
                otherUserName: "阿哲",
                unreadCount: 3
            )
        ]
        updater.markConversationRead(
            conversationId: conversationId,
            conversations: &conversations
        )

        XCTAssertEqual(conversations.first?.unreadCount, 0)
    }

    func testSetGroupConversationUnreadCountClampsToZero() {
        let updater = ChatConversationStateUpdater()
        let groupId = UUID(uuidString: "71000000-0000-0000-0000-000000000011")!
        var groups = [
            ChatGroupPreview.fixture(
                id: groupId,
                name: "学习群",
                unreadCount: 4
            )
        ]

        updater.setGroupConversationUnreadCount(
            groupId: groupId,
            unreadCount: -3,
            groupConversations: &groups
        )

        XCTAssertEqual(groups.first?.unreadCount, 0)
    }
}

private extension ChatConversationPreview {
    static func fixture(
        id: UUID,
        otherUserId: UUID = UUID(uuidString: "81000000-0000-0000-0000-000000000001")!,
        otherUserName: String,
        unreadCount: Int
    ) -> ChatConversationPreview {
        ChatConversationPreview(
            id: id,
            otherUserId: otherUserId,
            otherUserName: otherUserName,
            otherUserAvatar: nil,
            relatedPostId: nil,
            lastMessageAt: Date(),
            lastMessagePreview: "你好",
            unreadCount: unreadCount,
            isMuted: false
        )
    }
}

private extension ChatGroupPreview {
    static func fixture(
        id: UUID,
        name: String,
        unreadCount: Int
    ) -> ChatGroupPreview {
        ChatGroupPreview(
            id: id,
            name: name,
            avatarURL: nil,
            lastMessageAt: Date(),
            lastMessagePreview: "准备出发",
            memberCount: 4,
            unreadCount: unreadCount,
            isMuted: false
        )
    }
}
