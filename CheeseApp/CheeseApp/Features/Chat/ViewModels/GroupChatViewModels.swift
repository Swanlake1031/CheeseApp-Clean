import Combine
import PhotosUI
import SwiftUI
import UIKit

enum GroupChatRoomDestination: Identifiable, Hashable {
    case details
    case userProfile(UUID)
    case sharedForumPost(UUID)

    var id: String {
        switch self {
        case .details:
            return "details"
        case .userProfile(let userID):
            return "profile:\(userID.uuidString)"
        case .sharedForumPost(let postID):
            return "forum:\(postID.uuidString)"
        }
    }
}

enum GroupChatDetailsAlertDestination: Identifiable {
    case leave
    case removeMember(ChatGroupMemberSummary)

    var id: String {
        switch self {
        case .leave:
            return "leave"
        case .removeMember(let member):
            return "remove:\(member.id.uuidString)"
        }
    }
}

@MainActor
final class GroupChatRoomViewModel: ObservableObject {
    let group: ChatGroupPreview
    let roomState: ChatRoomMessageState<GroupMessage>

    @Published var draftText = ""
    @Published private(set) var pendingQuote: QuotedMessageMetadata?
    @Published private(set) var isPreparingImage = false
    @Published private(set) var isSubmittingText = false
    @Published var destination: GroupChatRoomDestination?
    @Published var reportTarget: ChatMessageReportTarget?
    @Published private(set) var pendingDeleteMessageID: UUID?
    @Published private(set) var pendingDeleteForEveryone = false

    private let mediaService: any ChatRoomMediaServicing
    private let chatService: ChatService
    private var roomObservation: AnyCancellable?
    private var mediaTask: Task<Void, Never>?

    init(
        group: ChatGroupPreview,
        roomState: ChatRoomMessageState<GroupMessage>? = nil,
        mediaService: (any ChatRoomMediaServicing)? = nil
    ) {
        self.group = group
        self.roomState = roomState ?? .group(groupID: group.id)
        self.mediaService = mediaService ?? LiveChatRoomMediaService()
        self.chatService = .shared

        roomObservation = self.roomState.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        mediaTask?.cancel()
    }

    var messages: [GroupMessage] { roomState.messages }
    var isLoading: Bool { roomState.isLoading }
    var isLoadingOlderHistory: Bool { roomState.isLoadingOlderHistory }
    var hasMoreHistory: Bool { roomState.hasMoreHistory }
    var historyErrorMessage: String? { roomState.historyErrorMessage }
    var isComposerBusy: Bool { isSubmittingText || isPreparingImage }
    var displayedError: String? { roomState.errorMessage }
    var scrollToMessageID: UUID? { roomState.scrollToMessageID }

    func bootstrap() async {
        await roomState.bootstrap()
    }

    func stopOnDisappear() {
        guard destination == nil else { return }
        mediaTask?.cancel()
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
        let pendingText = draftText
        let quotedMessage = pendingQuote
        guard !isSubmittingText,
              !pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        isSubmittingText = true
        Task { [weak self] in
            guard let self else { return }
            let didSend = await roomState.sendText(
                pendingText,
                quotedMessage: quotedMessage
            )
            if didSend {
                if draftText == pendingText {
                    draftText = ""
                }
                if pendingQuote == quotedMessage {
                    pendingQuote = nil
                }
            }
            isSubmittingText = false
        }
    }

    func quoteMessage(_ message: GroupMessage, isMine: Bool) {
        pendingQuote = QuotedMessageMetadata(
            messageId: message.id,
            senderName: isMine ? L10n.tr("Me", "我") : message.senderName,
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

    func submitImageSelection(_ item: PhotosPickerItem) {
        guard mediaTask == nil, !isComposerBusy else { return }
        isPreparingImage = true
        roomState.clearError()

        mediaTask = Task { [weak self] in
            guard let self else { return }
            await sendImage(item)
            isPreparingImage = false
            mediaTask = nil
        }
    }

    func submitCapturedImage(_ image: UIImage) {
        guard mediaTask == nil, !isComposerBusy else { return }
        isPreparingImage = true
        roomState.clearError()

        mediaTask = Task { [weak self] in
            guard let self else { return }
            await sendImage(image)
            isPreparingImage = false
            mediaTask = nil
        }
    }

    private func sendImage(_ item: PhotosPickerItem) async {
        do {
            guard let image = try await mediaService.loadImages(from: [item]).first else {
                roomState.setError("无法读取所选图片。")
                return
            }
            try Task.checkCancellation()
            await sendImage(image)
        } catch is CancellationError {
            // Leaving the room cancels unsent media without presenting an error.
        } catch {
            roomState.setError(error.localizedDescription)
        }
    }

    private func sendImage(_ image: UIImage) async {
        var uploadedAsset: ChatMediaAsset?
        var didSend = false

        do {
            let asset = try await mediaService.uploadImage(
                image,
                scope: .group,
                scopeID: group.id
            )
            uploadedAsset = asset
            try Task.checkCancellation()

            didSend = await roomState.sendImage(asset.reference)
            if !didSend, roomState.errorMessage == nil {
                roomState.setError("图片发送失败，请重试。")
            }
            if didSend {
                await mediaService.retainUploadedImage(asset)
            }
        } catch is CancellationError {
            // Leaving the room cancels unsent media without presenting an error.
        } catch {
            roomState.setError(error.localizedDescription)
        }

        if let uploadedAsset, !didSend {
            await mediaService.deleteUploadedImage(uploadedAsset)
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
}

@MainActor
final class GroupChatDetailsViewModel: ObservableObject {
    let group: ChatGroupPreview

    @Published private(set) var members: [ChatGroupMemberSummary] = []
    @Published private(set) var isMuted = false
    @Published private(set) var isOwner = false
    @Published private(set) var isLoading = true
    @Published private(set) var isSavingMute = false
    @Published private(set) var isLeaving = false
    @Published private(set) var isRemovingMember = false
    @Published private(set) var errorMessage: String?
    @Published var alertDestination: GroupChatDetailsAlertDestination?
    @Published var profileUserID: UUID?

    private let chatService: ChatService
    private var hasLoaded = false

    init(group: ChatGroupPreview) {
        self.group = group
        self.chatService = ChatService.shared
    }

    var effectiveMemberCount: Int {
        members.isEmpty ? max(group.memberCount, 1) : members.count
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

        let settings = await settingsTask
        let ownerFlag = await ownerTask
        isMuted = settings.isMuted
        isOwner = ownerFlag

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
