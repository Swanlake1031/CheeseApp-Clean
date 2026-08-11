//
//  ChatRoomViewModel.swift
//  CheeseApp
//
//  Direct-message orchestration and presentation state.
//

import Combine
import Foundation
import PhotosUI
import SwiftUI
import UIKit

enum ChatRoomNavigationDestination: Identifiable, Hashable {
    case userProfile(UUID)
    case sharedForumPost(UUID)
    case linkedPost(PostDeepLinkRoute)
    case settings

    var id: String {
        switch self {
        case .userProfile(let id): return "profile:\(id)"
        case .sharedForumPost(let id): return "forum:\(id)"
        case .linkedPost(let route): return "post:\(route.id)"
        case .settings: return "settings"
        }
    }
}

enum ChatRoomSheetDestination: Identifiable {
    case reportUser
    case reportMessage(ChatMessageReportTarget)
    case secondhandBuyerSelection

    var id: String {
        switch self {
        case .reportUser: return "report-user"
        case .reportMessage(let target): return "report-message:\(target.id)"
        case .secondhandBuyerSelection: return "secondhand-buyer-selection"
        }
    }
}

enum ChatRoomAlertDestination: Identifiable, Equatable {
    case clearHistoryConfirmation
    case blockConfirmation
    case unblockConfirmation
    case deleteMessage(UUID, forEveryone: Bool)
    case cancelSecondhandPurchaseIntent
    case completeSecondhandSale(UUID)
    case stopSellingSecondhandListing

    var id: String {
        switch self {
        case .clearHistoryConfirmation: return "clear-history-confirmation"
        case .blockConfirmation: return "block-confirmation"
        case .unblockConfirmation: return "unblock-confirmation"
        case .deleteMessage(let messageID, let forEveryone):
            return "delete-message:\(messageID.uuidString):\(forEveryone)"
        case .cancelSecondhandPurchaseIntent:
            return "cancel-secondhand-purchase-intent"
        case .completeSecondhandSale(let buyerID):
            return "complete-secondhand-sale:\(buyerID.uuidString)"
        case .stopSellingSecondhandListing:
            return "stop-selling-secondhand-listing"
        }
    }
}

enum ChatRoomSettingsAction {
    case setMuted(Bool)
    case saveRemark(String?)
    case report
    case clearHistory
    case toggleBlock
}

struct ChatRoomPendingImage {
    let image: UIImage
    var uploadedAsset: ChatMediaAsset?
}

struct ChatRoomMediaProgress {
    let completed: Int
    let total: Int

    var fraction: Double {
        total == 0 ? 0 : Double(completed) / Double(total)
    }
}

private enum ChatRoomPendingSend {
    case text(String, QuotedMessageMetadata?)
    case images
}

@MainActor
final class ChatRoomViewModel: ObservableObject {
    let conversation: ChatConversationPreview
    let roomState: ChatRoomMessageState<Message>

    @Published var draftText = ""
    @Published private(set) var pendingQuote: QuotedMessageMetadata?
    @Published private var stagedMedia: [ChatRoomPendingImage]
    @Published private(set) var isPreparingMedia = false
    @Published private(set) var isSubmittingComposer = false
    @Published private(set) var mediaProgress: ChatRoomMediaProgress?
    @Published private(set) var isCancellingMediaSend = false
    @Published private(set) var isMuted = false
    @Published private(set) var clearBeforeAt: Date?
    @Published private(set) var blockRelation: UserBlockRelation = .none
    @Published private(set) var isApplyingPrivacyAction = false
    @Published private(set) var conversationDisplayName: String
    @Published private(set) var conversationRemark: String?
    @Published private(set) var secondhandPurchaseIntent: SecondhandChatPurchaseIntent?
    @Published private(set) var secondhandActiveBuyers: [SecondhandActiveBuyer] = []
    @Published private(set) var isApplyingSecondhandTransactionAction = false
    @Published var navigationDestination: ChatRoomNavigationDestination?
    @Published var sheetDestination: ChatRoomSheetDestination?
    @Published var alertDestination: ChatRoomAlertDestination?

    var activeSecondhandPurchaseIntent: SecondhandChatPurchaseIntent? {
        guard secondhandPurchaseIntent?.status.isActive == true else { return nil }
        return secondhandPurchaseIntent
    }

    private let chatService: any ChatRoomServicing
    private let mediaService: any ChatRoomMediaServicing
    private let secondhandTransactionService: (any SecondhandChatTransactionServicing)?
    private var currentUserID: UUID?
    private var failedSend: ChatRoomPendingSend?
    private var messageStateObservation: AnyCancellable?
    private var mediaPreparationTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var secondhandTransactionRefreshTask: Task<Void, Never>?
    private var mediaPreparationID: UUID?
    private var mediaCancellationRequested = false
    private var discardMediaAfterCancellation = false

    init(
        conversation: ChatConversationPreview,
        roomState: ChatRoomMessageState<Message>? = nil,
        chatService: (any ChatRoomServicing)? = nil,
        secondhandTransactionService: (any SecondhandChatTransactionServicing)? = nil,
        mediaService: (any ChatRoomMediaServicing)? = nil,
        currentUserID: UUID? = nil,
        stagedImages: [UIImage] = []
    ) {
        let resolvedChatService = chatService ?? ChatService.shared

        self.conversation = conversation
        self.roomState = roomState ?? .direct(conversationID: conversation.id)
        self.chatService = resolvedChatService
        self.secondhandTransactionService = secondhandTransactionService
        self.mediaService = mediaService ?? LiveChatRoomMediaService()
        self.currentUserID = currentUserID
        self.stagedMedia = stagedImages.map { ChatRoomPendingImage(image: $0) }
        self.conversationDisplayName = resolvedChatService.displayName(for: conversation)
        self.conversationRemark = resolvedChatService.conversationRemark(for: conversation.id)
        self.secondhandPurchaseIntent = nil

        messageStateObservation = self.roomState.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        mediaPreparationTask?.cancel()
        sendTask?.cancel()
        presentationTask?.cancel()
        secondhandTransactionRefreshTask?.cancel()
    }

    var messages: [Message] { roomState.messages }
    var stagedImages: [UIImage] { stagedMedia.map(\.image) }
    var isLoading: Bool { roomState.isLoading }
    var isLoadingOlderHistory: Bool { roomState.isLoadingOlderHistory }
    var hasMoreHistory: Bool { roomState.hasMoreHistory }
    var historyErrorMessage: String? { roomState.historyErrorMessage }
    var scrollToMessageID: UUID? { roomState.scrollToMessageID }
    var displayedRoomError: String? { roomState.errorMessage }
    var canRetry: Bool { failedSend != nil && !isSubmittingComposer }
    var canCompose: Bool { !blockRelation.isEitherBlocked && !isApplyingPrivacyAction }
    var hasComposerContent: Bool {
        !stagedMedia.isEmpty
            || !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var imageSelectionLimit: Int { 9 }
    var blockedComposeHint: String {
        if blockRelation.isBlockedByMe && blockRelation.isBlockedByOther {
            return "双方处于封锁状态，当前会话仅可查看历史消息。"
        }
        return blockRelation.isBlockedByOther
            ? "你已被对方拉黑，当前会话仅可查看历史消息。"
            : "你已拉黑对方，当前会话仅可查看历史消息。"
    }
    var hasNestedDestinationPresented: Bool { navigationDestination != nil }
    var latestSecondhandTransactionSignalMessageID: UUID? {
        messages.last(where: { message in
            message.metadata?.secondhandTransactionEvent != nil
                || message.metadata?.postContactCard.map {
                    PostKind(remoteValue: $0.postKind) == .secondhand
                } == true
        })?.id
    }

    func bootstrap(currentUserID: UUID?) async {
        self.currentUserID = currentUserID
        await roomState.bootstrap { [weak self] in
            guard let self else { return }
            await self.loadPrivacyState()
            await self.refreshSecondhandPurchaseIntent()
            self.roomState.updateMinimumVisibleDate(self.clearBeforeAt)
        }
    }

    func stopOnDisappear() {
        guard !hasNestedDestinationPresented else { return }
        mediaPreparationTask?.cancel()
        if isSubmittingComposer, !stagedMedia.isEmpty {
            mediaCancellationRequested = true
        } else {
            cleanupUploadedAssets(in: stagedMedia)
        }
        roomState.stopOnDisappear(hasNestedDestinationPresented: false)
        secondhandTransactionRefreshTask?.cancel()
        secondhandTransactionRefreshTask = nil
    }

    func refreshSecondhandPurchaseIntentAfterTimelineSignal() {
        guard secondhandTransactionService != nil else { return }
        secondhandTransactionRefreshTask?.cancel()
        secondhandTransactionRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshSecondhandPurchaseIntent()
            self.secondhandTransactionRefreshTask = nil
        }
    }

    func requestCancelSecondhandPurchaseIntent() {
        guard secondhandPurchaseIntent?.status == .active,
              secondhandPurchaseIntent?.viewerRole == .buyer,
              !isApplyingSecondhandTransactionAction
        else { return }
        alertDestination = .cancelSecondhandPurchaseIntent
    }

    func requestCompleteSecondhandSale() {
        guard let intent = secondhandPurchaseIntent,
              intent.status == .active,
              intent.viewerRole == .seller,
              !isApplyingSecondhandTransactionAction,
              let secondhandTransactionService
        else { return }

        isApplyingSecondhandTransactionAction = true
        roomState.clearError()
        Task { [weak self] in
            guard let self else { return }
            defer { self.isApplyingSecondhandTransactionAction = false }
            do {
                let buyers = try await secondhandTransactionService
                    .fetchSecondhandActiveBuyers(listingId: intent.listingId)
                guard !buyers.isEmpty else {
                    self.roomState.setError("当前没有可确认成交的买家。")
                    return
                }
                self.secondhandActiveBuyers = buyers
                if buyers.count == 1, let buyerID = buyers.first?.buyerId {
                    self.alertDestination = .completeSecondhandSale(buyerID)
                } else {
                    self.sheetDestination = .secondhandBuyerSelection
                }
            } catch {
                self.roomState.setError(error.localizedDescription)
            }
        }
    }

    func selectSecondhandBuyerForCompletion(_ buyerID: UUID) {
        guard secondhandActiveBuyers.contains(where: { $0.buyerId == buyerID }) else { return }
        sheetDestination = nil
        presentationTask?.cancel()
        presentationTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.alertDestination = .completeSecondhandSale(buyerID)
        }
    }

    func requestStopSellingSecondhandListing() {
        guard secondhandPurchaseIntent?.status == .active,
              secondhandPurchaseIntent?.viewerRole == .seller,
              !isApplyingSecondhandTransactionAction
        else { return }
        alertDestination = .stopSellingSecondhandListing
    }

    func confirmCancelSecondhandPurchaseIntent() {
        guard let intent = secondhandPurchaseIntent,
              intent.status == .active,
              intent.viewerRole == .buyer,
              let secondhandTransactionService
        else { return }
        alertDestination = nil
        performSecondhandTransactionAction {
            try await secondhandTransactionService
                .cancelSecondhandPurchaseIntent(intentId: intent.id)
        }
    }

    func confirmCompleteSecondhandSale(buyerID: UUID) {
        guard let intent = secondhandPurchaseIntent,
              intent.status == .active,
              intent.viewerRole == .seller,
              secondhandActiveBuyers.contains(where: { $0.buyerId == buyerID }),
              let secondhandTransactionService
        else { return }
        alertDestination = nil
        performSecondhandTransactionAction {
            try await secondhandTransactionService.completeSecondhandSale(
                listingId: intent.listingId,
                buyerId: buyerID
            )
            PostFeatureEvents.postDidChange(
                kind: .secondhand,
                authorId: intent.sellerId,
                postId: intent.listingId
            )
        }
    }

    func confirmStopSellingSecondhandListing() {
        guard let intent = secondhandPurchaseIntent,
              intent.status == .active,
              intent.viewerRole == .seller,
              let secondhandTransactionService
        else { return }
        alertDestination = nil
        performSecondhandTransactionAction {
            try await secondhandTransactionService
                .stopSellingSecondhandListing(listingId: intent.listingId)
            PostFeatureEvents.postDidChange(
                kind: .secondhand,
                authorId: intent.sellerId,
                postId: intent.listingId
            )
        }
    }

    func requestScrollToLatest() {
        roomState.requestScrollToLatest()
    }

    func loadOlderHistory() async {
        await roomState.loadOlderHistory()
    }

    func stageMediaSelections(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, canCompose, !isSubmittingComposer else { return }
        mediaPreparationTask?.cancel()
        let preparationID = UUID()
        mediaPreparationID = preparationID
        isPreparingMedia = true
        roomState.clearError()

        mediaPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let images = try await mediaService.loadImages(from: items)
                try Task.checkCancellation()
                guard mediaPreparationID == preparationID else { return }
                cleanupUploadedAssets(in: stagedMedia)
                stagedMedia = images.prefix(imageSelectionLimit).map {
                    ChatRoomPendingImage(image: $0)
                }
                if stagedMedia.isEmpty { roomState.setError("无法读取所选图片。") }
            } catch is CancellationError {
                return
            } catch {
                guard mediaPreparationID == preparationID else { return }
                roomState.setError(error.localizedDescription)
            }
            guard mediaPreparationID == preparationID else { return }
            isPreparingMedia = false
            mediaPreparationTask = nil
        }
    }

    func stageCapturedImage(_ image: UIImage) {
        guard canCompose,
              !isSubmittingComposer,
              stagedMedia.count < imageSelectionLimit
        else { return }
        roomState.clearError()
        stagedMedia.append(ChatRoomPendingImage(image: image))
    }

    func removeStagedImage(at index: Int) {
        guard stagedMedia.indices.contains(index), !isSubmittingComposer else { return }
        let removed = stagedMedia.remove(at: index)
        if let asset = removed.uploadedAsset {
            Task { [mediaService] in await mediaService.deleteUploadedImage(asset) }
        }
    }

    func submitText() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        requestSend(.text(text, pendingQuote))
    }

    func submitComposer() {
        requestSend(stagedMedia.isEmpty ? .text(draftText, pendingQuote) : .images)
    }

    func retryFailedSend() {
        guard let send = failedSend else { return }
        launchSend(send)
    }

    func cancelActiveMediaWork() {
        mediaPreparationTask?.cancel()
        mediaPreparationTask = nil
        mediaPreparationID = nil
        isPreparingMedia = false
        guard isSubmittingComposer, !stagedMedia.isEmpty else { return }
        mediaCancellationRequested = true
        isCancellingMediaSend = true
    }

    func openOtherUserProfile() {
        guard !blockRelation.isBlockedByOther else {
            roomState.setError("对方已将你拉黑，无法访问其主页。")
            return
        }
        navigationDestination = .userProfile(conversation.otherUserId)
    }

    func openSettings() { navigationDestination = .settings }
    func openLinkedPost(_ route: PostDeepLinkRoute) { navigationDestination = .linkedPost(route) }

    func openSharedPost(_ card: SharedPostCardMetadata) {
        guard let postID = card.postId else {
            roomState.setError(L10n.tr("Shared post is unavailable", "分享帖子已不可用"))
            return
        }
        guard PostKind(remoteValue: card.postKind) == .forum else {
            roomState.setError(L10n.tr(
                "This shared content type is not supported yet",
                "暂不支持打开该类型分享内容"
            ))
            return
        }
        navigationDestination = .sharedForumPost(postID)
    }

    func quoteMessage(_ message: Message, senderName: String) {
        pendingQuote = QuotedMessageMetadata(
            messageId: message.id,
            senderName: senderName,
            preview: messageActionPreview(message),
            messageType: message.messageType
        )
    }

    func cancelQuote() {
        pendingQuote = nil
    }

    func reportMessage(_ message: Message) {
        sheetDestination = .reportMessage(.direct(message.id))
    }

    func requestDeleteMessage(_ message: Message) {
        alertDestination = .deleteMessage(
            message.id,
            forEveryone: message.senderId == currentUserID
        )
    }

    func deleteMessage(_ messageID: UUID, forEveryone: Bool) {
        alertDestination = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await chatService.deleteDirectMessage(
                    messageId: messageID,
                    forEveryone: forEveryone
                )
                roomState.removeMessage(id: messageID)
                if pendingQuote?.messageId == messageID {
                    pendingQuote = nil
                }
            } catch {
                roomState.setError(error.localizedDescription)
            }
        }
    }

    private func saveRemark(_ remark: String?) {
        chatService.setConversationRemark(conversationId: conversation.id, remark: remark)
        conversationRemark = chatService.conversationRemark(for: conversation.id)
        conversationDisplayName = chatService.displayName(for: conversation)
    }

    func handleSettingsAction(_ action: ChatRoomSettingsAction) {
        switch action {
        case .setMuted(let isMuted): setConversationMuted(isMuted)
        case .saveRemark(let remark): saveRemark(remark)
        case .report: requestReport()
        case .clearHistory: requestClearHistory()
        case .toggleBlock: requestToggleBlock()
        }
    }

    private func setConversationMuted(_ newValue: Bool) {
        runPrivacyAction { [self] in
            try await chatService.setConversationMuted(
                conversationId: conversation.id,
                isMuted: newValue
            )
            isMuted = newValue
        }
    }

    private func requestReport() { transitionFromSettings(sheet: .reportUser) }
    private func requestClearHistory() { transitionFromSettings(alert: .clearHistoryConfirmation) }
    private func requestToggleBlock() {
        transitionFromSettings(
            alert: blockRelation.isBlockedByMe ? .unblockConfirmation : .blockConfirmation
        )
    }

    func clearConversationHistory() {
        alertDestination = nil
        runPrivacyAction { [self] in
            let clearedAt = try await chatService.clearConversationHistory(
                conversationId: conversation.id
            )
            clearBeforeAt = clearedAt
            roomState.updateMinimumVisibleDate(clearedAt)
        }
    }

    func setBlocked(_ blocked: Bool) {
        alertDestination = nil
        runPrivacyAction { [self] in
            try await chatService.setUserBlocked(conversation.otherUserId, blocked: blocked)
            if blocked {
                draftText = ""
                if isSubmittingComposer, !stagedMedia.isEmpty {
                    discardMediaAfterCancellation = true
                    cancelActiveMediaWork()
                } else {
                    cleanupUploadedAssets(in: stagedMedia)
                    stagedMedia = []
                }
            }
            await loadPrivacyState()
        }
    }

    func submitReport(reason: String, details: String?) async {
        await performPrivacyAction { [self] in
            try await chatService.reportUser(
                reportedUserId: conversation.otherUserId,
                conversationId: conversation.id,
                reason: reason,
                details: details
            )
            sheetDestination = nil
        }
    }

    func clearPresentedError() {
        roomState.clearError()
        failedSend = nil
    }

    private func requestSend(_ send: ChatRoomPendingSend) {
        guard canCompose, !isSubmittingComposer, !isPreparingMedia, hasContent(for: send) else { return }
        launchSend(send)
    }

    private func launchSend(_ send: ChatRoomPendingSend) {
        guard !isSubmittingComposer else { return }
        isSubmittingComposer = true
        failedSend = nil
        roomState.clearError()
        mediaCancellationRequested = false
        isCancellingMediaSend = false

        sendTask = Task { [weak self] in
            guard let self else { return }
            switch send {
            case .text(let text, let quotedMessage):
                await self.sendText(text, quotedMessage: quotedMessage)
            case .images: await self.sendImages()
            }
            self.isSubmittingComposer = false
            self.mediaProgress = nil
            self.isCancellingMediaSend = false
            self.sendTask = nil
        }
    }

    private func sendText(
        _ text: String,
        quotedMessage: QuotedMessageMetadata?
    ) async {
        if await roomState.sendText(text, quotedMessage: quotedMessage) {
            if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                draftText = ""
            }
            if pendingQuote == quotedMessage {
                pendingQuote = nil
            }
        } else {
            failedSend = .text(text, quotedMessage)
            if roomState.errorMessage == nil { roomState.setError("消息发送失败，请重试。") }
        }
    }

    private func messageActionPreview(_ message: Message) -> String {
        if message.messageType == "image" {
            return L10n.tr("Photo", "图片")
        }
        if let card = message.metadata?.postContactCard {
            return card.title
        }
        if let card = message.metadata?.sharedPostCard {
            return card.title
        }
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(160))
    }

    private func sendImages() async {
        let total = stagedMedia.count
        mediaProgress = ChatRoomMediaProgress(completed: 0, total: total)

        while !stagedMedia.isEmpty {
            if mediaCancellationRequested {
                await cancelRemainingImageSend()
                return
            }

            do {
                let asset: ChatMediaAsset
                if let uploadedAsset = stagedMedia[0].uploadedAsset {
                    asset = uploadedAsset
                } else {
                    asset = try await mediaService.uploadImage(
                        stagedMedia[0].image,
                        scope: .direct,
                        scopeID: conversation.id
                    )
                    stagedMedia[0].uploadedAsset = asset
                }

                if mediaCancellationRequested {
                    await cancelRemainingImageSend()
                    return
                }

                let didSend = await roomState.sendImage(asset.reference)
                if mediaCancellationRequested {
                    if didSend { stagedMedia.removeFirst() }
                    await cancelRemainingImageSend()
                    return
                }
                guard didSend else {
                    failedSend = .images
                    if roomState.errorMessage == nil { roomState.setError("图片发送失败，请重试。") }
                    return
                }

                await mediaService.retainUploadedImage(asset)
                stagedMedia.removeFirst()
                mediaProgress = ChatRoomMediaProgress(
                    completed: total - stagedMedia.count,
                    total: total
                )
            } catch {
                failedSend = .images
                roomState.setError(error.localizedDescription)
                return
            }
        }
    }

    private func cancelRemainingImageSend() async {
        for image in stagedMedia {
            if let asset = image.uploadedAsset {
                await mediaService.deleteUploadedImage(asset)
            }
        }
        stagedMedia = discardMediaAfterCancellation
            ? []
            : stagedMedia.map { ChatRoomPendingImage(image: $0.image) }
        failedSend = nil
        mediaCancellationRequested = false
        discardMediaAfterCancellation = false
        roomState.clearError()
    }

    private func hasContent(for send: ChatRoomPendingSend) -> Bool {
        switch send {
        case .text(let text, _):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .images:
            return !stagedMedia.isEmpty
        }
    }

    private func cleanupUploadedAssets(in images: [ChatRoomPendingImage]) {
        let assets = images.compactMap(\.uploadedAsset)
        guard !assets.isEmpty else { return }
        Task { [mediaService] in
            for asset in assets { await mediaService.deleteUploadedImage(asset) }
        }
    }

    private func loadPrivacyState() async {
        let settings = await chatService.fetchDirectConversationSettings(
            conversationId: conversation.id
        )
        isMuted = settings.isMuted
        clearBeforeAt = settings.clearBeforeAt
        blockRelation = await chatService.fetchBlockRelation(with: conversation.otherUserId)
    }

    private func refreshSecondhandPurchaseIntent() async {
        guard let secondhandTransactionService else {
            secondhandPurchaseIntent = nil
            return
        }

        do {
            secondhandPurchaseIntent = try await secondhandTransactionService
                .fetchSecondhandPurchaseIntent(conversationId: conversation.id)
        } catch is CancellationError {
            return
        } catch {
            // Transaction state is supplemental to the room. A temporarily
            // unavailable status RPC must not replace an otherwise usable chat
            // with a full-room loading failure or erase the last valid status.
            return
        }
    }

    private func performSecondhandTransactionAction(
        _ action: @escaping () async throws -> Void
    ) {
        guard !isApplyingSecondhandTransactionAction else { return }
        isApplyingSecondhandTransactionAction = true
        roomState.clearError()

        Task { [weak self] in
            guard let self else { return }
            defer { self.isApplyingSecondhandTransactionAction = false }
            do {
                try await action()
                // The mutation is authoritative. Clear the sticky snapshot
                // before the follow-up fetch so a transient refresh failure
                // cannot leave an ended transaction pinned in the room.
                self.secondhandPurchaseIntent = nil
                await self.refreshSecondhandPurchaseIntent()
            } catch {
                self.roomState.setError(error.localizedDescription)
            }
        }
    }

    private func runPrivacyAction(_ action: @escaping () async throws -> Void) {
        Task { [weak self] in await self?.performPrivacyAction(action) }
    }

    private func performPrivacyAction(_ action: () async throws -> Void) async {
        guard !isApplyingPrivacyAction else { return }
        isApplyingPrivacyAction = true
        defer { isApplyingPrivacyAction = false }
        do {
            try await action()
        } catch {
            roomState.setError(error.localizedDescription)
        }
    }

    private func transitionFromSettings(
        sheet: ChatRoomSheetDestination? = nil,
        alert: ChatRoomAlertDestination? = nil
    ) {
        navigationDestination = nil
        presentationTask?.cancel()
        presentationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self?.sheetDestination = sheet
            self?.alertDestination = alert
        }
    }
}
