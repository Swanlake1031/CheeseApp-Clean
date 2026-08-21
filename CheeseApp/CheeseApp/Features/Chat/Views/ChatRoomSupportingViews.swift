//
//  ChatRoomView.swift
//  CheeseApp
//
//  💬 单聊会话页
//

import SwiftUI

struct ChatSharedForumDetailLoaderView: View {
    let postId: UUID

    @State private var post: ForumPostItem?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let post {
                ForumDetailView(post: post)
            } else {
                VStack(spacing: 12) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(AppColors.textMuted)
                    }

                    Text(errorMessage ?? L10n.tr("Loading post...", "正在加载帖子..."))
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textMuted)
                        .multilineTextAlignment(.center)

                    if !isLoading {
                        Button(L10n.tr("Retry", "重试")) {
                            Task { await load() }
                        }
                        .font(.system(size: 13, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 18)
                .background(AppColors.pageBackground.ignoresSafeArea())
                .task {
                    await load()
                }
            }
        }
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            post = try await ForumService.shared.fetchPost(postId: postId)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ChatRoomSettingsView: View {
    let conversation: ChatConversationPreview
    let remark: String?
    let isMuted: Bool
    let isPinned: Bool
    let blockRelation: UserBlockRelation
    let isBusy: Bool
    let onToggleMute: (Bool) -> Void
    let onTogglePin: (Bool) -> Void
    let onSaveRemark: (String?) -> Void
    let onReport: () -> Void
    let onClearHistory: () -> Void
    let onToggleBlock: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var localMuted: Bool
    @State private var localPinned: Bool
    @State private var localRemark: String?
    @State private var remarkDraft: String
    @State private var showRemarkEditor = false
    @State private var showFeatureHint = false
    @State private var showCreateGroupSheet = false
    @State private var showChatHistoryPage = false
    @State private var showTradeRecordsPage = false
    @State private var quickActionErrorMessage: String?

    init(
        conversation: ChatConversationPreview,
        remark: String?,
        isMuted: Bool,
        isPinned: Bool,
        blockRelation: UserBlockRelation,
        isBusy: Bool,
        onToggleMute: @escaping (Bool) -> Void,
        onTogglePin: @escaping (Bool) -> Void,
        onSaveRemark: @escaping (String?) -> Void,
        onReport: @escaping () -> Void,
        onClearHistory: @escaping () -> Void,
        onToggleBlock: @escaping () -> Void
    ) {
        self.conversation = conversation
        self.remark = remark
        self.isMuted = isMuted
        self.isPinned = isPinned
        self.blockRelation = blockRelation
        self.isBusy = isBusy
        self.onToggleMute = onToggleMute
        self.onTogglePin = onTogglePin
        self.onSaveRemark = onSaveRemark
        self.onReport = onReport
        self.onClearHistory = onClearHistory
        self.onToggleBlock = onToggleBlock
        _localMuted = State(initialValue: isMuted)
        _localPinned = State(initialValue: isPinned)
        _localRemark = State(initialValue: remark)
        _remarkDraft = State(initialValue: remark ?? "")
    }

    private var displayName: String {
        if let remark = localRemark?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remark.isEmpty {
            return remark
        }
        return conversation.displayName
    }

    private var remarkSummaryText: String {
        if let remark = localRemark?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remark.isEmpty {
            return remark
        }
        return "添加备注"
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                NavigationLink {
                    UserPostsView(userId: conversation.otherUserId)
                } label: {
                    VStack(spacing: 12) {
                        Group {
                            if let avatar = conversation.otherUserAvatar,
                               let url = URL(string: avatar),
                               !avatar.isEmpty {
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    avatarFallback
                                }
                            } else {
                                avatarFallback
                            }
                        }
                        .frame(width: 88, height: 88)
                        .clipShape(Circle())

                        Text(displayName)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(AppColors.textPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack(spacing: 12) {
                    quickActionButton(icon: "person.2.badge.plus", title: "建立群组") {
                        quickActionErrorMessage = nil
                        showCreateGroupSheet = true
                    }
                    quickActionButton(icon: "doc.text.magnifyingglass", title: "交易记录") {
                        showTradeRecordsPage = true
                    }
                    quickActionButton(icon: "magnifyingglass", title: "聊天记录") {
                        showChatHistoryPage = true
                    }
                    quickActionButton(icon: "ellipsis", title: "更多") {
                        showFeatureHint = true
                    }
                }

                if let quickActionErrorMessage, !quickActionErrorMessage.isEmpty {
                    Text(quickActionErrorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(
                            quickActionErrorMessage.contains("已创建")
                            ? Color.green.opacity(0.85)
                            : Color.red.opacity(0.88)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }

                VStack(spacing: 0) {
                    settingsValueButton(
                        title: "备注",
                        systemImage: "square.and.pencil",
                        value: remarkSummaryText
                    ) {
                        remarkDraft = localRemark ?? ""
                        showRemarkEditor = true
                    }

                    Divider().padding(.leading, 16)

                    settingsToggleRow(
                        title: "消息免打扰",
                        systemImage: "bell.slash",
                        isOn: Binding(
                            get: { localMuted },
                            set: { newValue in
                                localMuted = newValue
                                onToggleMute(newValue)
                            }
                        )
                    )

                    Divider().padding(.leading, 16)

                    settingsToggleRow(
                        title: "置顶聊天",
                        systemImage: "pin.fill",
                        isOn: Binding(
                            get: { localPinned },
                            set: { newValue in
                                localPinned = newValue
                                onTogglePin(newValue)
                            }
                        )
                    )

                    Divider().padding(.leading, 16)

                    settingsButton(
                        title: "举报",
                        systemImage: "exclamationmark.bubble",
                        role: nil,
                        action: onReport
                    )

                    Divider().padding(.leading, 16)

                    settingsButton(
                        title: "清空聊天记录",
                        systemImage: "trash",
                        role: .destructive,
                        action: onClearHistory
                    )

                    Divider().padding(.leading, 16)

                    settingsButton(
                        title: blockRelation.isBlockedByMe ? "解除拉黑" : "拉黑/封锁",
                        systemImage: "hand.raised.fill",
                        role: .destructive,
                        action: onToggleBlock
                    )
                    .disabled(isBusy || (!blockRelation.isBlockedByMe && blockRelation.isBlockedByOther))
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .cheeseCardChrome(cornerRadius: 18)

                if blockRelation.isBlockedByOther && !blockRelation.isBlockedByMe {
                    Text("你已被对方拉黑。当前只能查看历史聊天，无法访问对方主页或发送消息。")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.red.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }

                Spacer(minLength: 30)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .background(AppColors.pageBackground.ignoresSafeArea())
        .cheesePageTopBar(title: "聊天详情")
        .sheet(isPresented: $showCreateGroupSheet) {
            ChatRoomCreateGroupSheet(baseConversation: conversation) { group in
                _ = group
                quickActionErrorMessage = "群组已创建，可在消息页的群聊列表查看。"
            }
        }
        .sheet(isPresented: $showRemarkEditor) {
            NavigationStack {
                ZStack {
                    AppColors.pageBackground
                        .ignoresSafeArea()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("备注名")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppColors.textMuted)

                        TextField("输入备注", text: $remarkDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .cheeseInputChrome(cornerRadius: 12)

                        Text("留空则不设置备注。")
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.textMuted)
                    }
                    .padding(16)
                }
                .navigationTitle("设置备注")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(AppColors.pageBackground, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") {
                            showRemarkEditor = false
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            let normalized = remarkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            let nextValue = normalized.isEmpty ? nil : normalized
                            localRemark = nextValue
                            onSaveRemark(nextValue)
                            showRemarkEditor = false
                        }
                        .fontWeight(.semibold)
                    }
                }
                .tint(AppColors.textPrimary)
            }
        }
        .navigationDestination(isPresented: $showChatHistoryPage) {
            ChatRoomHistoryView(conversation: conversation)
        }
        .navigationDestination(isPresented: $showTradeRecordsPage) {
            ChatRoomTradeRecordsPlaceholderView(conversation: conversation)
        }
        .alert("即将上线", isPresented: $showFeatureHint) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("更多功能暂未开放，后续补齐。")
        }
    }

    private var avatarFallback: some View {
        Circle()
            .fill(Color.gray.opacity(0.15))
            .overlay {
                Text(String(displayName.prefix(1)).uppercased())
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.gray)
            }
    }

    private func quickActionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: 8) {
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                    }
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textMuted)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private func settingsValueButton(
        title: String,
        systemImage: String,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Text(value)
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.textMuted)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted.opacity(0.65))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private func settingsButton(
        title: String,
        systemImage: String,
        role: ButtonRole?,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role) {
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(role == .destructive ? Color.red : AppColors.textPrimary)
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(role == .destructive ? Color.red : AppColors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted.opacity(0.65))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingsToggleRow(
        title: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)

            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AppColors.textPrimary)

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(AppColors.textPrimary)
                .disabled(isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }
}
