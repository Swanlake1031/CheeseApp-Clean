//
//  ChatService.swift
//  CheeseApp
//
//  🎯 Feature-owned 聊天服务
//

import Foundation

struct DirectConversationSettings: Hashable {
    let isMuted: Bool
    let clearBeforeAt: Date?
    let manualUnread: Bool
    let hideUntilAt: Date?

    static let `default` = DirectConversationSettings(
        isMuted: false,
        clearBeforeAt: nil,
        manualUnread: false,
        hideUntilAt: nil
    )
}

struct GroupConversationSettings: Hashable {
    let isMuted: Bool

    static let `default` = GroupConversationSettings(isMuted: false)
}

struct ChatConversationListSettingsSnapshot {
    let mutedConversationIDs: Set<UUID>
    let manualUnreadConversationIDs: Set<UUID>
    let hiddenConversationUntilMap: [UUID: Date]
    let clearBeforeMap: [UUID: Date]
}

struct ChatGroupMemberSummary: Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let avatarURL: String?
    let role: String
    let joinedAt: Date?

    var roleLabel: String {
        role == "owner" ? "群主" : "成员"
    }
}

struct BlockedUserSummary: Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let avatarURL: String?
    let blockedAt: Date
}

struct UserBlockRelation: Hashable {
    let isBlockedByMe: Bool
    let isBlockedByOther: Bool

    var isEitherBlocked: Bool {
        isBlockedByMe || isBlockedByOther
    }

    static let none = UserBlockRelation(
        isBlockedByMe: false,
        isBlockedByOther: false
    )
}

@MainActor
class ChatService: ObservableObject {
    typealias CurrentUserIDProvider = () async throws -> UUID
    typealias ConversationStateLoader = (UUID) async throws -> ChatConversationRepositorySnapshot

    static let shared = ChatService()
    
    @Published var conversations: [ChatConversationPreview] = []
    @Published var messageRequests: [ChatConversationPreview] = []
    @Published var groupConversations: [ChatGroupPreview] = []
    @Published private(set) var conversationRemarks: [UUID: String] = [:]
    @Published var isLoadingConversations = false
    @Published var conversationErrorMessage: String?
    @Published private(set) var hasResolvedInitialConversationLoad = false
    @Published private(set) var accountGeneration: UInt64 = 0
    @Published private(set) var isAccountTransitionInProgress = false
    
    private let defaults = UserDefaults.standard
    private let repository = ChatServiceRepository()
    private let privacyActions = ChatPrivacyActions()
    private let stateUpdater = ChatConversationStateUpdater()
    private let conversationRemarksKeyPrefix = "chat.conversation.remarks."
    private let currentUserIDProvider: CurrentUserIDProvider
    private let injectedConversationStateLoader: ConversationStateLoader?
    private var remarksOwnerId: UUID?
    private var stateOwnerID: UUID?

    private init() {
        currentUserIDProvider = {
            try await AuthService.shared.requireAuthUserId()
        }
        injectedConversationStateLoader = nil
    }

    init(
        currentUserIDProvider: @escaping CurrentUserIDProvider,
        conversationStateLoader: @escaping ConversationStateLoader
    ) {
        self.currentUserIDProvider = currentUserIDProvider
        injectedConversationStateLoader = conversationStateLoader
    }

    var isAccountScopeReady: Bool {
        !isAccountTransitionInProgress && stateOwnerID != nil
    }

    func beginAccountTransition() {
        isAccountTransitionInProgress = true
        resetAccountScopedState(ownerID: nil)
    }

    func activateAccount(_ userID: UUID?) {
        let mustReset = isAccountTransitionInProgress || stateOwnerID != userID
        isAccountTransitionInProgress = false
        guard mustReset else { return }
        resetAccountScopedState(ownerID: userID)
    }

    private func resetAccountScopedState(ownerID: UUID?) {
        accountGeneration &+= 1
        stateOwnerID = ownerID
        conversations = []
        messageRequests = []
        groupConversations = []
        conversationRemarks = [:]
        remarksOwnerId = nil
        isLoadingConversations = false
        conversationErrorMessage = nil
        hasResolvedInitialConversationLoad = false
        RemoteImageCache.shared.removeAll()
    }

    private func isCurrentAccountRequest(userID: UUID, generation: UInt64) -> Bool {
        !isAccountTransitionInProgress
            && stateOwnerID == userID
            && accountGeneration == generation
    }

    private func requestGeneration(for userID: UUID) -> UInt64? {
        guard !isAccountTransitionInProgress,
              stateOwnerID == userID
        else { return nil }
        return accountGeneration
    }

    var conversationListState: CollectionLoadState {
        CollectionLoadState.resolve(
            hasResolvedInitialLoad: hasResolvedInitialConversationLoad,
            isLoading: isLoadingConversations,
            hasContent: !conversations.isEmpty || !messageRequests.isEmpty || !groupConversations.isEmpty,
            errorMessage: conversationErrorMessage
        )
    }

    func conversationRemark(for conversationId: UUID) -> String? {
        sanitizedOptionalText(conversationRemarks[conversationId])
    }

    func displayName(for conversation: ChatConversationPreview) -> String {
        conversationRemark(for: conversation.id) ?? conversation.displayName
    }

    func setConversationRemark(conversationId: UUID, remark: String?) {
        guard let userId = AuthService.shared.currentUser?.id else { return }
        ensureConversationRemarksLoaded(for: userId)

        if let normalized = sanitizedOptionalText(remark) {
            conversationRemarks[conversationId] = normalized
        } else {
            conversationRemarks.removeValue(forKey: conversationId)
        }
        persistConversationRemarks(for: userId)
    }

    private func ensureConversationRemarksLoaded(for userId: UUID) {
        if remarksOwnerId == userId { return }

        let key = conversationRemarksStorageKey(for: userId)
        guard let data = defaults.data(forKey: key),
              let rawMap = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            conversationRemarks = [:]
            remarksOwnerId = userId
            return
        }

        var resolved: [UUID: String] = [:]
        for (idString, remark) in rawMap {
            guard let id = UUID(uuidString: idString) else { continue }
            guard let normalized = sanitizedOptionalText(remark) else { continue }
            resolved[id] = normalized
        }
        conversationRemarks = resolved
        remarksOwnerId = userId
    }

    private func persistConversationRemarks(for userId: UUID) {
        var rawMap: [String: String] = [:]
        for (conversationId, value) in conversationRemarks {
            guard let normalized = sanitizedOptionalText(value) else { continue }
            rawMap[conversationId.uuidString] = normalized
        }
        let key = conversationRemarksStorageKey(for: userId)

        if rawMap.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }

        if let data = try? JSONEncoder().encode(rawMap) {
            defaults.set(data, forKey: key)
        }
    }

    private func conversationRemarksStorageKey(for userId: UUID) -> String {
        conversationRemarksKeyPrefix + userId.uuidString
    }

    func refreshConversations() async {
        guard !isAccountTransitionInProgress,
              stateOwnerID != nil,
              !isLoadingConversations
        else { return }

        let requestGeneration = accountGeneration
        isLoadingConversations = true
        conversationErrorMessage = nil
        defer {
            if accountGeneration == requestGeneration {
                isLoadingConversations = false
            }
        }

        do {
            let userId = try await currentUserIDProvider()
            guard isCurrentAccountRequest(
                userID: userId,
                generation: requestGeneration
            ) else { return }

            ensureConversationRemarksLoaded(for: userId)
            let snapshot = try await loadConversationState(userID: userId)

            guard isCurrentAccountRequest(
                userID: userId,
                generation: requestGeneration
            ) else { return }

            conversations = snapshot.directConversations
            messageRequests = snapshot.messageRequests
            groupConversations = snapshot.groupConversations
            hasResolvedInitialConversationLoad = true
        } catch {
            guard accountGeneration == requestGeneration,
                  !isAccountTransitionInProgress
            else { return }

            // SwiftUI cancels view-scoped tasks during navigation and account-boundary
            // reconstruction. Cancellation is lifecycle control, not a failed inbox load;
            // publishing it as an error replaced otherwise valid/empty content with the
            // user-facing "cancelled" retry screen.
            guard !Task.isCancelled else { return }

            conversationErrorMessage = error.isCancellationLike
                ? "连接中断，请重试。"
                : error.localizedDescription
            hasResolvedInitialConversationLoad = true
        }
    }

    private func loadConversationState(
        userID: UUID
    ) async throws -> ChatConversationRepositorySnapshot {
        if let injectedConversationStateLoader {
            return try await injectedConversationStateLoader(userID)
        }

        // Resolve the three list endpoints as one atomic snapshot first. The previous
        // implementation also launched five settings requests at the same time (including
        // duplicate reads of user_conversation_settings), which could overload the mobile
        // connection and cancel part of the refresh.
        let snapshot = try await repository.fetchConversationSnapshot(userId: userID)

        async let conversationSettingsTask = privacyActions.fetchConversationListSettings(
            userId: userID
        )
        async let mutedGroupTask = privacyActions.fetchMutedGroupIDs(userId: userID)

        let conversationSettings = try await conversationSettingsTask
        let mutedGroupIDs = try await mutedGroupTask
        let directConversations = stateUpdater.applyClearHistoryToPreviews(
            snapshot.directConversations,
            clearMap: conversationSettings.clearBeforeMap
        )
        let messageRequests = stateUpdater.applyClearHistoryToPreviews(
            snapshot.messageRequests,
            clearMap: conversationSettings.clearBeforeMap
        )
        let requests = stateUpdater.applyConversationListState(
            to: stateUpdater.applyMuteState(
                to: messageRequests,
                mutedConversationIDs: conversationSettings.mutedConversationIDs
            ),
            manualUnreadConversationIDs: conversationSettings.manualUnreadConversationIDs,
            hiddenConversationUntilMap: conversationSettings.hiddenConversationUntilMap
        )
        let requestIDs = Set(requests.map(\.id))

        return ChatConversationRepositorySnapshot(
            directConversations: stateUpdater.applyConversationListState(
                to: stateUpdater.applyMuteState(
                    to: directConversations.filter {
                        !requestIDs.contains($0.id)
                    },
                    mutedConversationIDs: conversationSettings.mutedConversationIDs
                ),
                manualUnreadConversationIDs: conversationSettings.manualUnreadConversationIDs,
                hiddenConversationUntilMap: conversationSettings.hiddenConversationUntilMap
            ),
            messageRequests: requests,
            groupConversations: stateUpdater.applyGroupMuteState(
                to: snapshot.groupConversations,
                mutedGroupIDs: mutedGroupIDs
            )
        )
    }

    func getOrCreateConversation(otherUserId: UUID, relatedPostId: UUID?) async throws -> ChatConversationPreview {
        let currentUserId = try await AuthService.shared.requireAuthUserId()
        guard let requestGeneration = requestGeneration(for: currentUserId) else {
            throw CancellationError()
        }

        guard otherUserId != currentUserId else {
            throw NSError(
                domain: "",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "不能和自己发起聊天。"]
            )
        }

        let blockRelation = await privacyActions.fetchBlockRelation(with: otherUserId)

        if blockRelation.isEitherBlocked {
            if let existingId = try? await repository.getOrCreateConversationId(
                currentUserId: currentUserId,
                otherUserId: otherUserId,
                relatedPostId: relatedPostId
            ) {
                let preview = try await repository.fetchConversationPreview(
                    conversationId: existingId,
                    userId: currentUserId
                )
                guard isCurrentAccountRequest(
                    userID: currentUserId,
                    generation: requestGeneration
                ) else { return preview }
                stateUpdater.upsertConversation(
                    preview,
                    conversations: &conversations,
                    messageRequests: &messageRequests
                )
                return preview
            }

            let localizedDescription: String
            if blockRelation.isBlockedByOther {
                localizedDescription = "对方已将你拉黑，无法发起新的私信。"
            } else {
                localizedDescription = "你已拉黑该用户，解除拉黑后可重新发起私信。"
            }

            throw NSError(
                domain: "",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: localizedDescription]
            )
        }

        let conversationId = try await repository.getOrCreateConversationId(
            currentUserId: currentUserId,
            otherUserId: otherUserId,
            relatedPostId: relatedPostId
        )

        let preview = try await repository.fetchConversationPreview(
            conversationId: conversationId,
            userId: currentUserId
        )
        guard isCurrentAccountRequest(
            userID: currentUserId,
            generation: requestGeneration
        ) else { return preview }
        stateUpdater.upsertConversation(
            preview,
            conversations: &conversations,
            messageRequests: &messageRequests
        )
        return preview
    }

    func fetchMessages(conversationId: UUID) async throws -> [Message] {
        try await repository.fetchMessages(conversationId: conversationId)
    }

    func fetchMessagesPage(
        conversationId: UUID,
        before cursor: ChatMessagePageCursor? = nil
    ) async throws -> ChatMessagePage<Message> {
        try await repository.fetchMessagesPage(
            conversationId: conversationId,
            before: cursor
        )
    }

    func fetchConversationPreview(conversationId: UUID) async throws -> ChatConversationPreview {
        let userId = try await AuthService.shared.requireAuthUserId()
        guard let requestGeneration = requestGeneration(for: userId) else {
            throw CancellationError()
        }
        let preview = try await repository.fetchConversationPreview(
            conversationId: conversationId,
            userId: userId
        )
        guard isCurrentAccountRequest(
            userID: userId,
            generation: requestGeneration
        ) else { return preview }
        stateUpdater.upsertConversation(
            preview,
            conversations: &conversations,
            messageRequests: &messageRequests
        )
        return preview
    }

    func sendMessage(
        conversationId: UUID,
        content: String,
        quotedMessage: QuotedMessageMetadata? = nil
    ) async throws -> Message {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "消息不能为空。"]
            )
        }

        return try await sendMessage(
            conversationId: conversationId,
            content: trimmed,
            messageType: "text",
            metadata: quotedMessage.map {
                MessageMetadata(
                    imageURL: nil,
                    sharedPostCard: nil,
                    postContactCard: nil,
                    quotedMessage: $0
                )
            }
        )
    }

    func sendImageMessage(
        conversationId: UUID,
        media: ChatMediaReference
    ) async throws -> Message {
        guard media.belongs(to: .direct, id: conversationId) else {
            throw NSError(
                domain: "",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "聊天图片路径无效。"]
            )
        }

        return try await sendMessage(
            conversationId: conversationId,
            content: "📷 Photo",
            messageType: "image",
            metadata: MessageMetadata(
                imageURL: nil,
                sharedPostCard: nil,
                postContactCard: nil,
                imageBucket: media.bucket,
                imageObjectPath: media.objectPath,
                imageScope: media.scope.rawValue,
                imageScopeID: media.scopeID
            )
        )
    }

    func sendPostContactCardMessage(
        conversationId: UUID,
        card: PostContactCardMetadata
    ) async throws -> Message {
        if let postId = card.postId,
           let postKind = PostKind(remoteValue: card.postKind) {
            try await assertCanSendPostLinkedCard(
                conversationId: conversationId,
                postKind: postKind,
                postId: postId
            )
        }

        return try await sendMessage(
            conversationId: conversationId,
            content: "Post contact card",
            messageType: "text",
            metadata: MessageMetadata(
                imageURL: nil,
                sharedPostCard: nil,
                postContactCard: card
            )
        )
    }

    func sendSharedPostCardMessage(
        conversationId: UUID,
        card: SharedPostCardMetadata
    ) async throws -> Message {
        try await sendMessage(
            conversationId: conversationId,
            content: "Shared a post",
            messageType: "text",
            metadata: MessageMetadata(
                imageURL: nil,
                sharedPostCard: card,
                postContactCard: nil
            )
        )
    }

    func fetchGroupPreview(groupId: UUID) async throws -> ChatGroupPreview {
        let userId = try await AuthService.shared.requireAuthUserId()
        guard let requestGeneration = requestGeneration(for: userId) else {
            throw CancellationError()
        }
        let preview = try await repository.fetchGroupPreview(groupId: groupId, userId: userId)
        guard isCurrentAccountRequest(
            userID: userId,
            generation: requestGeneration
        ) else { return preview }
        stateUpdater.upsertGroupConversation(preview, groupConversations: &groupConversations)
        return preview
    }

    func sendGroupMessage(
        groupId: UUID,
        content: String,
        quotedMessage: QuotedMessageMetadata? = nil
    ) async throws -> GroupMessage {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "消息不能为空。"]
            )
        }

        return try await sendGroupMessage(
            groupId: groupId,
            content: trimmed,
            messageType: "text",
            metadata: quotedMessage.map {
                MessageMetadata(
                    imageURL: nil,
                    sharedPostCard: nil,
                    postContactCard: nil,
                    quotedMessage: $0
                )
            }
        )
    }

    func deleteDirectMessage(messageId: UUID, forEveryone: Bool) async throws {
        if forEveryone {
            try await repository.deleteDirectMessage(messageId: messageId)
        } else {
            try await repository.hideDirectMessage(messageId: messageId)
        }
    }

    func deleteGroupMessage(messageId: UUID, forEveryone: Bool) async throws {
        if forEveryone {
            try await repository.deleteGroupMessage(messageId: messageId)
        } else {
            try await repository.hideGroupMessage(messageId: messageId)
        }
    }

    func sendGroupImageMessage(
        groupId: UUID,
        media: ChatMediaReference
    ) async throws -> GroupMessage {
        guard media.belongs(to: .group, id: groupId) else {
            throw NSError(
                domain: "",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "群聊图片路径无效。"]
            )
        }

        return try await sendGroupMessage(
            groupId: groupId,
            content: "📷 Photo",
            messageType: "image",
            metadata: MessageMetadata(
                imageURL: nil,
                sharedPostCard: nil,
                postContactCard: nil,
                imageBucket: media.bucket,
                imageObjectPath: media.objectPath,
                imageScope: media.scope.rawValue,
                imageScopeID: media.scopeID
            )
        )
    }

    func sendGroupSharedPostCardMessage(
        groupId: UUID,
        card: SharedPostCardMetadata
    ) async throws -> GroupMessage {
        try await sendGroupMessage(
            groupId: groupId,
            content: "Shared a post",
            messageType: "text",
            metadata: MessageMetadata(
                imageURL: nil,
                sharedPostCard: card,
                postContactCard: nil
            )
        )
    }

    func fetchMutualFollowProfiles(limit: Int = 50) async throws -> [MutualFollowProfile] {
        let userId = try await AuthService.shared.requireAuthUserId()
        return try await repository.fetchMutualFollowProfiles(userId: userId, limit: limit)
    }

    func hasSentPostLinkedCard(
        to otherUserId: UUID,
        postKind: PostKind,
        postId: UUID
    ) async throws -> Bool {
        let currentUserId = try await AuthService.shared.requireAuthUserId()
        guard currentUserId != otherUserId else { return false }
        guard let conversationId = try await repository.findExistingConversationId(
            currentUserId: currentUserId,
            otherUserId: otherUserId
        ) else {
            return false
        }

        return try await repository.hasSentPostLinkedCard(
            conversationId: conversationId,
            postKind: postKind,
            postId: postId
        )
    }

    func ensureCanSendPostLinkedCard(
        to otherUserId: UUID,
        postKind: PostKind,
        postId: UUID
    ) async throws {
        if try await hasSentPostLinkedCard(to: otherUserId, postKind: postKind, postId: postId) {
            throw duplicatePostLinkedCardError(for: postKind)
        }
    }

    func createChatGroup(name: String, memberIds: [UUID]) async throws -> ChatGroupPreview {
        let userId = try await AuthService.shared.requireAuthUserId()
        guard let requestGeneration = requestGeneration(for: userId) else {
            throw CancellationError()
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw NSError(
                domain: "",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "群聊名称不能为空。"]
            )
        }

        let uniqueMembers = Array(Set(memberIds.filter { $0 != userId }))
        guard uniqueMembers.count >= 1 else {
            throw NSError(
                domain: "",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "请至少选择 1 位互关好友。"]
            )
        }

        for memberId in uniqueMembers {
            let relation = await fetchBlockRelation(with: memberId)
            if relation.isEitherBlocked {
                throw NSError(
                    domain: "",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: "存在拉黑关系，无法创建群聊。请先解除拉黑后重试。"]
                )
            }
        }

        let groupId = try await repository.createChatGroup(
            name: normalizedName,
            memberIds: uniqueMembers
        )

        let preview = try await repository.fetchGroupPreview(groupId: groupId, userId: userId)
        guard isCurrentAccountRequest(
            userID: userId,
            generation: requestGeneration
        ) else { return preview }
        stateUpdater.upsertGroupConversation(preview, groupConversations: &groupConversations)
        return preview
    }

    func fetchGroupConversationSettings(groupId: UUID) async -> GroupConversationSettings {
        await privacyActions.fetchGroupConversationSettings(groupId: groupId)
    }

    func setGroupConversationMuted(groupId: UUID, isMuted: Bool) async throws {
        let userID = try await AuthService.shared.requireAuthUserId()
        guard let requestGeneration = requestGeneration(for: userID) else {
            throw CancellationError()
        }
        try await privacyActions.persistGroupConversationMute(groupId: groupId, isMuted: isMuted)
        guard isCurrentAccountRequest(
            userID: userID,
            generation: requestGeneration
        ) else { return }
        stateUpdater.setGroupConversationMuted(
            groupId: groupId,
            isMuted: isMuted,
            groupConversations: &groupConversations
        )
    }

    func fetchChatGroupMembers(groupId: UUID) async throws -> [ChatGroupMemberSummary] {
        do {
            return try await repository.fetchChatGroupMembers(groupId: groupId)
        } catch {
            throw normalizedGroupDetailsError(from: error)
        }
    }

    func isCurrentUserGroupOwner(groupId: UUID) async -> Bool {
        let userId: UUID
        do {
            userId = try await AuthService.shared.requireAuthUserId()
        } catch {
            return false
        }

        do {
            return try await repository.fetchChatGroupOwnerId(groupId: groupId) == userId
        } catch {
            return false
        }
    }

    /// Returns `true` when owner disbands group, `false` when member leaves group.
    @discardableResult
    func leaveChatGroup(groupId: UUID) async throws -> Bool {
        let userID = try await AuthService.shared.requireAuthUserId()
        guard let requestGeneration = requestGeneration(for: userID) else {
            throw CancellationError()
        }

        do {
            let didDisband = try await repository.leaveChatGroup(groupId: groupId)
            if isCurrentAccountRequest(
                userID: userID,
                generation: requestGeneration
            ) {
                groupConversations.removeAll { $0.id == groupId }
            }
            return didDisband
        } catch {
            throw normalizedGroupDetailsError(from: error)
        }
    }

    func removeGroupMember(groupId: UUID, memberUserId: UUID) async throws {
        let currentUserId = try await AuthService.shared.requireAuthUserId()
        guard memberUserId != currentUserId else {
            throw NSError(
                domain: "",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "群主不能通过此操作移除自己。"]
            )
        }

        if try await repository.fetchChatGroupMemberRole(
            groupId: groupId,
            userId: memberUserId
        ) == "owner" {
            throw NSError(
                domain: "",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "无法移除群主。"]
            )
        }

        try await repository.deleteChatGroupMember(
            groupId: groupId,
            userId: memberUserId
        )
    }

    func fetchDirectConversationSettings(conversationId: UUID) async -> DirectConversationSettings {
        await privacyActions.fetchDirectConversationSettings(conversationId: conversationId)
    }

    func setConversationMuted(conversationId: UUID, isMuted: Bool) async throws {
        let userID = try await AuthService.shared.requireAuthUserId()
        guard let requestGeneration = requestGeneration(for: userID) else {
            throw CancellationError()
        }
        try await privacyActions.persistConversationMute(
            conversationId: conversationId,
            isMuted: isMuted
        )
        guard isCurrentAccountRequest(
            userID: userID,
            generation: requestGeneration
        ) else { return }
        stateUpdater.setConversationMuted(
            conversationId: conversationId,
            isMuted: isMuted,
            conversations: &conversations,
            messageRequests: &messageRequests
        )
    }

    @discardableResult
    func clearConversationHistory(conversationId: UUID) async throws -> Date {
        let userID = try await AuthService.shared.requireAuthUserId()
        guard let requestGeneration = requestGeneration(for: userID) else {
            throw CancellationError()
        }
        let clearedAt = try await privacyActions.clearConversationHistory(conversationId: conversationId)
        guard isCurrentAccountRequest(
            userID: userID,
            generation: requestGeneration
        ) else { return clearedAt }
        await markConversationRead(conversationId)
        stateUpdater.clearConversationPreview(
            conversationId: conversationId,
            conversations: &conversations,
            messageRequests: &messageRequests
        )
        return clearedAt
    }

    func markConversationUnread(conversationId: UUID) async throws {
        let userID = try await AuthService.shared.requireAuthUserId()
        guard let requestGeneration = requestGeneration(for: userID) else {
            throw CancellationError()
        }
        try await privacyActions.setConversationManualUnread(
            conversationId: conversationId,
            manualUnread: true
        )
        guard isCurrentAccountRequest(
            userID: userID,
            generation: requestGeneration
        ) else { return }
        stateUpdater.markConversationUnread(
            conversationId: conversationId,
            conversations: &conversations,
            messageRequests: &messageRequests
        )
    }

    func hideConversation(conversationId: UUID) async throws {
        let userID = try await AuthService.shared.requireAuthUserId()
        guard let requestGeneration = requestGeneration(for: userID) else {
            throw CancellationError()
        }
        try await privacyActions.hideConversation(conversationId: conversationId)
        guard isCurrentAccountRequest(
            userID: userID,
            generation: requestGeneration
        ) else { return }
        stateUpdater.removeConversation(
            conversationId: conversationId,
            conversations: &conversations,
            messageRequests: &messageRequests
        )
    }

    func deleteConversation(conversationId: UUID) async throws {
        let userID = try await AuthService.shared.requireAuthUserId()
        guard let requestGeneration = requestGeneration(for: userID) else {
            throw CancellationError()
        }
        try await privacyActions.deleteConversation(conversationId: conversationId)
        guard isCurrentAccountRequest(
            userID: userID,
            generation: requestGeneration
        ) else { return }
        await markConversationRead(conversationId)
        stateUpdater.removeConversation(
            conversationId: conversationId,
            conversations: &conversations,
            messageRequests: &messageRequests
        )
    }

    func isUserBlocked(with otherUserId: UUID) async -> Bool {
        await privacyActions.isUserBlocked(with: otherUserId)
    }

    func fetchBlockRelation(with otherUserId: UUID) async -> UserBlockRelation {
        await privacyActions.fetchBlockRelation(with: otherUserId)
    }

    func setUserBlocked(_ otherUserId: UUID, blocked: Bool) async throws {
        try await privacyActions.setUserBlocked(otherUserId, blocked: blocked)
        await refreshConversations()
    }

    func fetchBlockedUsers() async throws -> [BlockedUserSummary] {
        try await privacyActions.fetchBlockedUsers()
    }

    func reportUser(
        reportedUserId: UUID,
        conversationId: UUID?,
        reason: String,
        details: String?
    ) async throws {
        try await privacyActions.reportUser(
            reportedUserId: reportedUserId,
            conversationId: conversationId,
            reason: reason,
            details: details
        )
    }

    private func normalizedGroupDetailsError(from error: Error) -> Error {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("row-level security")
            || lower.contains("permission denied")
            || lower.contains("policy") {
            return NSError(
                domain: "",
                code: 403,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "当前账号没有权限执行群聊详情操作。"
                ]
            )
        }

        return error
    }

    private func sanitizedOptionalText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sendMessage(
        conversationId: UUID,
        content: String,
        messageType: String,
        metadata: MessageMetadata?
    ) async throws -> Message {
        let senderId = try await AuthService.shared.requireAuthUserId()
        guard let requestGeneration = requestGeneration(for: senderId) else {
            throw CancellationError()
        }

        let inserted: Message
        do {
            inserted = try await repository.insertMessage(
                conversationId: conversationId,
                senderId: senderId,
                content: content,
                messageType: messageType,
                metadata: metadata
            )
        } catch {
            throw normalizedSendError(from: error)
        }

        if isCurrentAccountRequest(
            userID: senderId,
            generation: requestGeneration
        ) {
            await updateConversationAfterSend(
                conversationId: conversationId,
                senderId: senderId,
                requestGeneration: requestGeneration,
                lastMessagePreview: content,
                messageCreatedAt: inserted.createdAt
            )
        }
        return inserted
    }

    private func sendGroupMessage(
        groupId: UUID,
        content: String,
        messageType: String,
        metadata: MessageMetadata?
    ) async throws -> GroupMessage {
        let senderId = try await AuthService.shared.requireAuthUserId()
        guard let requestGeneration = requestGeneration(for: senderId) else {
            throw CancellationError()
        }

        let insertedMessageID: UUID
        do {
            insertedMessageID = try await repository.insertGroupMessage(
                groupId: groupId,
                senderId: senderId,
                content: content,
                messageType: messageType,
                metadata: metadata
            )
        } catch {
            throw normalizedGroupSendError(from: error)
        }

        let message = try await repository.fetchGroupMessage(messageId: insertedMessageID)
        if isCurrentAccountRequest(
            userID: senderId,
            generation: requestGeneration
        ) {
            updateGroupConversationAfterSend(
                groupId: groupId,
                userID: senderId,
                requestGeneration: requestGeneration,
                messageCreatedAt: message.createdAt,
                preview: content
            )
        }
        return message
    }

    private func assertCanSendPostLinkedCard(
        conversationId: UUID,
        postKind: PostKind,
        postId: UUID
    ) async throws {
        if try await repository.hasSentPostLinkedCard(
            conversationId: conversationId,
            postKind: postKind,
            postId: postId
        ) {
            throw duplicatePostLinkedCardError(for: postKind)
        }
    }

    private func duplicatePostLinkedCardError(for postKind: PostKind) -> NSError {
        let localizedDescription: String

        localizedDescription = L10n.tr(
            "You have already sent a contact card for this post. Each post can only be contacted once.",
            "你已经针对这个帖子发过联系卡了，每个帖子只能联系一次。"
        )

        return NSError(
            domain: "",
            code: 409,
            userInfo: [NSLocalizedDescriptionKey: localizedDescription]
        )
    }

    private func normalizedSendError(from error: Error) -> Error {
        let text = error.localizedDescription.lowercased()
        if text.contains("blocked")
            || text.contains("封锁")
            || text.contains("拉黑") {
            return NSError(
                domain: "",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "封锁关系下无法发送私信。"]
            )
        }
        if text.contains("row-level security")
            || text.contains("permission")
            || text.contains("policy") {
            return NSError(
                domain: "",
                code: 403,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "陌生人聊天需等待对方回复后才能继续发送；互相关注后可自由聊天。"
                ]
            )
        }
        return error
    }

    private func normalizedGroupSendError(from error: Error) -> Error {
        let text = error.localizedDescription.lowercased()
        if text.contains("row-level security")
            || text.contains("permission")
            || text.contains("policy") {
            return NSError(
                domain: "",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "只有群成员可以在群聊中发送消息。"]
            )
        }
        return error
    }

    func markConversationRead(_ conversationId: UUID) async {
        stateUpdater.markConversationRead(
            conversationId: conversationId,
            conversations: &conversations,
            messageRequests: &messageRequests
        )
        await privacyActions.markConversationRead(conversationId: conversationId)
    }

    func markGroupConversationRead(_ groupId: UUID) async {
        do {
            try await privacyActions.saveGroupConversationReadMarker(groupId: groupId, lastReadAt: Date())
            stateUpdater.setGroupConversationUnreadCount(
                groupId: groupId,
                unreadCount: 0,
                groupConversations: &groupConversations
            )
        } catch {
        }
    }

    private func refreshConversation(
        conversationId: UUID,
        userId: UUID,
        requestGeneration: UInt64
    ) async throws {
        let preview = try await repository.fetchConversationPreview(conversationId: conversationId, userId: userId)
        guard isCurrentAccountRequest(
            userID: userId,
            generation: requestGeneration
        ) else { return }
        stateUpdater.upsertConversation(
            preview,
            conversations: &conversations,
            messageRequests: &messageRequests
        )
    }

    private func updateConversationAfterSend(
        conversationId: UUID,
        senderId: UUID,
        requestGeneration: UInt64,
        lastMessagePreview: String,
        messageCreatedAt: Date
    ) async {
        guard isCurrentAccountRequest(
            userID: senderId,
            generation: requestGeneration
        ) else { return }
        if let current = conversations.first(where: { $0.id == conversationId }) {
            let updated = ChatConversationPreview(
                id: current.id,
                otherUserId: current.otherUserId,
                otherUserName: current.otherUserName,
                otherUserAvatar: current.otherUserAvatar,
                relatedPostId: current.relatedPostId,
                lastMessageAt: messageCreatedAt,
                lastMessagePreview: lastMessagePreview,
                unreadCount: current.unreadCount,
                canChatFreely: current.canChatFreely,
                isMutualFollow: current.isMutualFollow,
                isMuted: current.isMuted
            )
            stateUpdater.upsertConversation(
                updated,
                conversations: &conversations,
                messageRequests: &messageRequests
            )
            return
        }

        try? await refreshConversation(
            conversationId: conversationId,
            userId: senderId,
            requestGeneration: requestGeneration
        )
    }

    private func updateGroupConversationAfterSend(
        groupId: UUID,
        userID: UUID,
        requestGeneration: UInt64,
        messageCreatedAt: Date,
        preview: String
    ) {
        guard isCurrentAccountRequest(
            userID: userID,
            generation: requestGeneration
        ) else { return }
        let previewText = preview == "📷 Photo"
            ? preview
            : String(preview.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))

        if let current = groupConversations.first(where: { $0.id == groupId }) {
            stateUpdater.upsertGroupConversation(
                ChatGroupPreview(
                    id: current.id,
                    name: current.name,
                    avatarURL: current.avatarURL,
                    lastMessageAt: messageCreatedAt,
                    lastMessagePreview: previewText,
                    memberCount: current.memberCount,
                    unreadCount: 0,
                    isMuted: current.isMuted
                ),
                groupConversations: &groupConversations
            )
            return
        }

        Task {
            if let preview = try? await repository.fetchGroupPreview(
                groupId: groupId,
                userId: userID
            ) {
                await MainActor.run {
                    guard self.isCurrentAccountRequest(
                        userID: userID,
                        generation: requestGeneration
                    ) else { return }
                    self.stateUpdater.upsertGroupConversation(
                        preview,
                        groupConversations: &self.groupConversations
                    )
                }
            }
        }
    }

}

struct ChatGetOrCreateConversationParams: Encodable {
    let pUserId: UUID
    let pOtherUserId: UUID
    let pRelatedPostId: UUID?

    enum CodingKeys: String, CodingKey {
        case pUserId = "p_user_id"
        case pOtherUserId = "p_other_user_id"
        case pRelatedPostId = "p_related_post_id"
    }
}

struct ChatGetUserConversationsParams: Encodable {
    let pUserId: UUID

    enum CodingKeys: String, CodingKey {
        case pUserId = "p_user_id"
    }
}

struct ChatGetUserMessageRequestsParams: Encodable {
    let pUserId: UUID

    enum CodingKeys: String, CodingKey {
        case pUserId = "p_user_id"
    }
}

struct ChatGetUserChatGroupsParams: Encodable {
    let pUserId: UUID

    enum CodingKeys: String, CodingKey {
        case pUserId = "p_user_id"
    }
}

struct ChatGetChatGroupMembersParams: Encodable {
    let pGroupId: UUID

    enum CodingKeys: String, CodingKey {
        case pGroupId = "p_group_id"
    }
}

struct ChatLeaveChatGroupParams: Encodable {
    let pGroupId: UUID

    enum CodingKeys: String, CodingKey {
        case pGroupId = "p_group_id"
    }
}

struct ChatGetMutualFollowProfilesParams: Encodable {
    let pUserId: UUID
    let pLimit: Int

    enum CodingKeys: String, CodingKey {
        case pUserId = "p_user_id"
        case pLimit = "p_limit"
    }
}

struct ChatCreateChatGroupParams: Encodable {
    let pName: String
    let pMemberIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case pName = "p_name"
        case pMemberIds = "p_member_ids"
    }
}

struct ChatMarkMessagesAsReadParams: Encodable {
    let pConversationId: UUID
    let pUserId: UUID

    enum CodingKeys: String, CodingKey {
        case pConversationId = "p_conversation_id"
        case pUserId = "p_user_id"
    }
}

struct ConversationInsertResult: Decodable {
    let id: UUID
}

struct ConversationRow: Decodable {
    let id: UUID
    let user1Id: UUID
    let user2Id: UUID
    let relatedPostId: UUID?
    let lastMessageAt: Date
    let lastMessagePreview: String?
    let user1UnreadCount: Int
    let user2UnreadCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case user1Id = "user1_id"
        case user2Id = "user2_id"
        case relatedPostId = "related_post_id"
        case lastMessageAt = "last_message_at"
        case lastMessagePreview = "last_message_preview"
        case user1UnreadCount = "user1_unread_count"
        case user2UnreadCount = "user2_unread_count"
    }
}

struct ProfileLite: Decodable {
    let id: UUID
    let fullName: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case avatarURL = "avatar_url"
    }
}

struct ChatGroupFallbackRow: Decodable {
    let id: UUID
    let name: String
    let avatarURL: String?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case avatarURL = "avatar_url"
        case updatedAt = "updated_at"
    }
}

struct ChatGroupMemberCountRow: Decodable {
    let userId: UUID

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
    }
}

struct ChatGroupOwnerRow: Decodable {
    let ownerId: UUID

    enum CodingKeys: String, CodingKey {
        case ownerId = "owner_id"
    }
}

struct ChatGroupMemberRoleRow: Decodable {
    let role: String
}

struct ChatGroupMemberRpcRow: Decodable {
    let userId: UUID
    let fullName: String?
    let avatarURL: String?
    let role: String
    let joinedAt: Date?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case fullName = "full_name"
        case avatarURL = "avatar_url"
        case role
        case joinedAt = "joined_at"
    }
}

struct GroupMessagePreviewRow: Decodable {
    let createdAt: Date
    let content: String
    let messageType: String

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case content
        case messageType = "message_type"
    }
}

struct GroupConversationSettingsRow: Decodable {
    let isMuted: Bool

    enum CodingKeys: String, CodingKey {
        case isMuted = "is_muted"
    }
}

struct GroupConversationSettingsInsert: Encodable {
    let userId: UUID
    let groupId: UUID
    let isMuted: Bool

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case groupId = "group_id"
        case isMuted = "is_muted"
    }
}

struct GroupConversationSettingsUpdate: Encodable {
    let isMuted: Bool

    enum CodingKeys: String, CodingKey {
        case isMuted = "is_muted"
    }
}

struct GroupConversationReadMarkerInsert: Encodable {
    let userId: UUID
    let groupId: UUID
    let lastReadAt: Date

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case groupId = "group_id"
        case lastReadAt = "last_read_at"
    }
}

struct GroupConversationReadMarkerUpdate: Encodable {
    let lastReadAt: Date

    enum CodingKeys: String, CodingKey {
        case lastReadAt = "last_read_at"
    }
}

struct ConversationListSettingsRow: Decodable {
    let conversationId: UUID
    let isMuted: Bool
    let manualUnread: Bool
    let hideUntilAt: Date?
    let clearBeforeAt: Date?

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case isMuted = "is_muted"
        case manualUnread = "manual_unread"
        case hideUntilAt = "hide_until_at"
        case clearBeforeAt = "clear_before_at"
    }
}

struct GroupIDRow: Decodable {
    let groupId: UUID

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
    }
}

struct ConversationSettingsRow: Decodable {
    let isMuted: Bool
    let clearBeforeAt: Date?
    let manualUnread: Bool
    let hideUntilAt: Date?

    enum CodingKeys: String, CodingKey {
        case isMuted = "is_muted"
        case clearBeforeAt = "clear_before_at"
        case manualUnread = "manual_unread"
        case hideUntilAt = "hide_until_at"
    }
}

struct ConversationSettingsInsert: Encodable {
    let userId: UUID
    let conversationId: UUID
    let isMuted: Bool
    let clearBeforeAt: Date?
    let manualUnread: Bool
    let hideUntilAt: Date?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case conversationId = "conversation_id"
        case isMuted = "is_muted"
        case clearBeforeAt = "clear_before_at"
        case manualUnread = "manual_unread"
        case hideUntilAt = "hide_until_at"
    }
}

struct ConversationSettingsUpdate: Encodable {
    let isMuted: Bool
    let clearBeforeAt: Date?
    let manualUnread: Bool
    let hideUntilAt: Date?

    enum CodingKeys: String, CodingKey {
        case isMuted = "is_muted"
        case clearBeforeAt = "clear_before_at"
        case manualUnread = "manual_unread"
        case hideUntilAt = "hide_until_at"
    }
}

struct ConversationManualUnreadInsert: Encodable {
    let userId: UUID
    let conversationId: UUID
    let manualUnread: Bool

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case conversationId = "conversation_id"
        case manualUnread = "manual_unread"
    }
}

struct ConversationManualUnreadUpdate: Encodable {
    let manualUnread: Bool

    enum CodingKeys: String, CodingKey {
        case manualUnread = "manual_unread"
    }
}

struct HiddenConversationUntilRow: Decodable {
    let conversationId: UUID
    let hideUntilAt: Date?

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case hideUntilAt = "hide_until_at"
    }
}

struct ChatIsUserBlockedParams: Encodable {
    let pUserA: UUID
    let pUserB: UUID

    enum CodingKeys: String, CodingKey {
        case pUserA = "p_user_a"
        case pUserB = "p_user_b"
    }
}

struct UserBlockInsert: Encodable {
    let blockerId: UUID
    let blockedId: UUID

    enum CodingKeys: String, CodingKey {
        case blockerId = "blocker_id"
        case blockedId = "blocked_id"
    }
}

struct UserBlockRow: Decodable {
    let blockerId: UUID
    let blockedId: UUID
    let blockedAt: Date

    enum CodingKeys: String, CodingKey {
        case blockerId = "blocker_id"
        case blockedId = "blocked_id"
        case blockedAt = "blocked_at"
    }
}

struct BlockedUserRpcRow: Decodable {
    let blockedUserId: UUID
    let blockedUserName: String
    let blockedUserAvatar: String?
    let blockedAt: Date

    enum CodingKeys: String, CodingKey {
        case blockedUserId = "blocked_user_id"
        case blockedUserName = "blocked_user_name"
        case blockedUserAvatar = "blocked_user_avatar"
        case blockedAt = "blocked_at"
    }
}

struct ChatGetBlockedUsersParams: Encodable {
    let pUserId: UUID

    enum CodingKeys: String, CodingKey {
        case pUserId = "p_user_id"
    }
}

struct UserReportInsert: Encodable {
    let reporterId: UUID
    let reportedUserId: UUID
    let conversationId: UUID?
    let reason: String
    let details: String?

    enum CodingKeys: String, CodingKey {
        case reporterId = "reporter_id"
        case reportedUserId = "reported_user_id"
        case conversationId = "conversation_id"
        case reason
        case details
    }
}
