//
//  ChatListView.swift
//  CheeseApp
//
//  💬 聊天列表视图（主消息 + 陌生人消息 + 群聊）
//

import SwiftUI

struct ChatListView: View {
    @EnvironmentObject private var notificationRouter: AppNotificationRouter
    @EnvironmentObject private var postDeepLinkCoordinator: PostDeepLinkCoordinator
    @StateObject private var chatService = ChatService.shared
    @StateObject private var systemMessageService = SystemMessageService.shared

    @State private var searchText = ""
    @State private var activeSheetDestination: ChatInboxSheetDestination?
    @State private var activeRoute: ChatInboxRoute?
    @State private var rowActionErrorMessage: String?
    @State private var activeSwipeConversationId: UUID?
    @State private var isSwipeHorizontallyDragging = false
    @State private var isSearchFieldFocused = false

    private var conversationDisplayNamesById: [UUID: String] {
        let previews = chatService.messageRequests + chatService.conversations
        return previews.reduce(into: [UUID: String]()) { partialResult, preview in
            partialResult[preview.id] = chatService.displayName(for: preview)
        }
    }

    private var inboxState: ChatInboxPresentationState {
        ChatInboxPresentationState(
            searchText: searchText,
            messageRequests: chatService.messageRequests,
            directConversations: chatService.conversations,
            groupConversations: chatService.groupConversations,
            displayNamesByConversationId: conversationDisplayNamesById
        )
    }

    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()

            switch chatService.conversationListState {
            case .unresolved, .initialLoading:
                loadingState
            case .empty:
                emptyState
            case .error(let message):
                errorState(message)
            case .loaded:
                conversationListContent
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $activeRoute) { route in
            destinationView(route)
        }
        .task(id: chatService.accountGeneration) {
            guard chatService.isAccountScopeReady else { return }
            if !chatService.hasResolvedInitialConversationLoad {
                await chatService.refreshConversations()
            }
            await systemMessageService.refreshUnreadCount()
            await handlePendingNotificationNavigationIfNeeded()
        }
        .refreshable {
            await chatService.refreshConversations()
            await systemMessageService.refreshUnreadCount()
            await handlePendingNotificationNavigationIfNeeded()
        }
        .onAppear {
            CheeseTabBarVisibilityController.shared.resetVisibility()
            Task {
                await handlePendingNotificationNavigationIfNeeded()
            }
        }
        .onChange(of: notificationRouter.pendingActionID) { _, _ in
            Task {
                await handlePendingNotificationNavigationIfNeeded()
            }
        }
        .onChange(of: chatService.accountGeneration) { _, _ in
            resetForAccountBoundary()
        }
        .sheet(item: $activeSheetDestination) { destination in
            switch destination {
            case .createGroup:
                CreateChatGroupSheet { group in
                    activeRoute = .group(currentGroupRoute(group))
                }
            case .addFollow:
                ChatFollowSearchSheet()
            }
        }
        .safeAreaInset(edge: .top) {
            inboxTopInset
        }
    }

    private var inboxTopInset: some View {
        VStack(spacing: 10) {
            CheeseInlineTopBar {
                EmptyView()
            } center: {
                Text("消息")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
            } trailing: {
                Menu {
                    Button {
                        activeSheetDestination = .createGroup
                    } label: {
                        Label("创建群聊", systemImage: "person.3.fill")
                    }

                    Button {
                        activeSheetDestination = .addFollow
                    } label: {
                        Label("新增关注", systemImage: "person.badge.plus")
                    }

                    Divider()

                    Button {
                        Task { await chatService.refreshConversations() }
                    } label: {
                        Label("刷新消息", systemImage: "arrow.clockwise")
                    }
                } label: {
                    PostToolbarIconCircle(icon: "plus")
                }
            }

            ChatInboxSearchField(
                placeholder: "搜索聊天、群聊、消息内容",
                text: $searchText,
                focus: $isSearchFieldFocused
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(AppColors.pageBackground)
    }

    @MainActor
    private func handlePendingNotificationNavigationIfNeeded() async {
        guard chatService.isAccountScopeReady else { return }
        guard let action = notificationRouter.pendingAction else { return }

        switch action.target {
        case .conversation(let conversationID):
            do {
                let preview: ChatConversationPreview
                if let existing =
                    chatService.messageRequests.first(where: { $0.id == conversationID })
                    ?? chatService.conversations.first(where: { $0.id == conversationID }) {
                    preview = existing
                } else {
                    preview = try await chatService.fetchConversationPreview(
                        conversationId: conversationID
                    )
                }
                activeRoute = .conversation(currentConversationRoute(preview))
                notificationRouter.consume(action)
            } catch {
                rowActionErrorMessage = error.localizedDescription
            }

        case .group(let groupID):
            do {
                let preview: ChatGroupPreview
                if let existing = chatService.groupConversations.first(where: { $0.id == groupID }) {
                    preview = existing
                } else {
                    preview = try await chatService.fetchGroupPreview(groupId: groupID)
                }
                activeRoute = .group(currentGroupRoute(preview))
                notificationRouter.consume(action)
            } catch {
                rowActionErrorMessage = error.localizedDescription
            }

        case .systemMessages(_, let category):
            activeRoute = .systemMessages(category ?? .system)
            notificationRouter.consume(action)

        case .post:
            break
        }
    }

    private var conversationListContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                if !inboxState.isSearching {
                    inboxCategoryEntries
                        .padding(.horizontal, 16)
                }

                if inboxState.isSearching {
                    HStack {
                        Text(
                            inboxState.showsSearchEmptyState
                            ? "没有找到和“\(inboxState.trimmedSearchText)”相关的消息"
                            : "找到 \(inboxState.visibleItemCount) 条相关结果"
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColors.textMuted)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                }

                if inboxState.showsSearchEmptyState {
                    searchEmptyState
                        .padding(.horizontal, 16)
                } else {
                    ForEach(inboxState.visibleSections) { section in
                        listSectionCard(title: section.title) {
                            sectionRows(for: section)
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if let error = chatService.conversationErrorMessage {
                    errorBanner(error)
                        .padding(.horizontal, 16)
                }

                if let rowActionErrorMessage, !rowActionErrorMessage.isEmpty {
                    errorBanner(rowActionErrorMessage)
                        .padding(.horizontal, 16)
                }

                Spacer(minLength: 120)
            }
            .padding(.top, 10)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollDisabled(isSwipeHorizontallyDragging)
        .overlay {
            if isSearchFieldFocused {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissSearchKeyboard()
                    }
            }
        }
    }

    private var emptyState: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                inboxCategoryEntries

                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 52))
                    .foregroundStyle(.secondary.opacity(0.5))

                Text("还没有聊天")
                    .font(.system(size: 20, weight: .semibold))

                Text("可从贴文或主页发起私信，也可以用右上角创建群聊或新增关注。")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private var inboxCategoryEntries: some View {
        VStack(spacing: 0) {
            systemCategoryEntry(.system)

            Divider()
                .padding(.leading, 76)

            systemCategoryEntry(.interaction)

            Divider()
                .padding(.leading, 76)

            inboxCategoryEntry(
                title: "陌生人消息",
                preview: strangerMessagePreview,
                icon: "bubble.left.fill",
                tint: Color(red: 1.0, green: 0.36, blue: 0.39),
                date: latestMessageRequest?.lastMessageAt,
                unreadCount: strangerMessageBadgeCount
            ) {
                activeRoute = .messageRequests
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .cheeseCardChrome(cornerRadius: 20)
    }

    private func systemCategoryEntry(_ category: SystemMessageCategory) -> some View {
        let summary = systemMessageService.inboxSummaries[category]
        return inboxCategoryEntry(
            title: category.title,
            preview: summary?.latestBody ?? category.fallbackPreview,
            icon: category == .system ? "bell.fill" : "bolt.fill",
            tint: category == .system ? Color.blue : AppColors.likeActive,
            date: summary?.latestCreatedAt,
            unreadCount: summary?.unreadCount ?? 0
        ) {
            activeRoute = .systemMessages(category)
        }
    }

    private func inboxCategoryEntry(
        title: String,
        preview: String,
        icon: String,
        tint: Color,
        date: Date?,
        unreadCount: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Circle()
                    .fill(tint)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)

                    Text(preview)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 7) {
                    if let date {
                        Text(Formatters.formatCompactTimeAgo(date, useJustNow: true))
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.textMuted.opacity(0.85))
                            .lineLimit(1)
                    }

                    if unreadCount > 0 {
                        Text("\(min(unreadCount, 99))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Color.red)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var latestMessageRequest: ChatConversationPreview? {
        chatService.messageRequests.max { $0.lastMessageAt < $1.lastMessageAt }
    }

    private var strangerMessageBadgeCount: Int {
        let unread = chatService.messageRequests.reduce(0) { partial, conversation in
            partial + max(conversation.unreadCount, 0)
        }
        return unread > 0 ? unread : chatService.messageRequests.count
    }

    private var strangerMessagePreview: String {
        guard let latestMessageRequest else { return "暂无陌生人消息" }
        let name = chatService.displayName(for: latestMessageRequest)
        let message = latestMessageRequest.lastMessagePreview?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let message, !message.isEmpty else {
            return "\(name) 发来陌生人消息"
        }
        return "\(name)：\(message)"
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在加载对话...")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }

    private func errorState(_ message: String) -> some View {
        ErrorView(message) {
            Task { await chatService.refreshConversations() }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        InlineErrorBanner(text: text)
            .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(AppColors.textMuted)

            Text("没有匹配的聊天")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)

            Text("试试搜索备注、昵称、群名称或最近一条消息。")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 18)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .cheeseCardChrome(cornerRadius: 18)
    }

    @ViewBuilder
    private func sectionRows(for section: ChatInboxSection) -> some View {
        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
            sectionRow(item)

            if index != section.items.count - 1 {
                Divider()
                    .padding(.leading, 84)
            }
        }
    }

    @ViewBuilder
    private func sectionRow(_ item: ChatInboxSectionItem) -> some View {
        switch item {
        case .group(let group):
            Button {
                openGroup(group)
            } label: {
                GroupChatRow(group: group)
            }
            .buttonStyle(.plain)

        case .direct(let conversation), .messageRequest(let conversation):
            ConversationSwipeActionRow(
                conversation: conversation,
                activeSwipeConversationId: $activeSwipeConversationId,
                isAnyRowHorizontallyDragging: $isSwipeHorizontallyDragging,
                rowActionErrorMessage: $rowActionErrorMessage,
                onOpenConversation: {
                    openConversation(conversation)
                },
                onOpenProfile: {
                    openProfile(conversation.otherUserId)
                }
            )
        }
    }

    private func listSectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColors.textMuted)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .cheeseCardChrome(cornerRadius: 20)
        }
    }

    @ViewBuilder
    private func destinationView(_ route: ChatInboxRoute) -> some View {
        switch route {
        case .systemMessages(let category):
            SystemMessageTimelineView(
                category: category,
                onOpenPost: { route in
                    postDeepLinkCoordinator.openRoute(
                        route,
                        canPresentProtectedContent: true
                    )
                },
                onOpenProfile: { userID in
                    activeRoute = .profile(userID)
                }
            )
        case .messageRequests:
            MessageRequestsView()
        case .group(let group):
            GroupChatRoomView(group: currentGroupRoute(group))
        case .conversation(let conversation):
            ChatRoomView(conversation: currentConversationRoute(conversation))
        case .profile(let userID):
            UserPostsView(userId: userID)
        }
    }
}

private extension ChatListView {
    func resetForAccountBoundary() {
        searchText = ""
        activeSheetDestination = nil
        activeRoute = nil
        rowActionErrorMessage = nil
        activeSwipeConversationId = nil
        isSwipeHorizontallyDragging = false
        isSearchFieldFocused = false
    }

    func dismissSearchKeyboard() {
        isSearchFieldFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func openConversation(_ conversation: ChatConversationPreview) {
        if isSearchFieldFocused {
            dismissSearchKeyboard()
            return
        }
        activeRoute = .conversation(currentConversationRoute(conversation))
    }

    func openGroup(_ group: ChatGroupPreview) {
        if isSearchFieldFocused {
            dismissSearchKeyboard()
            return
        }
        activeRoute = .group(currentGroupRoute(group))
    }

    func openProfile(_ userId: UUID) {
        if isSearchFieldFocused {
            dismissSearchKeyboard()
            return
        }
        activeRoute = .profile(userId)
    }

    func currentConversationRoute(_ fallback: ChatConversationPreview) -> ChatConversationPreview {
        chatService.conversations.first(where: { $0.id == fallback.id })
        ?? chatService.messageRequests.first(where: { $0.id == fallback.id })
        ?? fallback
    }

    func currentGroupRoute(_ fallback: ChatGroupPreview) -> ChatGroupPreview {
        chatService.groupConversations.first(where: { $0.id == fallback.id }) ?? fallback
    }
}

#Preview {
    NavigationStack {
        ChatListView()
    }
}
