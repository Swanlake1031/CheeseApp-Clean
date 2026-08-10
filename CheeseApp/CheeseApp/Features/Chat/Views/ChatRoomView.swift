//
//  ChatRoomView.swift
//  CheeseApp
//
//  Direct-message presentation. Workflow state lives in ChatRoomViewModel.
//

import PhotosUI
import SwiftUI
import UIKit

enum ChatComposerLayout {
    static func keyboardOverlapHeight(from notification: Notification) -> CGFloat {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return 0
        }
        let screenHeight = UIScreen.main.bounds.height
        let overlap = max(0, screenHeight - frame.origin.y)
        let safeBottom = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
        return max(0, overlap - safeBottom)
    }
}

private struct ChatComposerContainerModifier: ViewModifier {
    let topGap: CGFloat
    let keyboardHeight: CGFloat
    let horizontalPadding: CGFloat
    let restingBottomPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topGap)
            .padding(.bottom, keyboardHeight > 0 ? topGap : restingBottomPadding)
            .background(Color.white)
            .overlay(alignment: .top) {
                Divider()
            }
            .animation(.easeOut(duration: 0.2), value: keyboardHeight)
    }
}

extension View {
    func chatComposerContainer(
        topGap: CGFloat,
        keyboardHeight: CGFloat,
        horizontalPadding: CGFloat = 12,
        restingBottomPadding: CGFloat = 12
    ) -> some View {
        modifier(
            ChatComposerContainerModifier(
                topGap: topGap,
                keyboardHeight: keyboardHeight,
                horizontalPadding: horizontalPadding,
                restingBottomPadding: restingBottomPadding
            )
        )
    }
}

struct ChatRoomView: View {
    let conversation: ChatConversationPreview

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @StateObject private var viewModel: ChatRoomViewModel
    @State private var selectedImageItems: [PhotosPickerItem] = []
    @State private var showingMediaSourceMenu = false
    @State private var showingPhotoLibrary = false
    @State private var showingCamera = false
    @State private var keyboardHeight: CGFloat = 0

    private let composerVerticalGap: CGFloat = 8

    init(conversation: ChatConversationPreview) {
        self.conversation = conversation
        _viewModel = StateObject(
            wrappedValue: ChatRoomViewModel(conversation: conversation)
        )
    }

    private var currentUserID: UUID? { authService.currentUser?.id }
    private var composerInputHeight: CGFloat {
        let explicitLineCount = viewModel.draftText.reduce(into: 1) { count, char in
            if char == "\n" { count += 1 }
        }
        return min(74, max(42, CGFloat(explicitLineCount) * 20 + 14))
    }

    var body: some View {
        contentView
            .background(AppColors.pageBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .cheeseTabBarHidden(true)
            .dismissKeyboardOnTap()
            .task {
                await viewModel.bootstrap(currentUserID: currentUserID)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillChangeFrameNotification
                )
            ) { notification in
                updateKeyboardHeight(notification)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillHideNotification
                )
            ) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    keyboardHeight = 0
                }
            }
            .onDisappear {
                viewModel.stopOnDisappear()
            }
            .onChange(of: selectedImageItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                selectedImageItems = []
                viewModel.stageMediaSelections(newItems)
            }
            .navigationDestination(item: $viewModel.navigationDestination) { destination in
                navigationView(for: destination)
            }
            .sheet(item: $viewModel.sheetDestination) { destination in
                sheetView(for: destination)
            }
            .alert(item: $viewModel.alertDestination) { destination in
                alert(for: destination)
            }
            .enableSwipeBackGesture()
            .safeAreaInset(edge: .top) {
                topBar
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composerView
            }
    }

    @ViewBuilder
    private var contentView: some View {
        if viewModel.isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text(L10n.tr("Loading messages...", "正在载入讯息..."))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            messageTimeline
        }
    }

    private var messageTimeline: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    if viewModel.isLoadingOlderHistory {
                        ProgressView()
                            .padding(.vertical, 6)
                    } else if viewModel.hasMoreHistory {
                        Button(L10n.tr("Load earlier messages", "加载更早消息")) {
                            let anchorID = viewModel.messages.first?.id
                            Task {
                                await viewModel.loadOlderHistory()
                                if let anchorID {
                                    proxy.scrollTo(anchorID, anchor: .top)
                                }
                            }
                        }
                        .font(.system(size: 13, weight: .medium))
                    }

                    if let historyError = viewModel.historyErrorMessage {
                        Button {
                            Task { await viewModel.loadOlderHistory() }
                        } label: {
                            Text("\(historyError) · \(L10n.tr("Retry", "重试"))")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                    }

                    if let error = viewModel.displayedRoomError {
                        errorBanner(error)
                            .padding(.horizontal, 12)
                    }

                    ForEach(ChatRoomMessageTimeline.entries(for: viewModel.messages)) { entry in
                        if entry.showsTimeSeparator {
                            ChatTimelineTimeSeparator(date: entry.message.createdAt)
                        }
                        messageBubble(entry.message)
                            .id(entry.message.id)
                    }

                    Spacer(minLength: 10)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                TapGesture().onEnded {
                    dismissDraftKeyboard()
                }
            )
            .onChange(of: viewModel.scrollToMessageID) { _, newID in
                scrollTo(newID, using: proxy)
            }
            .onChange(of: keyboardHeight) { _, newHeight in
                guard newHeight > 0 else { return }
                DispatchQueue.main.async {
                    scrollTo(viewModel.messages.last?.id, using: proxy)
                }
            }
            .onAppear {
                if let lastMessageID = viewModel.messages.last?.id {
                    proxy.scrollTo(lastMessageID, anchor: .bottom)
                }
            }
        }
    }

    private var topBar: some View {
        VStack(spacing: 0) {
            CheeseInlineTopBar {
                Button(action: { dismiss() }) {
                    PostToolbarIconCircle(icon: "chevron.left")
                }
                .buttonStyle(.plain)
            } center: {
                Button {
                    viewModel.openOtherUserProfile()
                } label: {
                    HStack(spacing: 8) {
                        chatHeaderAvatar(size: 28)
                        Text(viewModel.conversationDisplayName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            } trailing: {
                Button {
                    viewModel.openSettings()
                } label: {
                    PostToolbarIconCircle(icon: "square.grid.2x2")
                }
                .buttonStyle(.plain)
            }

            if viewModel.shouldShowStrangerSafetyBanner {
                strangerSafetyBanner
            }
        }
    }

    private var strangerSafetyBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)

            Text("你和对方尚未互相关注。请注意隐私和交易安全。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.orange)
                .frame(width: 3)
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var composerView: some View {
        VStack(spacing: 8) {
            composerHint

            if let quotedMessage = viewModel.pendingQuote {
                pendingQuoteView(quotedMessage)
            }

            if viewModel.isPreparingMedia {
                mediaPreparationStatus
            } else if let progress = viewModel.mediaProgress {
                mediaUploadStatus(progress: progress)
            }

            if !viewModel.stagedImages.isEmpty {
                stagedImageStrip
            }

            HStack(spacing: 10) {
                mediaPicker
                composerTextField
                sendButton
            }
        }
        .chatComposerContainer(
            topGap: composerVerticalGap,
            keyboardHeight: keyboardHeight
        )
    }

    @ViewBuilder
    private var composerHint: some View {
        if viewModel.blockRelation.isEitherBlocked {
            Text(viewModel.blockedComposeHint)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
        } else if let hint = viewModel.strangerComposerHint {
            Text(hint)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
        }
    }

    private var mediaPreparationStatus: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在处理图片…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button("取消") {
                viewModel.cancelActiveMediaWork()
            }
            .font(.system(size: 12, weight: .semibold))
        }
    }

    private func mediaUploadStatus(progress: ChatRoomMediaProgress) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: progress.fraction)
                .frame(maxWidth: 110)
            Text(
                viewModel.isCancellingMediaSend
                    ? "正在停止发送…"
                    : "已发送 \(progress.completed)/\(progress.total) 张"
            )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button("停止发送") {
                viewModel.cancelActiveMediaWork()
            }
            .font(.system(size: 12, weight: .semibold))
            .disabled(viewModel.isCancellingMediaSend)
        }
    }

    private var mediaPicker: some View {
        let isPreparingMedia = viewModel.isPreparingMedia

        return Button {
            showingMediaSourceMenu = true
        } label: {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isPreparingMedia ? .secondary : AppColors.textPrimary)
                .frame(width: 36, height: 36)
                .background(Color.white)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isPreparingMedia || viewModel.isSubmittingComposer || !viewModel.canCompose)
        .confirmationDialog(
            L10n.tr("Add photo", "添加图片"),
            isPresented: $showingMediaSourceMenu,
            titleVisibility: .visible
        ) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(L10n.tr("Take Photo", "拍照")) {
                    dismissDraftKeyboard()
                    showingCamera = true
                }
            }
            Button(L10n.tr("Choose from Library", "从相册选择")) {
                showingPhotoLibrary = true
            }
            Button(L10n.tr("Cancel", "取消"), role: .cancel) {}
        }
        .photosPicker(
            isPresented: $showingPhotoLibrary,
            selection: $selectedImageItems,
            maxSelectionCount: viewModel.imageSelectionLimit,
            selectionBehavior: .ordered,
            matching: .images,
            photoLibrary: .shared()
        )
        .fullScreenCover(isPresented: $showingCamera) {
            CameraImagePicker(
                onCapture: { image in
                    viewModel.stageCapturedImage(image)
                    showingCamera = false
                },
                onCancel: {
                    showingCamera = false
                }
            )
            .ignoresSafeArea()
        }
    }

    private var composerTextField: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.draftText.isEmpty {
                Text(L10n.tr("Type a message...", "输入消息..."))
                    .font(.system(size: 15))
                    .foregroundStyle(AppColors.textMuted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }

            PressEnterComposerField(text: $viewModel.draftText) {
                viewModel.submitText()
                dismissDraftKeyboard()
            }
            .frame(height: composerInputHeight)
            .padding(.horizontal, 12)
            .disabled(!viewModel.canCompose || viewModel.isSubmittingComposer)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .cheeseInputChrome(cornerRadius: 14)
    }

    private var sendButton: some View {
        Button {
            viewModel.submitComposer()
            dismissDraftKeyboard()
        } label: {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 36, height: 36)
                .background(AppColors.accent)
                .clipShape(Circle())
        }
        .overlay(alignment: .topTrailing) {
            if !viewModel.stagedImages.isEmpty {
                Text("\(viewModel.stagedImages.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Color.red)
                    .clipShape(Circle())
                    .offset(x: 4, y: -4)
            }
        }
        .disabled(
            viewModel.isSubmittingComposer
                || viewModel.isPreparingMedia
                || !viewModel.canCompose
                || !viewModel.hasComposerContent
        )
        .opacity(
            viewModel.isSubmittingComposer
                || viewModel.isPreparingMedia
                || !viewModel.canCompose
                || !viewModel.hasComposerContent ? 0.5 : 1
        )
    }

    private var stagedImageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.stagedImages.indices, id: \.self) { index in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: viewModel.stagedImages[index])
                            .resizable()
                            .scaledToFill()
                            .frame(width: 62, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Button {
                            viewModel.removeStagedImage(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.black.opacity(0.72))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                    }
                    .padding(.top, 5)
                    .padding(.trailing, 5)
                }
            }
        }
        .frame(height: 72)
    }

    private func pendingQuoteView(_ quotedMessage: QuotedMessageMetadata) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(AppColors.link)
                .frame(width: 2, height: 18)

            (
                Text("\(quotedMessage.senderName)：")
                    .fontWeight(.semibold)
                    .foregroundStyle(AppColors.link)
                + Text(quotedMessage.displayPreview)
                    .foregroundStyle(AppColors.textMuted)
            )
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer(minLength: 0)

            Button {
                viewModel.cancelQuote()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("Cancel reply", "取消引用"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .fixedSize(horizontal: false, vertical: true)
        .background(AppColors.pageBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func messageBubble(_ message: Message) -> some View {
        let isMine = currentUserID != nil && message.senderId == currentUserID

        return HStack(alignment: .center, spacing: 8) {
            if isMine { Spacer(minLength: 40) }
            if !isMine {
                Button {
                    viewModel.openOtherUserProfile()
                } label: {
                    directMessageAvatar(isMine: false, size: 30)
                }
                .buttonStyle(.plain)
            }

            ChatMessageContentView(
                message: message,
                isMine: isMine,
                onOpenPostRoute: viewModel.openLinkedPost,
                onOpenSharedPost: viewModel.openSharedPost
            )
            .contextMenu {
                messageContextMenu(message, isMine: isMine)
            }

            if isMine {
                directMessageAvatar(isMine: true, size: 30)
            }
            if !isMine { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private func messageContextMenu(_ message: Message, isMine: Bool) -> some View {
        Button {
            UIPasteboard.general.string = messageCopyText(message)
        } label: {
            Label(L10n.tr("Copy", "复制"), systemImage: "doc.on.doc")
        }

        Button {
            let senderName = isMine
                ? L10n.tr("Me", "我")
                : viewModel.conversationDisplayName
            viewModel.quoteMessage(message, senderName: senderName)
        } label: {
            Label(L10n.tr("Quote", "引用"), systemImage: "quote.bubble")
        }

        Button(role: .destructive) {
            viewModel.requestDeleteMessage(message)
        } label: {
            Label(L10n.tr("Delete", "删除"), systemImage: "trash")
        }

        if !isMine {
            Button(role: .destructive) {
                viewModel.reportMessage(message)
            } label: {
                Label(L10n.tr("Report", "举报"), systemImage: "flag")
            }
        }
    }

    private func messageCopyText(_ message: Message) -> String {
        if message.messageType == "image" {
            return L10n.tr("Photo", "图片")
        }
        if let card = message.metadata?.postContactCard {
            return card.title
        }
        if let card = message.metadata?.sharedPostCard {
            return card.title
        }
        return message.content
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if viewModel.canRetry {
                Button("重试") {
                    viewModel.retryFailedSend()
                }
                .font(.system(size: 12, weight: .semibold))
            }
            Button {
                viewModel.clearPresentedError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .cheeseCardChrome(cornerRadius: 12)
    }

    @ViewBuilder
    private func navigationView(for destination: ChatRoomNavigationDestination) -> some View {
        switch destination {
        case .userProfile(let userID):
            UserPostsView(userId: userID)
        case .sharedForumPost(let postID):
            ChatSharedForumDetailLoaderView(postId: postID)
        case .linkedPost(let route):
            DeepLinkedPostPresenterView(route: route)
        case .settings:
            ChatRoomSettingsView(
                conversation: conversation,
                remark: viewModel.conversationRemark,
                isMuted: viewModel.isMuted,
                blockRelation: viewModel.blockRelation,
                isBusy: viewModel.isApplyingPrivacyAction,
                onToggleMute: { viewModel.handleSettingsAction(.setMuted($0)) },
                onSaveRemark: { viewModel.handleSettingsAction(.saveRemark($0)) },
                onReport: { viewModel.handleSettingsAction(.report) },
                onClearHistory: { viewModel.handleSettingsAction(.clearHistory) },
                onToggleBlock: { viewModel.handleSettingsAction(.toggleBlock) }
            )
        }
    }

    @ViewBuilder
    private func sheetView(for destination: ChatRoomSheetDestination) -> some View {
        switch destination {
        case .reportUser:
            ReportUserSheet(isSubmitting: viewModel.isApplyingPrivacyAction) { reason, details in
                await viewModel.submitReport(reason: reason, details: details)
            }
        case .reportMessage(let target):
            ReportMessageSheet(target: target)
        }
    }

    private func alert(for destination: ChatRoomAlertDestination) -> Alert {
        switch destination {
        case .strangerEntry:
            return Alert(
                title: Text("陌生人消息"),
                message: Text("你和对方尚未互相关注。请勿透露验证码、住址等敏感信息，交易前请确认对方身份。"),
                dismissButton: .default(Text("我知道了")) {
                    viewModel.acknowledgeStrangerSafety()
                }
            )
        case .strangerSendConfirmation:
            return Alert(
                title: Text("发送给陌生人？"),
                message: Text("你们尚未互相关注。在对方回复前，你只能发送一条消息。请注意隐私和交易安全。"),
                primaryButton: .cancel(Text("取消")) {
                    viewModel.cancelPendingSend()
                },
                secondaryButton: .default(Text("继续发送")) {
                    viewModel.confirmPendingSend()
                }
            )
        case .clearHistoryConfirmation:
            return Alert(
                title: Text("清空聊天记录？"),
                message: Text("仅会清空你自己的会话记录视图，不会删除对方的消息。"),
                primaryButton: .cancel(),
                secondaryButton: .destructive(Text("清空")) {
                    viewModel.clearConversationHistory()
                }
            )
        case .blockConfirmation:
            return Alert(
                title: Text("确认拉黑该用户？"),
                message: Text("拉黑后会保留聊天框，但双方都无法继续发送消息；对方也无法访问你的主页和帖子。"),
                primaryButton: .cancel(),
                secondaryButton: .destructive(Text("拉黑")) {
                    viewModel.setBlocked(true)
                }
            )
        case .unblockConfirmation:
            return Alert(
                title: Text("解除拉黑？"),
                message: Text("解除后，双方可恢复发送私信和访问主页。"),
                primaryButton: .cancel(),
                secondaryButton: .destructive(Text("解除")) {
                    viewModel.setBlocked(false)
                }
            )
        case .deleteMessage(let messageID, let forEveryone):
            return Alert(
                title: Text(L10n.tr("Delete this message?", "删除这则讯息？")),
                message: Text(
                    forEveryone
                        ? L10n.tr(
                            "This message will be removed for everyone and cannot be restored.",
                            "这则讯息会对所有人移除，且无法复原。"
                        )
                        : L10n.tr(
                            "This message will only be hidden from your chat history.",
                            "这则讯息只会从你的聊天记录隐藏。"
                        )
                ),
                primaryButton: .cancel(Text(L10n.tr("Cancel", "取消"))),
                secondaryButton: .destructive(Text(L10n.tr("Delete", "删除"))) {
                    viewModel.deleteMessage(messageID, forEveryone: forEveryone)
                }
            )
        }
    }

    private func directMessageAvatar(isMine: Bool, size: CGFloat) -> some View {
        let avatarURL = isMine ? authService.currentUser?.avatarUrl : conversation.otherUserAvatar
        let fallbackName = isMine
            ? (authService.currentUser?.fullName ?? "Me")
            : viewModel.conversationDisplayName

        return Group {
            if let avatarURL,
               let url = URL(string: avatarURL),
               !avatarURL.isEmpty {
                CachedRemoteImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    avatarFallback(name: fallbackName, size: size)
                }
            } else {
                avatarFallback(name: fallbackName, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func chatHeaderAvatar(size: CGFloat) -> some View {
        Group {
            if let avatar = conversation.otherUserAvatar,
               let url = URL(string: avatar),
               !avatar.isEmpty {
                CachedRemoteImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    avatarFallback(name: viewModel.conversationDisplayName, size: size)
                }
            } else {
                avatarFallback(name: viewModel.conversationDisplayName, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func avatarFallback(name: String, size: CGFloat) -> some View {
        Circle()
            .fill(Color.gray.opacity(0.15))
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(.gray)
            }
    }

    private func dismissDraftKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func updateKeyboardHeight(_ notification: Notification) {
        let nextHeight = ChatComposerLayout.keyboardOverlapHeight(from: notification)
        withAnimation(.easeOut(duration: 0.2)) {
            keyboardHeight = nextHeight
            if nextHeight > 0, !viewModel.messages.isEmpty {
                viewModel.requestScrollToLatest()
            }
        }
    }

    private func scrollTo<ID: Hashable>(_ id: ID?, using proxy: ScrollViewProxy) {
        guard let id else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}
