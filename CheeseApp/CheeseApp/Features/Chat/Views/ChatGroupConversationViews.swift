//
//  ChatGroupConversationViews.swift
//  CheeseApp
//
//  💬 群聊消息页面
//

import PhotosUI
import SwiftUI
import UIKit

struct GroupChatRoomView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @StateObject private var viewModel: GroupChatRoomViewModel
    @State private var selectedImageItem: PhotosPickerItem?
    @State private var showingMediaSourceMenu = false
    @State private var showingPhotoLibrary = false
    @State private var showingCamera = false
    @State private var keyboardHeight: CGFloat = 0
    @FocusState private var isDraftFocused: Bool

    private let composerVerticalGap: CGFloat = 10

    init(group: ChatGroupPreview) {
        _viewModel = StateObject(wrappedValue: GroupChatRoomViewModel(group: group))
    }

    private var currentUserID: UUID? { authService.currentUser?.id }

    var body: some View {
        contentView
            .background(AppColors.pageBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .cheeseTabBarHidden(true)
            .dismissKeyboardOnTap()
            .task {
                await viewModel.bootstrap()
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
            .onChange(of: selectedImageItem) { _, newItem in
                guard let newItem else { return }
                selectedImageItem = nil
                viewModel.submitImageSelection(newItem)
            }
            .navigationDestination(item: $viewModel.destination) { destination in
                destinationView(destination)
            }
            .sheet(item: $viewModel.reportTarget) { target in
                ReportMessageSheet(target: target)
            }
            .alert(
                L10n.tr("Delete this message?", "删除这则讯息？"),
                isPresented: deleteAlertBinding
            ) {
                Button(L10n.tr("Cancel", "取消"), role: .cancel) {
                    viewModel.cancelDeleteMessage()
                }
                Button(L10n.tr("Delete", "删除"), role: .destructive) {
                    viewModel.confirmDeleteMessage()
                }
            } message: {
                Text(
                    viewModel.pendingDeleteForEveryone
                        ? L10n.tr(
                            "This message will be removed for everyone and cannot be restored.",
                            "这则讯息会对所有人移除，且无法复原。"
                        )
                        : L10n.tr(
                            "This message will only be hidden from your chat history.",
                            "这则讯息只会从你的聊天记录隐藏。"
                        )
                )
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
                Text("正在加载群消息...")
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
                        Button("加载更早消息") {
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
                        Button("\(historyError) · 重试") {
                            Task { await viewModel.loadOlderHistory() }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                    }

                    if let error = viewModel.displayedError {
                        InlineErrorBanner(text: error)
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
                guard let newID else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .bottom)
                }
            }
            .onChange(of: keyboardHeight) { _, newHeight in
                guard newHeight > 0, let lastMessageID = viewModel.messages.last?.id else {
                    return
                }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(lastMessageID, anchor: .bottom)
                    }
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
        CheeseInlineTopBar {
            Button(action: { dismiss() }) {
                PostToolbarIconCircle(icon: "chevron.left")
            }
            .buttonStyle(.plain)
        } center: {
            Text(viewModel.group.displayName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
        } trailing: {
            Button {
                viewModel.openDetails()
            } label: {
                PostToolbarIconCircle(icon: "ellipsis")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("群聊详情")
        }
    }

    private var composerView: some View {
        let isPreparingImage = viewModel.isPreparingImage

        return VStack(spacing: 8) {
            if let quotedMessage = viewModel.pendingQuote {
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
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .fixedSize(horizontal: false, vertical: true)
                .background(AppColors.pageBackground)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            HStack(spacing: 10) {
                Button {
                    showingMediaSourceMenu = true
                } label: {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(
                            isPreparingImage ? .secondary : AppColors.textPrimary
                        )
                        .frame(width: 40, height: 40)
                        .background(Color.white)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isComposerBusy)
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
                    selection: $selectedImageItem,
                    matching: .images,
                    photoLibrary: .shared()
                )
                .fullScreenCover(isPresented: $showingCamera) {
                    CameraImagePicker(
                        onCapture: { image in
                            viewModel.submitCapturedImage(image)
                            showingCamera = false
                        },
                        onCancel: {
                            showingCamera = false
                        }
                    )
                    .ignoresSafeArea()
                }

                TextField("输入消息...", text: $viewModel.draftText, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($isDraftFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .cheeseInputChrome(cornerRadius: 14)

                Button {
                    viewModel.submitText()
                    dismissDraftKeyboard()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 42, height: 42)
                        .background(AppColors.accent)
                        .clipShape(Circle())
                }
                .disabled(
                    viewModel.isComposerBusy
                        || viewModel.draftText.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                )
                .opacity(
                    viewModel.isComposerBusy
                        || viewModel.draftText.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty ? 0.5 : 1
                )
            }
        }
        .chatComposerContainer(
            topGap: composerVerticalGap,
            keyboardHeight: keyboardHeight
        )
    }

    private func messageBubble(_ message: GroupMessage) -> some View {
        let isMine = currentUserID != nil && message.senderId == currentUserID

        return HStack(alignment: .center, spacing: 8) {
            if isMine { Spacer(minLength: 40) }
            if !isMine {
                Button {
                    viewModel.openProfile(message.senderId)
                } label: {
                    groupMessageAvatar(message: message, isMine: false, size: 30)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                if !isMine {
                    Text(message.senderName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColors.textMuted)
                }

                messageContentView(message, isMine: isMine)
                    .contextMenu {
                        groupMessageContextMenu(message, isMine: isMine)
                    }
            }

            if isMine {
                Button {
                    viewModel.openProfile(currentUserID)
                } label: {
                    groupMessageAvatar(message: message, isMine: true, size: 30)
                }
                .buttonStyle(.plain)
            }
            if !isMine { Spacer(minLength: 40) }
        }
    }

    private func messageContentView(_ message: GroupMessage, isMine: Bool) -> some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
            if let quotedMessage = message.metadata?.quotedMessage {
                ChatQuotedMessageView(quotedMessage: quotedMessage, isMine: isMine)
            }

            Group {
                if let card = message.metadata?.sharedPostCard {
                    ChatSharedPostCardView(card: card, onOpen: viewModel.openSharedPost)
                } else if message.messageType == "image",
                   let reference = message.metadata?.chatMediaReference,
                   reference.belongs(to: .group, id: message.groupId) {
                    ChatPrivateMediaImageView(reference: reference)
                } else if message.messageType == "image" {
                    ChatPrivateMediaUnavailableView()
                } else {
                    Text(message.content)
                        .font(.system(size: 15))
                        .foregroundStyle(isMine ? .black : AppColors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(isMine ? AppColors.chatOutgoingBubble : Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(
                                    isMine ? Color.clear : Color.black.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                }
            }
        }
    }

    @ViewBuilder
    private func groupMessageContextMenu(_ message: GroupMessage, isMine: Bool) -> some View {
        Button {
            UIPasteboard.general.string = message.messageType == "image"
                ? L10n.tr("Photo", "图片")
                : message.content
        } label: {
            Label(L10n.tr("Copy", "复制"), systemImage: "doc.on.doc")
        }

        Button {
            viewModel.quoteMessage(message, isMine: isMine)
        } label: {
            Label(L10n.tr("Quote", "引用"), systemImage: "quote.bubble")
        }

        Button(role: .destructive) {
            viewModel.requestDeleteMessage(message, isMine: isMine)
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

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingDeleteMessageID != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.cancelDeleteMessage()
                }
            }
        )
    }

    private func groupMessageAvatar(
        message: GroupMessage,
        isMine: Bool,
        size: CGFloat
    ) -> some View {
        let avatarURL = isMine ? authService.currentUser?.avatarUrl : message.senderAvatar
        let fallbackName = isMine
            ? (authService.currentUser?.fullName ?? "Me")
            : message.senderName

        return Group {
            if let avatarURL,
               let url = URL(string: avatarURL),
               !avatarURL.isEmpty {
                CachedRemoteImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    groupMessageAvatarFallback(name: fallbackName, size: size)
                }
            } else {
                groupMessageAvatarFallback(name: fallbackName, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func groupMessageAvatarFallback(name: String, size: CGFloat) -> some View {
        Circle()
            .fill(Color.gray.opacity(0.15))
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(.gray)
            }
    }

    @ViewBuilder
    private func destinationView(_ destination: GroupChatRoomDestination) -> some View {
        switch destination {
        case .details:
            GroupChatDetailsView(group: viewModel.group) {
                viewModel.roomState.stop()
                dismiss()
            }
        case .userProfile(let userID):
            UserPostsView(userId: userID)
        case .sharedForumPost(let postID):
            ChatSharedForumDetailLoaderView(postId: postID)
        }
    }

    private func dismissDraftKeyboard() {
        isDraftFocused = false
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
}
