import Combine
import PhotosUI
import SwiftUI
import UIKit

enum GroupChatRoomDestination: Identifiable, Hashable {
    case details
    case history
    case userProfile(UUID)
    case sharedForumPost(UUID)

    var id: String {
        switch self {
        case .details:
            return "details"
        case .history:
            return "history"
        case .userProfile(let userID):
            return "profile:\(userID.uuidString)"
        case .sharedForumPost(let postID):
            return "forum:\(postID.uuidString)"
        }
    }
}

enum GroupChatDetailsAlertDestination: Identifiable {
    case leave
    case clearHistory
    case removeMember(ChatGroupMemberSummary)

    var id: String {
        switch self {
        case .leave:
            return "leave"
        case .clearHistory:
            return "clear-history"
        case .removeMember(let member):
            return "remove:\(member.id.uuidString)"
        }
    }
}

private enum GroupChatRoomPendingSend {
    case text(String, QuotedMessageMetadata?)
    case images
}

@MainActor
final class GroupChatRoomViewModel: ObservableObject {
    let group: ChatGroupPreview
    let roomState: ChatRoomMessageState<GroupMessage>

    @Published var draftText = ""
    @Published private(set) var pendingQuote: QuotedMessageMetadata?
    @Published private var stagedMedia: [ChatRoomPendingImage]
    @Published private(set) var isPreparingMedia = false
    @Published private(set) var isSubmittingComposer = false
    @Published private(set) var mediaProgress: ChatRoomMediaProgress?
    @Published private(set) var isCancellingMediaSend = false
    @Published var destination: GroupChatRoomDestination?
    @Published var reportTarget: ChatMessageReportTarget?
    @Published private(set) var pendingDeleteMessageID: UUID?
    @Published private(set) var pendingDeleteForEveryone = false
    @Published private(set) var groupDisplayName: String
    @Published private(set) var announcement: String?
    @Published private(set) var memberDisplayNamesByID: [UUID: String]

    private let mediaService: any ChatRoomMediaServicing
    private let chatService: ChatService
    private var roomObservation: AnyCancellable?
    private var mediaPreparationTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var mediaPreparationID: UUID?
    private var mediaCancellationRequested = false
    private var memberObservationStop: (() -> Void)?

    init(
        group: ChatGroupPreview,
        roomState: ChatRoomMessageState<GroupMessage>? = nil,
        mediaService: (any ChatRoomMediaServicing)? = nil,
        stagedImages: [UIImage] = []
    ) {
        self.group = group
        self.roomState = roomState ?? .group(groupID: group.id)
        self.mediaService = mediaService ?? LiveChatRoomMediaService()
        self.chatService = .shared
        self.groupDisplayName = group.displayName
        self.announcement = nil
        self.memberDisplayNamesByID = [:]
        self.stagedMedia = stagedImages.map { ChatRoomPendingImage(image: $0) }

        roomObservation = self.roomState.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        mediaPreparationTask?.cancel()
        sendTask?.cancel()
        memberObservationStop?()
    }

    var messages: [GroupMessage] { roomState.messages }
    var stagedImages: [UIImage] { stagedMedia.map(\.image) }
    var isLoading: Bool { roomState.isLoading }
    var isLoadingOlderHistory: Bool { roomState.isLoadingOlderHistory }
    var hasMoreHistory: Bool { roomState.hasMoreHistory }
    var historyErrorMessage: String? { roomState.historyErrorMessage }
    var isComposerBusy: Bool { isSubmittingComposer || isPreparingMedia }
    var hasComposerContent: Bool {
        !stagedMedia.isEmpty
            || !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var imageSelectionLimit: Int { 9 }
    var displayedError: String? { roomState.errorMessage }
    var scrollToMessageID: UUID? { roomState.scrollToMessageID }

    func bootstrap() async {
        async let settingsTask = chatService.fetchGroupConversationSettings(groupId: group.id)
        async let announcementTask = chatService.fetchChatGroupAnnouncement(groupId: group.id)
        async let membersTask = try? chatService.fetchChatGroupMembers(groupId: group.id)
        let (settings, announcement, members) = await (
            settingsTask,
            announcementTask,
            membersTask
        )
        self.announcement = announcement
        applyMembers(members ?? [])
        roomState.updateMinimumVisibleDate(settings.clearBeforeAt)
        await roomState.bootstrap()
        startMemberObservationIfNeeded()
    }

    func stopOnDisappear() {
        guard destination == nil else { return }
        mediaPreparationTask?.cancel()
        mediaPreparationTask = nil
        mediaPreparationID = nil
        isPreparingMedia = false
        if isSubmittingComposer, !stagedMedia.isEmpty {
            mediaCancellationRequested = true
        } else {
            cleanupUploadedAssets(in: stagedMedia)
        }
        roomState.stopOnDisappear(hasNestedDestinationPresented: false)
    }

    func requestScrollToLatest() {
        roomState.requestScrollToLatest()
    }

    func loadOlderHistory() async {
        await roomState.loadOlderHistory()
    }

    func openDetails() {
        destination = .details
    }

    func applyClearedHistory(_ clearedAt: Date) {
        roomState.updateMinimumVisibleDate(clearedAt)
    }

    func applyGroupName(_ name: String) {
        groupDisplayName = name
    }

    func applyAnnouncement(_ announcement: String?) {
        self.announcement = announcement
    }

    func applyMemberDisplayNames(_ names: [UUID: String]) {
        memberDisplayNamesByID = names
    }

    func displayName(for message: GroupMessage) -> String {
        memberDisplayNamesByID[message.senderId] ?? message.senderName
    }

    func openProfile(_ userID: UUID?) {
        guard let userID else { return }
        destination = .userProfile(userID)
    }

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
        destination = .sharedForumPost(postID)
    }

    func submitText() {
        requestSend(.text(draftText, pendingQuote))
    }

    func quoteMessage(_ message: GroupMessage, isMine: Bool) {
        pendingQuote = QuotedMessageMetadata(
            messageId: message.id,
            senderName: isMine ? L10n.tr("Me", "我") : displayName(for: message),
            preview: messageActionPreview(message),
            messageType: message.messageType
        )
    }

    func cancelQuote() {
        pendingQuote = nil
    }

    func reportMessage(_ message: GroupMessage) {
        reportTarget = .group(message.id)
    }

    func requestDeleteMessage(_ message: GroupMessage, isMine: Bool) {
        pendingDeleteMessageID = message.id
        pendingDeleteForEveryone = isMine
    }

    func cancelDeleteMessage() {
        pendingDeleteMessageID = nil
        pendingDeleteForEveryone = false
    }

    func confirmDeleteMessage() {
        guard let messageID = pendingDeleteMessageID else { return }
        let forEveryone = pendingDeleteForEveryone
        cancelDeleteMessage()

        Task { [weak self] in
            guard let self else { return }
            do {
                try await chatService.deleteGroupMessage(
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

    func stageMediaSelections(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, !isSubmittingComposer else { return }
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
                if stagedMedia.isEmpty {
                    roomState.setError("无法读取所选图片。")
                }
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
        guard !isSubmittingComposer,
              stagedMedia.count < imageSelectionLimit
        else { return }
        roomState.clearError()
        stagedMedia.append(ChatRoomPendingImage(image: image))
    }

    func removeStagedImage(at index: Int) {
        guard stagedMedia.indices.contains(index), !isSubmittingComposer else { return }
        let removed = stagedMedia.remove(at: index)
        if let asset = removed.uploadedAsset {
            Task { [mediaService] in
                await mediaService.deleteUploadedImage(asset)
            }
        }
    }

    func submitComposer() {
        requestSend(stagedMedia.isEmpty ? .text(draftText, pendingQuote) : .images)
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

    private func requestSend(_ pendingSend: GroupChatRoomPendingSend) {
        guard !isSubmittingComposer,
              !isPreparingMedia,
              hasContent(for: pendingSend)
        else { return }
        isSubmittingComposer = true
        roomState.clearError()
        mediaCancellationRequested = false
        isCancellingMediaSend = false

        sendTask = Task { [weak self] in
            guard let self else { return }
            switch pendingSend {
            case .text(let text, let quotedMessage):
                await sendText(text, quotedMessage: quotedMessage)
            case .images:
                await sendImages()
            }
            isSubmittingComposer = false
            mediaProgress = nil
            isCancellingMediaSend = false
            sendTask = nil
        }
    }

    private func sendText(
        _ text: String,
        quotedMessage: QuotedMessageMetadata?
    ) async {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if await roomState.sendText(normalized, quotedMessage: quotedMessage) {
            if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == normalized {
                draftText = ""
            }
            if pendingQuote == quotedMessage {
                pendingQuote = nil
            }
        }
    }

    private func sendImages() async {
        let total = stagedMedia.count
        mediaProgress = ChatRoomMediaProgress(completed: 0, total: total)

        while !stagedMedia.isEmpty {
            if mediaCancellationRequested {
                await cancelRemainingImageSend()
                return
            }

            var uploadedAsset: ChatMediaAsset?
            var didSend = false

            do {
                let asset: ChatMediaAsset
                if let existingAsset = stagedMedia[0].uploadedAsset {
                    asset = existingAsset
                } else {
                    asset = try await mediaService.uploadImage(
                        stagedMedia[0].image,
                        scope: .group,
                        scopeID: group.id
                    )
                    stagedMedia[0].uploadedAsset = asset
                }
                uploadedAsset = asset

                if mediaCancellationRequested {
                    await cancelRemainingImageSend()
                    return
                }

                didSend = await roomState.sendImage(asset.reference)
                guard didSend else {
                    if roomState.errorMessage == nil {
                        roomState.setError("图片发送失败，请重试。")
                    }
                    return
                }

                await mediaService.retainUploadedImage(asset)
                stagedMedia.removeFirst()
                mediaProgress = ChatRoomMediaProgress(
                    completed: total - stagedMedia.count,
                    total: total
                )
            } catch is CancellationError {
                await cancelRemainingImageSend()
                return
            } catch {
                roomState.setError(error.localizedDescription)
                if let uploadedAsset, !didSend {
                    // Keep the uploaded asset staged so the user can retry without
                    // uploading the same image again.
                    stagedMedia[0].uploadedAsset = uploadedAsset
                }
                return
            }
        }
    }

    private func cancelRemainingImageSend() async {
        for pendingImage in stagedMedia {
            if let asset = pendingImage.uploadedAsset {
                await mediaService.deleteUploadedImage(asset)
            }
        }
        stagedMedia = stagedMedia.map { ChatRoomPendingImage(image: $0.image) }
        mediaCancellationRequested = false
        isCancellingMediaSend = false
        roomState.clearError()
    }

    private func hasContent(for pendingSend: GroupChatRoomPendingSend) -> Bool {
        switch pendingSend {
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
            for asset in assets {
                await mediaService.deleteUploadedImage(asset)
            }
        }
    }

    private func messageActionPreview(_ message: GroupMessage) -> String {
        if message.messageType == "image" {
            return L10n.tr("Photo", "图片")
        }
        if let card = message.metadata?.sharedPostCard {
            return card.title
        }
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(160))
    }

    private func startMemberObservationIfNeeded() {
        guard memberObservationStop == nil else { return }
        memberObservationStop = chatService.observeChatGroupMemberChanges(
            groupId: group.id
        ) { [weak self] in
            guard let self else { return }
            let members = try? await self.chatService.fetchChatGroupMembers(groupId: self.group.id)
            guard let members else { return }
            await MainActor.run { self.applyMembers(members) }
        }
    }

    private func applyMembers(_ members: [ChatGroupMemberSummary]) {
        memberDisplayNamesByID = Dictionary(
            uniqueKeysWithValues: members.map { ($0.id, $0.displayName) }
        )
    }
}

@MainActor
final class GroupChatDetailsViewModel: ObservableObject {
    let group: ChatGroupPreview

    @Published private(set) var members: [ChatGroupMemberSummary] = []
    @Published private(set) var isMuted = false
    @Published private(set) var isPinned = false
    @Published private(set) var isOwner = false
    @Published private(set) var isLoading = true
    @Published private(set) var isSavingMute = false
    @Published private(set) var isSavingPin = false
    @Published private(set) var isClearingHistory = false
    @Published private(set) var isSavingDetails = false
    @Published private(set) var isLeaving = false
    @Published private(set) var isRemovingMember = false
    @Published private(set) var errorMessage: String?
    @Published var alertDestination: GroupChatDetailsAlertDestination?
    @Published var profileUserID: UUID?
    @Published private(set) var groupName: String
    @Published private(set) var announcement: String?

    private let chatService: ChatService
    private var hasLoaded = false

    init(group: ChatGroupPreview) {
        self.group = group
        self.chatService = ChatService.shared
        self.groupName = group.displayName
        self.announcement = nil
    }

    var effectiveMemberCount: Int {
        members.isEmpty ? max(group.memberCount, 1) : members.count
    }

    var myNickname: String? {
        guard let myID = AuthService.shared.currentUser?.id else { return nil }
        return members.first(where: { $0.id == myID })?.nickname
    }

    var memberDisplayNamesByID: [UUID: String] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.displayName) })
    }

    var leaveAlertTitle: String {
        isOwner ? "确认解散群聊？" : "确认退出群聊？"
    }

    var leaveAlertMessage: String {
        isOwner
            ? "解散后所有群消息将被清空，且无法恢复。"
            : "退出后你将不能继续在该群发送消息。"
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoading = true

        async let settingsTask = chatService.fetchGroupConversationSettings(groupId: group.id)
        async let ownerTask = chatService.isCurrentUserGroupOwner(groupId: group.id)
        async let membersTask = chatService.fetchChatGroupMembers(groupId: group.id)
        async let announcementTask = chatService.fetchChatGroupAnnouncement(groupId: group.id)

        let settings = await settingsTask
        let ownerFlag = await ownerTask
        isMuted = settings.isMuted
        isPinned = settings.isPinned
        isOwner = ownerFlag
        announcement = await announcementTask

        do {
            members = try await membersTask
            errorMessage = nil
        } catch {
            members = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func setMuted(_ newValue: Bool) {
        guard !isSavingMute, !isLeaving else { return }
        let previousValue = isMuted
        isMuted = newValue
        isSavingMute = true

        Task { [weak self] in
            guard let self else { return }
            do {
                try await chatService.setGroupConversationMuted(
                    groupId: group.id,
                    isMuted: newValue
                )
                errorMessage = nil
            } catch {
                isMuted = previousValue
                errorMessage = error.localizedDescription
            }
            isSavingMute = false
        }
    }

    func setPinned(_ newValue: Bool) {
        guard !isSavingPin, !isLeaving else { return }
        let previous = isPinned
        isPinned = newValue
        isSavingPin = true
        Task { [weak self] in
            guard let self else { return }
            defer { isSavingPin = false }
            do {
                try await chatService.setGroupConversationPinned(groupId: group.id, isPinned: newValue)
                errorMessage = nil
            } catch {
                isPinned = previous
                errorMessage = error.localizedDescription
            }
        }
    }

    func renameGroup(_ name: String) async -> Bool {
        guard !isSavingDetails else { return false }
        isSavingDetails = true
        defer { isSavingDetails = false }
        do {
            try await chatService.renameChatGroup(groupId: group.id, name: name)
            groupName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateMyNickname(_ nickname: String?) async -> Bool {
        guard !isSavingDetails else { return false }
        isSavingDetails = true
        defer { isSavingDetails = false }
        do {
            try await chatService.updateMyChatGroupNickname(groupId: group.id, nickname: nickname)
            members = try await chatService.fetchChatGroupMembers(groupId: group.id)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateAnnouncement(_ value: String?) async -> Bool {
        guard isOwner, !isSavingDetails else { return false }
        isSavingDetails = true
        defer { isSavingDetails = false }
        do {
            try await chatService.updateChatGroupAnnouncement(
                groupId: group.id,
                announcement: value
            )
            announcement = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            if announcement?.isEmpty == true { announcement = nil }
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func addMembers(_ ids: [UUID]) async -> Bool {
        guard !isSavingDetails else { return false }
        isSavingDetails = true
        defer { isSavingDetails = false }
        do {
            _ = try await chatService.addChatGroupMembers(groupId: group.id, memberIds: ids)
            members = try await chatService.fetchChatGroupMembers(groupId: group.id)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func requestClearHistory() {
        alertDestination = .clearHistory
    }

    func clearHistory() async -> Date? {
        guard !isClearingHistory else { return nil }
        isClearingHistory = true
        defer { isClearingHistory = false; alertDestination = nil }
        do {
            let date = try await chatService.clearGroupConversationHistory(groupId: group.id)
            errorMessage = nil
            return date
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func requestLeave() {
        alertDestination = .leave
    }

    func requestRemoval(of member: ChatGroupMemberSummary) {
        guard !isRemovingMember else { return }
        alertDestination = .removeMember(member)
    }

    func leaveGroup() async -> Bool {
        guard !isLeaving else { return false }
        isLeaving = true
        defer { isLeaving = false }

        do {
            _ = try await chatService.leaveChatGroup(groupId: group.id)
            await chatService.refreshConversations()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removeMember(_ member: ChatGroupMemberSummary) async {
        guard !isRemovingMember else { return }
        guard member.role != "owner" else {
            errorMessage = "无法移除群主。"
            alertDestination = nil
            return
        }

        isRemovingMember = true
        defer {
            isRemovingMember = false
            alertDestination = nil
        }

        do {
            try await chatService.removeGroupMember(
                groupId: group.id,
                memberUserId: member.id
            )
            members.removeAll { $0.id == member.id }
            await chatService.refreshConversations()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
