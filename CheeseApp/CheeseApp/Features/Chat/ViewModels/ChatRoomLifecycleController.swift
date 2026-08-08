//
//  ChatRoomLifecycleController.swift
//  CheeseApp
//
//  Shared room state, bootstrap, and timeline merge rules.
//

import Combine
import Foundation

struct ChatRoomLifecycleController: Equatable {
    private(set) var hasBootstrappedRoom = false
    private(set) var isBootstrappingRoom = false
    private(set) var activeSessionID: UUID?

    mutating func beginBootstrapIfNeeded() -> Bool {
        guard !hasBootstrappedRoom, !isBootstrappingRoom else { return false }
        isBootstrappingRoom = true
        activeSessionID = UUID()
        return true
    }

    mutating func completeBootstrap() {
        isBootstrappingRoom = false
        hasBootstrappedRoom = true
    }

    func acceptsEvents(for sessionID: UUID) -> Bool {
        activeSessionID == sessionID
    }

    mutating func invalidateForRoomExit() {
        activeSessionID = nil
        isBootstrappingRoom = false
        hasBootstrappedRoom = false
    }

    func shouldStopRealtimeOnDisappear(hasNestedDestinationPresented: Bool) -> Bool {
        !hasNestedDestinationPresented
    }
}

struct ChatStrangerSafetyPolicy {
    let isStranger: Bool
    let hasSentMessage: Bool
    let hasReceivedMessage: Bool
    let hasAcknowledgedNotice: Bool

    static func isExplicitStranger(
        isMutualFollow: Bool?,
        canChatFreely: Bool?
    ) -> Bool {
        isMutualFollow == false || canChatFreely == false
    }

    var shouldShowEntryNotice: Bool {
        isStranger && hasReceivedMessage && !hasSentMessage && !hasAcknowledgedNotice
    }

    var requiresSendConfirmation: Bool {
        isStranger && !hasSentMessage && !hasAcknowledgedNotice
    }
}

protocol ChatRoomTimelineMessage: Identifiable where ID == UUID {
    var createdAt: Date { get }
}

extension Message: ChatRoomTimelineMessage {}
extension GroupMessage: ChatRoomTimelineMessage {}

enum ChatRoomMessageTimeline {
    static func merge<MessageType: ChatRoomTimelineMessage>(
        _ incoming: [MessageType],
        into existing: [MessageType]
    ) -> [MessageType] {
        var seenIDs = Set<UUID>()
        var merged: [MessageType] = []

        for message in existing + incoming where seenIDs.insert(message.id).inserted {
            merged.append(message)
        }

        merged.sort { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return merged
    }
}

struct ChatRoomMessageOperations<MessageType: ChatRoomTimelineMessage> {
    let loadInitialPage: () async throws -> ChatMessagePage<MessageType>
    let loadOlderPage: (ChatMessagePageCursor) async throws -> ChatMessagePage<MessageType>
    let observe: (
        @escaping (MessageType) async -> Void,
        @escaping (UUID) async -> Void,
        @escaping () -> Void
    ) -> () -> Void
    let sendText: (String, QuotedMessageMetadata?) async throws -> MessageType
    let sendImage: (ChatMediaReference) async throws -> MessageType
    let markRead: () async -> Void
    let isIncoming: (MessageType) -> Bool
    let marksReadWhenLoadFails: Bool
}

@MainActor
final class ChatRoomMessageState<MessageType: ChatRoomTimelineMessage>: ObservableObject {
    @Published private(set) var messages: [MessageType] = []
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var scrollToMessageID: UUID?
    @Published private(set) var hasResolvedInitialLoad = false
    @Published private(set) var isLoadingOlderHistory = false
    @Published private(set) var hasMoreHistory = false
    @Published private(set) var historyErrorMessage: String?

    private let operations: ChatRoomMessageOperations<MessageType>
    private var lifecycle = ChatRoomLifecycleController()
    private var stopRealtimeObservation: (() -> Void)?
    private var minimumVisibleDate: Date?
    private var isTransportingMessage = false
    private var historyCursor: ChatMessagePageCursor?
    private var historyRequestID: UUID?

    init(operations: ChatRoomMessageOperations<MessageType>) {
        self.operations = operations
    }

    func bootstrap(prepare: () async -> Void = {}) async {
        guard lifecycle.beginBootstrapIfNeeded(),
              let sessionID = lifecycle.activeSessionID
        else { return }

        await prepare()
        guard lifecycle.acceptsEvents(for: sessionID) else { return }

        isLoading = true
        errorMessage = nil
        hasResolvedInitialLoad = false

        do {
            let page = try await operations.loadInitialPage()
            guard lifecycle.acceptsEvents(for: sessionID) else { return }

            messages = ChatRoomMessageTimeline
                .merge(page.messages, into: [])
                .filter(isVisible)
            historyCursor = page.nextCursor
            hasMoreHistory = page.nextCursor != nil
            historyErrorMessage = nil
            scrollToMessageID = messages.last?.id
            hasResolvedInitialLoad = true
        } catch {
            guard lifecycle.acceptsEvents(for: sessionID) else { return }
            errorMessage = error.localizedDescription
        }

        guard lifecycle.acceptsEvents(for: sessionID) else { return }
        isLoading = false

        if hasResolvedInitialLoad || operations.marksReadWhenLoadFails {
            await operations.markRead()
        }

        guard lifecycle.acceptsEvents(for: sessionID) else { return }
        startRealtime(sessionID: sessionID)
        lifecycle.completeBootstrap()
    }

    func loadOlderHistory() async {
        guard !isLoadingOlderHistory,
              let cursor = historyCursor,
              let sessionID = lifecycle.activeSessionID,
              lifecycle.acceptsEvents(for: sessionID)
        else { return }

        let requestID = UUID()
        historyRequestID = requestID
        isLoadingOlderHistory = true
        historyErrorMessage = nil

        do {
            let page = try await operations.loadOlderPage(cursor)
            guard lifecycle.acceptsEvents(for: sessionID),
                  historyRequestID == requestID
            else { return }

            messages = ChatRoomMessageTimeline
                .merge(page.messages, into: messages)
                .filter(isVisible)
            historyCursor = page.nextCursor
            hasMoreHistory = page.nextCursor != nil
        } catch {
            guard lifecycle.acceptsEvents(for: sessionID),
                  historyRequestID == requestID
            else { return }
            historyErrorMessage = error.localizedDescription
        }

        guard historyRequestID == requestID else { return }
        historyRequestID = nil
        isLoadingOlderHistory = false
    }

    @discardableResult
    func sendText(
        _ content: String,
        quotedMessage: QuotedMessageMetadata? = nil
    ) async -> Bool {
        guard !isTransportingMessage else { return false }
        isTransportingMessage = true
        defer { isTransportingMessage = false }
        return await send { try await operations.sendText(content, quotedMessage) }
    }

    @discardableResult
    func sendImage(_ media: ChatMediaReference) async -> Bool {
        guard !isTransportingMessage else { return false }
        isTransportingMessage = true
        defer { isTransportingMessage = false }
        return await send { try await operations.sendImage(media) }
    }

    func clearError() {
        errorMessage = nil
    }

    func setError(_ message: String) {
        errorMessage = message
    }

    private func send(
        using operation: () async throws -> MessageType
    ) async -> Bool {
        do {
            let sent = try await operation()
            mergeOutgoing(sent)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateMinimumVisibleDate(_ date: Date?) {
        minimumVisibleDate = date
        messages = messages.filter(isVisible)
        scrollToMessageID = messages.last?.id
    }

    func requestScrollToLatest() {
        scrollToMessageID = messages.last?.id
    }

    func removeMessage(id: UUID) {
        messages.removeAll { $0.id == id }
        if scrollToMessageID == id {
            scrollToMessageID = messages.last?.id
        }
    }

    func stopOnDisappear(hasNestedDestinationPresented: Bool) {
        guard lifecycle.shouldStopRealtimeOnDisappear(
            hasNestedDestinationPresented: hasNestedDestinationPresented
        ) else { return }
        stop()
    }

    func stop() {
        stopRealtimeObservation?()
        stopRealtimeObservation = nil
        lifecycle.invalidateForRoomExit()
        historyRequestID = nil
        isLoading = false
        isLoadingOlderHistory = false
        isTransportingMessage = false
    }

    private func startRealtime(sessionID: UUID) {
        stopRealtimeObservation?()
        stopRealtimeObservation = operations.observe(
            { [weak self] message in
                await self?.receive(message, sessionID: sessionID)
            },
            { [weak self] messageID in
                guard let self,
                      self.lifecycle.acceptsEvents(for: sessionID)
                else { return }
                self.removeMessage(id: messageID)
            },
            { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.lifecycle.acceptsEvents(for: sessionID)
                    else { return }
                    self.errorMessage = "Realtime disconnected. Pull to refresh."
                }
            }
        )
    }

    private func receive(_ message: MessageType, sessionID: UUID) async {
        guard lifecycle.acceptsEvents(for: sessionID) else { return }

        mergeOutgoing(message)
        if operations.isIncoming(message) {
            await operations.markRead()
        }
    }

    private func mergeOutgoing(_ message: MessageType) {
        guard isVisible(message),
              !messages.contains(where: { $0.id == message.id })
        else { return }
        messages = ChatRoomMessageTimeline.merge([message], into: messages)
        scrollToMessageID = message.id
        hasResolvedInitialLoad = true
    }

    private func isVisible(_ message: MessageType) -> Bool {
        guard let minimumVisibleDate else { return true }
        return message.createdAt >= minimumVisibleDate
    }
}

extension ChatRoomMessageState where MessageType == Message {
    static func direct(conversationID: UUID) -> ChatRoomMessageState<Message> {
        let chatService = ChatService.shared
        let repository = ChatServiceRepository()
        return ChatRoomMessageState<Message>(
            operations: ChatRoomMessageOperations(
                loadInitialPage: {
                    try await repository.fetchMessagesPage(conversationId: conversationID)
                },
                loadOlderPage: {
                    try await repository.fetchMessagesPage(
                        conversationId: conversationID,
                        before: $0
                    )
                },
                observe: { onMessage, onDelete, onDisconnect in
                    repository.observeMessages(
                        conversationId: conversationID,
                        onMessage: onMessage,
                        onMessageDeleted: onDelete,
                        onDisconnect: onDisconnect
                    )
                },
                sendText: { content, quotedMessage in
                    try await chatService.sendMessage(
                        conversationId: conversationID,
                        content: content,
                        quotedMessage: quotedMessage
                    )
                },
                sendImage: { try await chatService.sendImageMessage(conversationId: conversationID, media: $0) },
                markRead: { await chatService.markConversationRead(conversationID) },
                isIncoming: { $0.senderId != AuthService.shared.currentUser?.id },
                marksReadWhenLoadFails: true
            )
        )
    }
}

extension ChatRoomMessageState where MessageType == GroupMessage {
    static func group(groupID: UUID) -> ChatRoomMessageState<GroupMessage> {
        let chatService = ChatService.shared
        let repository = ChatServiceRepository()
        return ChatRoomMessageState<GroupMessage>(
            operations: ChatRoomMessageOperations(
                loadInitialPage: {
                    try await repository.fetchGroupMessagesPage(groupId: groupID)
                },
                loadOlderPage: {
                    try await repository.fetchGroupMessagesPage(
                        groupId: groupID,
                        before: $0
                    )
                },
                observe: { onMessage, onDelete, onDisconnect in
                    repository.observeGroupMessages(
                        groupId: groupID,
                        onMessage: onMessage,
                        onMessageDeleted: onDelete,
                        onDisconnect: onDisconnect
                    )
                },
                sendText: { content, quotedMessage in
                    try await chatService.sendGroupMessage(
                        groupId: groupID,
                        content: content,
                        quotedMessage: quotedMessage
                    )
                },
                sendImage: { try await chatService.sendGroupImageMessage(groupId: groupID, media: $0) },
                markRead: { await chatService.markGroupConversationRead(groupID) },
                isIncoming: { $0.senderId != AuthService.shared.currentUser?.id },
                marksReadWhenLoadFails: false
            )
        )
    }
}
