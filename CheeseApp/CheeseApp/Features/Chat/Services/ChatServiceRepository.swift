//
//  ChatServiceRepository.swift
//  CheeseApp
//
//  Feature-owned Chat data access and server-backed fetch helpers.
//

import Foundation
import Supabase

struct ChatConversationRepositorySnapshot {
    let directConversations: [ChatConversationPreview]
    let groupConversations: [ChatGroupPreview]
}

struct ChatMessagePageCursor: Equatable {
    let createdAt: Date
    let id: UUID
}

struct ChatMessagePage<MessageType> {
    let messages: [MessageType]
    let nextCursor: ChatMessagePageCursor?
}

struct ChatServiceRepository {
    private let supabase = SupabaseManager.shared
    private let stateUpdater = ChatConversationStateUpdater()
    private let messagePageSize = 40

    func findExistingConversationId(currentUserId: UUID, otherUserId: UUID) async throws -> UUID? {
        let (user1Id, user2Id) = orderedConversationUsers(currentUserId, otherUserId)
        return try await fetchConversationId(user1Id: user1Id, user2Id: user2Id)
    }

    func fetchConversationSnapshot(userId: UUID) async throws -> ChatConversationRepositorySnapshot {
        async let directTask = fetchUserConversations(userId: userId)
        async let groupTask = fetchUserChatGroups(userId: userId)

        return ChatConversationRepositorySnapshot(
            directConversations: try await directTask,
            groupConversations: try await groupTask
        )
    }

    func fetchMessages(conversationId: UUID) async throws -> [Message] {
        try await fetchMessagesPage(conversationId: conversationId).messages
    }

    func fetchMessagesPage(
        conversationId: UUID,
        before cursor: ChatMessagePageCursor? = nil
    ) async throws -> ChatMessagePage<Message> {
        let rows: [Message] = try await supabase.client
            .rpc(
                "get_direct_messages_page",
                params: DirectMessagePageParams(
                    conversationID: conversationId,
                    beforeCreatedAt: cursor?.createdAt,
                    beforeID: cursor?.id,
                    limit: messagePageSize
                )
            )
            .execute()
            .value

        return ChatMessagePage(
            messages: rows,
            nextCursor: rows.count == messagePageSize
                ? rows.last.map { ChatMessagePageCursor(createdAt: $0.createdAt, id: $0.id) }
                : nil
        )
    }

    private func fetchMessage(messageId: UUID) async throws -> Message {
        try await supabase
            .database(Tables.messages)
            .select("id,conversation_id,sender_id,content,message_type,metadata,is_read,created_at,is_deleted")
            .eq("id", value: messageId.uuidString)
            .single()
            .execute()
            .value
    }

    func observeMessages(
        conversationId: UUID,
        onMessage: @escaping (Message) async -> Void,
        onMessageDeleted: @escaping (UUID) async -> Void,
        onDisconnect: @escaping () -> Void
    ) async throws -> () -> Void {
        try await observeMessageChanges(
            channelName: "chat-room-\(conversationId.uuidString)",
            table: Tables.messages,
            filterColumn: "conversation_id",
            roomId: conversationId,
            fetchMessage: { try await fetchMessage(messageId: $0) },
            onMessage: onMessage,
            onMessageDeleted: onMessageDeleted,
            onDisconnect: onDisconnect
        )
    }

    func insertMessage(
        conversationId: UUID,
        senderId: UUID,
        content: String,
        messageType: String,
        metadata: MessageMetadata?
    ) async throws -> Message {
        try await supabase
            .database(Tables.messages)
            .insert(
                MessageInsert(
                    conversationId: conversationId,
                    senderId: senderId,
                    content: content,
                    messageType: messageType,
                    metadata: metadata
                )
            )
            .select("id,conversation_id,sender_id,content,message_type,metadata,is_read,created_at,is_deleted")
            .single()
            .execute()
            .value
    }

    func hasSentPostLinkedCard(
        conversationId: UUID,
        postKind: PostKind,
        postId: UUID
    ) async throws -> Bool {
        return try await supabase.client
            .rpc(
                "has_sent_post_linked_card",
                params: LinkedPostCardLookupParams(
                    conversationID: conversationId,
                    postKind: postKind.rawValue,
                    postID: postId
                )
            )
            .execute()
            .value
    }

    func fetchSecondhandPurchaseIntent(
        conversationId: UUID
    ) async throws -> SecondhandChatPurchaseIntent? {
        let rows: [SecondhandChatPurchaseIntent] = try await supabase.client
            .rpc(
                "get_secondhand_chat_purchase_intent",
                params: SecondhandChatIntentParams(conversationID: conversationId)
            )
            .execute()
            .value
        return rows.first
    }

    func fetchSecondhandActiveBuyers(
        listingId: UUID
    ) async throws -> [SecondhandActiveBuyer] {
        try await supabase.client
            .rpc(
                "get_secondhand_active_buyers",
                params: SecondhandListingParams(listingID: listingId)
            )
            .execute()
            .value
    }

    func fetchConversationCompletedSecondhandTransactions(
        conversationId: UUID
    ) async throws -> [CompletedSecondhandTransaction] {
        try await supabase.client
            .rpc(
                "get_conversation_completed_secondhand_transactions",
                params: SecondhandChatIntentParams(conversationID: conversationId)
            )
            .execute()
            .value
    }

    func cancelSecondhandPurchaseIntent(intentId: UUID) async throws {
        try await supabase.client
            .rpc(
                "cancel_my_secondhand_purchase_intent",
                params: SecondhandIntentActionParams(intentID: intentId)
            )
            .execute()
    }

    func completeSecondhandSale(listingId: UUID, buyerId: UUID) async throws {
        try await supabase.client
            .rpc(
                "complete_secondhand_sale",
                params: CompleteSecondhandSaleParams(
                    listingID: listingId,
                    buyerID: buyerId
                )
            )
            .execute()
    }

    func cancelSellerSecondhandTransaction(intentId: UUID) async throws {
        try await supabase.client
            .rpc(
                "cancel_seller_secondhand_purchase_intent",
                params: SecondhandIntentActionParams(intentID: intentId)
            )
            .execute()
    }

    func fetchGroupMessages(groupId: UUID) async throws -> [GroupMessage] {
        try await fetchGroupMessagesPage(groupId: groupId).messages
    }

    func fetchGroupMessagesPage(
        groupId: UUID,
        before cursor: ChatMessagePageCursor? = nil
    ) async throws -> ChatMessagePage<GroupMessage> {
        let rows: [GroupMessage] = try await supabase.client
            .rpc(
                "get_group_messages_page",
                params: GroupMessagePageParams(
                    groupID: groupId,
                    beforeCreatedAt: cursor?.createdAt,
                    beforeID: cursor?.id,
                    limit: messagePageSize
                )
            )
            .execute()
            .value

        return ChatMessagePage(
            messages: rows,
            nextCursor: rows.count == messagePageSize
                ? rows.last.map { ChatMessagePageCursor(createdAt: $0.createdAt, id: $0.id) }
                : nil
        )
    }

    func fetchGroupMessage(messageId: UUID) async throws -> GroupMessage {
        try await supabase
            .database("group_messages_view")
            .select("id,group_id,sender_id,content,message_type,metadata,is_deleted,created_at,sender_name,sender_avatar")
            .eq("id", value: messageId.uuidString)
            .single()
            .execute()
            .value
    }

    func observeGroupMessages(
        groupId: UUID,
        onMessage: @escaping (GroupMessage) async -> Void,
        onMessageDeleted: @escaping (UUID) async -> Void,
        onDisconnect: @escaping () -> Void
    ) async throws -> () -> Void {
        try await observeMessageChanges(
            channelName: "group-chat-room-\(groupId.uuidString)",
            table: "group_messages",
            filterColumn: "group_id",
            roomId: groupId,
            fetchMessage: { try await fetchGroupMessage(messageId: $0) },
            onMessage: onMessage,
            onMessageDeleted: onMessageDeleted,
            onDisconnect: onDisconnect
        )
    }

    func observeChatGroupMemberChanges(
        groupId: UUID,
        onChange: @escaping () async -> Void
    ) -> () -> Void {
        let channel = supabase.client.channel("group-members-\(groupId.uuidString)")
        let changes = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "chat_group_members",
            filter: .eq("group_id", value: groupId)
        )
        let task = Task {
            do {
                try await channel.subscribeWithError()
                for await _ in changes {
                    guard !Task.isCancelled else { break }
                    await onChange()
                }
            } catch {
                // Member display names refresh again when the room is reopened.
            }
        }

        return { [supabase] in
            task.cancel()
            Task { await supabase.client.removeChannel(channel) }
        }
    }

    func insertGroupMessage(
        groupId: UUID,
        senderId: UUID,
        content: String,
        messageType: String,
        metadata: MessageMetadata?
    ) async throws -> UUID {
        let inserted: GroupMessageInsertResult = try await supabase
            .database("group_messages")
            .insert(
                GroupMessageInsert(
                    groupId: groupId,
                    senderId: senderId,
                    content: content,
                    messageType: messageType,
                    metadata: metadata
                )
            )
            .select("id")
            .single()
            .execute()
            .value

        return inserted.id
    }

    func deleteDirectMessage(messageId: UUID) async throws {
        try await supabase.client
            .rpc(
                "delete_own_direct_message",
                params: DeleteChatMessageParams(messageID: messageId)
            )
            .execute()
    }

    func deleteGroupMessage(messageId: UUID) async throws {
        try await supabase.client
            .rpc(
                "delete_own_group_message",
                params: DeleteChatMessageParams(messageID: messageId)
            )
            .execute()
    }

    func hideDirectMessage(messageId: UUID) async throws {
        try await supabase.client
            .rpc(
                "hide_direct_message_for_me",
                params: DeleteChatMessageParams(messageID: messageId)
            )
            .execute()
    }

    func hideGroupMessage(messageId: UUID) async throws {
        try await supabase.client
            .rpc(
                "hide_group_message_for_me",
                params: DeleteChatMessageParams(messageID: messageId)
            )
            .execute()
    }

    func fetchConversationPreview(conversationId: UUID, userId: UUID) async throws -> ChatConversationPreview {
        let rows = try await fetchUserConversations(userId: userId)
        if let matched = rows.first(where: { $0.id == conversationId }) {
            return matched
        }

        let conversation: ConversationRow = try await supabase
            .database(Tables.conversations)
            .select("id,user1_id,user2_id,related_post_id,last_message_at,last_message_preview,user1_unread_count,user2_unread_count")
            .eq("id", value: conversationId.uuidString)
            .single()
            .execute()
            .value

        let otherUserId = conversation.user1Id == userId ? conversation.user2Id : conversation.user1Id

        let profile: ProfileLite?
        do {
            profile = try await supabase
                .database("profile_public_view")
                .select("id,full_name,avatar_url")
                .eq("id", value: otherUserId.uuidString)
                .single()
                .execute()
                .value
        } catch {
            profile = nil
        }

        let unreadCount = conversation.user1Id == userId ? conversation.user1UnreadCount : conversation.user2UnreadCount

        return ChatConversationPreview(
            id: conversation.id,
            otherUserId: otherUserId,
            otherUserName: profile?.fullName,
            otherUserAvatar: profile?.avatarURL,
            relatedPostId: conversation.relatedPostId,
            lastMessageAt: conversation.lastMessageAt,
            lastMessagePreview: conversation.lastMessagePreview,
            unreadCount: unreadCount
        )
    }

    func fetchGroupPreview(groupId: UUID, userId: UUID) async throws -> ChatGroupPreview {
        if let matched = (try await fetchUserChatGroups(userId: userId)).first(where: { $0.id == groupId }) {
            return matched
        }

        let group: ChatGroupFallbackRow = try await supabase
            .database("chat_groups")
            .select("id,name,avatar_url,updated_at")
            .eq("id", value: groupId.uuidString)
            .single()
            .execute()
            .value

        let members: [ChatGroupMemberCountRow] = try await supabase
            .database("chat_group_members")
            .select("user_id")
            .eq("group_id", value: groupId.uuidString)
            .execute()
            .value

        let lastMessage: GroupMessagePreviewRow? = try? await supabase
            .database("group_messages")
            .select("created_at,content,message_type")
            .eq("group_id", value: groupId.uuidString)
            .eq("is_deleted", value: false)
            .order("created_at", ascending: false)
            .limit(1)
            .single()
            .execute()
            .value

        return ChatGroupPreview(
            id: group.id,
            name: group.name,
            avatarURL: group.avatarURL,
            lastMessageAt: lastMessage?.createdAt ?? group.updatedAt,
            lastMessagePreview: groupPreviewContent(from: lastMessage),
            memberCount: max(members.count, 1),
            unreadCount: 0,
            isMuted: false
        )
    }

    func getOrCreateConversationId(
        currentUserId: UUID,
        otherUserId: UUID,
        relatedPostId: UUID?
    ) async throws -> UUID {
        let conversationId: UUID = try await supabase.client
            .rpc(
                "get_or_create_conversation",
                params: ChatGetOrCreateConversationParams(
                    pUserId: currentUserId,
                    pOtherUserId: otherUserId,
                    pRelatedPostId: relatedPostId
                )
            )
            .execute()
            .value

        if relatedPostId != nil {
            _ = try? await supabase
                .database(Tables.conversations)
                .update(
                    ConversationRelatedPostUpdate(
                        relatedPostId: relatedPostId?.uuidString
                    )
                )
                .eq("id", value: conversationId.uuidString)
                .execute()
        }

        return conversationId
    }

    func fetchMutualFollowProfiles(userId: UUID, limit: Int = 50) async throws -> [MutualFollowProfile] {
        let rows: [MutualFollowProfile] = try await supabase.client
            .rpc(
                "get_mutual_follow_profiles",
                params: ChatGetMutualFollowProfilesParams(
                    pUserId: userId,
                    pLimit: max(1, min(limit, 200))
                )
            )
            .execute()
            .value

        return rows
    }

    func createChatGroup(name: String, memberIds: [UUID]) async throws -> UUID {
        try await supabase.client
            .rpc(
                "create_chat_group",
                params: ChatCreateChatGroupParams(
                    pName: name,
                    pMemberIds: memberIds
                )
            )
            .execute()
            .value
    }

    func renameChatGroup(groupId: UUID, name: String) async throws {
        try await supabase.client
            .rpc("rename_chat_group", params: ChatRenameGroupParams(groupID: groupId, name: name))
            .execute()
    }

    func fetchChatGroupAnnouncement(groupId: UUID) async throws -> String? {
        let row: ChatGroupAnnouncementRow = try await supabase
            .database("chat_groups")
            .select("announcement")
            .eq("id", value: groupId.uuidString)
            .single()
            .execute()
            .value
        return row.announcement?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func updateChatGroupAnnouncement(groupId: UUID, announcement: String?) async throws {
        try await supabase.client
            .rpc(
                "update_chat_group_announcement",
                params: ChatUpdateGroupAnnouncementParams(
                    groupID: groupId,
                    announcement: announcement
                )
            )
            .execute()
    }

    func addChatGroupMembers(groupId: UUID, memberIds: [UUID]) async throws -> Int {
        try await supabase.client
            .rpc(
                "add_chat_group_members",
                params: ChatAddGroupMembersParams(groupID: groupId, memberIDs: memberIds)
            )
            .execute()
            .value
    }

    func updateMyChatGroupNickname(groupId: UUID, nickname: String?) async throws {
        try await supabase.client
            .rpc(
                "update_my_chat_group_nickname",
                params: ChatUpdateGroupNicknameParams(groupID: groupId, nickname: nickname)
            )
            .execute()
    }

    func fetchChatGroupMembers(groupId: UUID) async throws -> [ChatGroupMemberSummary] {
        let rows: [ChatGroupMemberRpcRow] = try await supabase.client
            .rpc(
                "get_chat_group_members",
                params: ChatGetChatGroupMembersParams(pGroupId: groupId)
            )
            .execute()
            .value

        return rows.map {
            ChatGroupMemberSummary(
                id: $0.userId,
                displayName: resolvedDisplayName(fullName: $0.nickname ?? $0.fullName),
                avatarURL: $0.avatarURL,
                role: $0.role,
                joinedAt: $0.joinedAt,
                nickname: $0.nickname
            )
        }
    }

    func fetchChatGroupOwnerId(groupId: UUID) async throws -> UUID {
        let row: ChatGroupOwnerRow = try await supabase
            .database("chat_groups")
            .select("owner_id")
            .eq("id", value: groupId.uuidString)
            .single()
            .execute()
            .value
        return row.ownerId
    }

    func leaveChatGroup(groupId: UUID) async throws -> Bool {
        try await supabase.client
            .rpc(
                "leave_chat_group",
                params: ChatLeaveChatGroupParams(pGroupId: groupId)
            )
            .execute()
            .value
    }

    func fetchChatGroupMemberRole(groupId: UUID, userId: UUID) async throws -> String? {
        let rows: [ChatGroupMemberRoleRow] = try await supabase
            .database("chat_group_members")
            .select("role")
            .eq("group_id", value: groupId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first?.role
    }

    func deleteChatGroupMember(groupId: UUID, userId: UUID) async throws {
        try await supabase
            .database("chat_group_members")
            .delete()
            .eq("group_id", value: groupId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .execute()
    }

    private func fetchUserConversations(userId: UUID) async throws -> [ChatConversationPreview] {
        let rows: [ChatConversationPreview] = try await supabase.client
            .rpc("get_user_conversations", params: ChatGetUserConversationsParams(pUserId: userId))
            .execute()
            .value

        return rows.sorted { lhs, rhs in
            lhs.lastMessageAt > rhs.lastMessageAt
        }
    }

    private func fetchUserChatGroups(userId: UUID) async throws -> [ChatGroupPreview] {
        let rows: [ChatGroupPreview] = try await supabase.client
            .rpc("get_user_chat_groups", params: ChatGetUserChatGroupsParams(pUserId: userId))
            .execute()
            .value

        return stateUpdater.sortGroupConversations(rows)
    }

    private func groupPreviewContent(from message: GroupMessagePreviewRow?) -> String? {
        guard let message else { return nil }
        if message.messageType == "image" {
            return "📷 Photo"
        }
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
    }

    private func fetchConversationId(user1Id: UUID, user2Id: UUID) async throws -> UUID? {
        let rows: [ConversationInsertResult] = try await supabase
            .database(Tables.conversations)
            .select("id")
            .eq("user1_id", value: user1Id.uuidString)
            .eq("user2_id", value: user2Id.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first?.id
    }

    private func observeMessageChanges<MessageType>(
        channelName: String,
        table: String,
        filterColumn: String,
        roomId: UUID,
        fetchMessage: @escaping (UUID) async throws -> MessageType,
        onMessage: @escaping (MessageType) async -> Void,
        onMessageDeleted: @escaping (UUID) async -> Void,
        onDisconnect: @escaping () -> Void
    ) async throws -> () -> Void {
        let channel = supabase.client.channel(channelName)
        let changes = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: table,
            filter: .eq(filterColumn, value: roomId)
        )

        try await channel.subscribeWithError()

        let task = Task {
            for await change in changes {
                guard !Task.isCancelled else { break }
                switch change {
                case .insert(let insert):
                    guard let messageID = chatMessageID(in: insert.record),
                          let message = try? await fetchMessage(messageID)
                    else { continue }
                    await onMessage(message)
                case .update(let update):
                    guard update.record["is_deleted"]?.boolValue == true,
                          let messageID = chatMessageID(in: update.record)
                    else { continue }
                    await onMessageDeleted(messageID)
                case .delete(let delete):
                    guard let messageID = chatMessageID(in: delete.oldRecord) else { continue }
                    await onMessageDeleted(messageID)
                }
            }
        }

        let statusTask = Task {
            for await status in channel.statusChange {
                guard !Task.isCancelled else { return }
                if status == .unsubscribed {
                    onDisconnect()
                    return
                }
            }
        }

        return { [supabase] in
            task.cancel()
            statusTask.cancel()
            Task { await supabase.client.removeChannel(channel) }
        }
    }

    private func chatMessageID(in record: [String: AnyJSON]) -> UUID? {
        guard let idString = record["id"]?.stringValue else { return nil }
        return UUID(uuidString: idString)
    }

    private func orderedConversationUsers(_ lhs: UUID, _ rhs: UUID) -> (UUID, UUID) {
        if lhs.uuidString < rhs.uuidString {
            return (lhs, rhs)
        }
        return (rhs, lhs)
    }

    private func resolvedDisplayName(fullName: String?) -> String {
        if let fullName = fullName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fullName.isEmpty {
            return fullName
        }
        return "已注销"
    }

}

private struct ConversationRelatedPostUpdate: Encodable {
    let relatedPostId: String?

    enum CodingKeys: String, CodingKey {
        case relatedPostId = "related_post_id"
    }
}

private struct DirectMessagePageParams: Encodable {
    let conversationID: UUID
    let beforeCreatedAt: Date?
    let beforeID: UUID?
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case conversationID = "p_conversation_id"
        case beforeCreatedAt = "p_before_created_at"
        case beforeID = "p_before_id"
        case limit = "p_limit"
    }
}

private struct GroupMessagePageParams: Encodable {
    let groupID: UUID
    let beforeCreatedAt: Date?
    let beforeID: UUID?
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case groupID = "p_group_id"
        case beforeCreatedAt = "p_before_created_at"
        case beforeID = "p_before_id"
        case limit = "p_limit"
    }
}

private struct LinkedPostCardLookupParams: Encodable {
    let conversationID: UUID
    let postKind: String
    let postID: UUID

    enum CodingKeys: String, CodingKey {
        case conversationID = "p_conversation_id"
        case postKind = "p_post_kind"
        case postID = "p_post_id"
    }
}

private struct SecondhandChatIntentParams: Encodable {
    let conversationID: UUID

    enum CodingKeys: String, CodingKey {
        case conversationID = "p_conversation_id"
    }
}

private struct ChatRenameGroupParams: Encodable {
    let groupID: UUID
    let name: String
    enum CodingKeys: String, CodingKey {
        case groupID = "p_group_id"
        case name = "p_name"
    }
}

private struct ChatAddGroupMembersParams: Encodable {
    let groupID: UUID
    let memberIDs: [UUID]
    enum CodingKeys: String, CodingKey {
        case groupID = "p_group_id"
        case memberIDs = "p_member_ids"
    }
}

private struct ChatUpdateGroupNicknameParams: Encodable {
    let groupID: UUID
    let nickname: String?

    enum CodingKeys: String, CodingKey {
        case groupID = "p_group_id"
        case nickname = "p_nickname"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(groupID, forKey: .groupID)
        if let nickname {
            try container.encode(nickname, forKey: .nickname)
        } else {
            // PostgREST RPC needs an explicit JSON null to clear the nickname.
            // Synthesized Optional encoding would omit p_nickname entirely.
            try container.encodeNil(forKey: .nickname)
        }
    }
}

private struct ChatUpdateGroupAnnouncementParams: Encodable {
    let groupID: UUID
    let announcement: String?

    enum CodingKeys: String, CodingKey {
        case groupID = "p_group_id"
        case announcement = "p_announcement"
    }
}

private struct SecondhandListingParams: Encodable {
    let listingID: UUID

    enum CodingKeys: String, CodingKey {
        case listingID = "p_listing_id"
    }
}

private struct SecondhandIntentActionParams: Encodable {
    let intentID: UUID

    enum CodingKeys: String, CodingKey {
        case intentID = "p_intent_id"
    }
}

private struct CompleteSecondhandSaleParams: Encodable {
    let listingID: UUID
    let buyerID: UUID

    enum CodingKeys: String, CodingKey {
        case listingID = "p_listing_id"
        case buyerID = "p_buyer_id"
    }
}

private struct MessageInsert: Encodable {
    let conversationId: UUID
    let senderId: UUID
    let content: String
    let messageType: String
    let metadata: MessageMetadata?

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case senderId = "sender_id"
        case content
        case messageType = "message_type"
        case metadata
    }
}

private struct GroupMessageInsert: Encodable {
    let groupId: UUID
    let senderId: UUID
    let content: String
    let messageType: String
    let metadata: MessageMetadata?

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case senderId = "sender_id"
        case content
        case messageType = "message_type"
        case metadata
    }
}

private struct GroupMessageInsertResult: Decodable {
    let id: UUID
}

private struct DeleteChatMessageParams: Encodable {
    let messageID: UUID

    enum CodingKeys: String, CodingKey {
        case messageID = "p_message_id"
    }
}
