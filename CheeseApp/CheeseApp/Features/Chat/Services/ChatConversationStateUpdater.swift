//
//  ChatConversationStateUpdater.swift
//  CheeseApp
//
//  Feature-owned local chat list mutations and ordering rules.
//

import Foundation

struct ChatConversationStateUpdater {
    private let timestampTolerance: TimeInterval

    init(timestampTolerance: TimeInterval = 1) {
        self.timestampTolerance = timestampTolerance
    }

    func applyMuteState(
        to previews: [ChatConversationPreview],
        mutedConversationIDs: Set<UUID>
    ) -> [ChatConversationPreview] {
        previews.map { preview in
            var updated = preview
            updated.isMuted = mutedConversationIDs.contains(preview.id)
            return updated
        }
    }

    func applyConversationListState(
        to previews: [ChatConversationPreview],
        manualUnreadConversationIDs: Set<UUID>,
        hiddenConversationUntilMap: [UUID: Date]
    ) -> [ChatConversationPreview] {
        previews.compactMap { preview in
            if let hiddenUntil = hiddenConversationUntilMap[preview.id],
               preview.lastMessageAt <= hiddenUntil.addingTimeInterval(timestampTolerance) {
                return nil
            }

            var updated = preview
            if manualUnreadConversationIDs.contains(preview.id) {
                updated.unreadCount = max(updated.unreadCount, 1)
            }
            return updated
        }
    }

    func applyClearHistoryToPreviews(
        _ previews: [ChatConversationPreview],
        clearMap: [UUID: Date]
    ) -> [ChatConversationPreview] {
        previews.map { preview in
            guard let clearBeforeAt = clearMap[preview.id],
                  preview.lastMessageAt <= clearBeforeAt.addingTimeInterval(timestampTolerance)
            else {
                return preview
            }

            return ChatConversationPreview(
                id: preview.id,
                otherUserId: preview.otherUserId,
                otherUserName: preview.otherUserName,
                otherUserAvatar: preview.otherUserAvatar,
                relatedPostId: preview.relatedPostId,
                lastMessageAt: preview.lastMessageAt,
                lastMessagePreview: nil,
                unreadCount: 0,
                isMuted: preview.isMuted
            )
        }
    }

    func markConversationRead(
        conversationId: UUID,
        conversations: inout [ChatConversationPreview]
    ) {
        if let index = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[index].unreadCount = 0
        }
    }

    func markConversationUnread(
        conversationId: UUID,
        conversations: inout [ChatConversationPreview]
    ) {
        if let index = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[index].unreadCount = max(1, conversations[index].unreadCount)
        }
    }

    func setConversationMuted(
        conversationId: UUID,
        isMuted: Bool,
        conversations: inout [ChatConversationPreview]
    ) {
        if let index = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[index].isMuted = isMuted
        }
    }

    func clearConversationPreview(
        conversationId: UUID,
        conversations: inout [ChatConversationPreview]
    ) {
        if let index = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[index] = clearedConversationPreview(from: conversations[index])
        }
    }

    func removeConversation(
        conversationId: UUID,
        conversations: inout [ChatConversationPreview]
    ) {
        conversations.removeAll { $0.id == conversationId }
    }

    func upsertConversation(
        _ preview: ChatConversationPreview,
        conversations: inout [ChatConversationPreview]
    ) {
        var preview = preview
        if let existing = conversations.first(where: { $0.id == preview.id }) {
            preview.isMuted = existing.isMuted
        }

        if let index = conversations.firstIndex(where: { $0.id == preview.id }) {
            conversations[index] = preview
        } else {
            conversations.insert(preview, at: 0)
        }

        conversations.sort { lhs, rhs in
            lhs.lastMessageAt > rhs.lastMessageAt
        }
    }

    func applyGroupMuteState(
        to previews: [ChatGroupPreview],
        mutedGroupIDs: Set<UUID>
    ) -> [ChatGroupPreview] {
        sortGroupConversations(previews.map { preview in
            var updated = preview
            updated.isMuted = mutedGroupIDs.contains(preview.id)
            return updated
        })
    }

    func setGroupConversationMuted(
        groupId: UUID,
        isMuted: Bool,
        groupConversations: inout [ChatGroupPreview]
    ) {
        if let index = groupConversations.firstIndex(where: { $0.id == groupId }) {
            groupConversations[index].isMuted = isMuted
        }
    }

    func setGroupConversationUnreadCount(
        groupId: UUID,
        unreadCount: Int,
        groupConversations: inout [ChatGroupPreview]
    ) {
        guard let index = groupConversations.firstIndex(where: { $0.id == groupId }) else { return }
        groupConversations[index].unreadCount = max(0, unreadCount)
    }

    func upsertGroupConversation(
        _ preview: ChatGroupPreview,
        groupConversations: inout [ChatGroupPreview]
    ) {
        if let index = groupConversations.firstIndex(where: { $0.id == preview.id }) {
            groupConversations[index] = preview
        } else {
            groupConversations.insert(preview, at: 0)
        }

        groupConversations = sortGroupConversations(groupConversations)
    }

    func sortGroupConversations(_ previews: [ChatGroupPreview]) -> [ChatGroupPreview] {
        previews.sorted(by: compareGroupConversations)
    }

    private func clearedConversationPreview(from preview: ChatConversationPreview) -> ChatConversationPreview {
        ChatConversationPreview(
            id: preview.id,
            otherUserId: preview.otherUserId,
            otherUserName: preview.otherUserName,
            otherUserAvatar: preview.otherUserAvatar,
            relatedPostId: preview.relatedPostId,
            lastMessageAt: preview.lastMessageAt,
            lastMessagePreview: nil,
            unreadCount: 0,
            isMuted: preview.isMuted
        )
    }

    private func compareGroupConversations(_ lhs: ChatGroupPreview, _ rhs: ChatGroupPreview) -> Bool {
        if lhs.lastMessageAt != rhs.lastMessageAt {
            return lhs.lastMessageAt > rhs.lastMessageAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}
