import SwiftUI
import Foundation
import UIKit

enum ChatInboxSheetDestination: String, Identifiable {
    case createGroup
    case addFollow

    var id: String { rawValue }
}
struct ChatInboxSearchField: View {
    let placeholder: String
    @Binding var text: String
    var focus: Binding<Bool>?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppColors.textMuted)

            inputField

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(AppColors.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .cheeseInputChrome(cornerRadius: 14)
    }

    @ViewBuilder
    private var inputField: some View {
        CheeseSearchTextField(
            text: $text,
            placeholder: placeholder,
            fontSize: 14,
            isFirstResponder: focus
        )
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 22)
    }
}

/// Non-editable search entry shown in the inbox. Tapping it opens the
/// dedicated search page so the chat list never competes with the keyboard.
struct ChatInboxSearchEntry: View {
    let placeholder: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted)

                Text(placeholder)
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .cheeseInputChrome(cornerRadius: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(placeholder)
    }
}

private enum ChatInboxSearchHistory {
    private static let key = "chat.inbox.recent.searches"

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return load() }

        var values = load().filter {
            $0.caseInsensitiveCompare(trimmed) != .orderedSame
        }
        values.insert(trimmed, at: 0)
        values = Array(values.prefix(8))
        UserDefaults.standard.set(values, forKey: key)
        return values
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

struct ChatInboxSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var chatService: ChatService

    let onOpenConversation: (ChatConversationPreview) -> Void
    let onOpenGroup: (ChatGroupPreview) -> Void
    let onOpenMessage: (ChatMessageSearchResult) -> Void
    let onDismiss: (() -> Void)?

    @State private var queryText = ""
    @State private var isSearchFieldFocused = false
    @State private var recentSearches = ChatInboxSearchHistory.load()
    @State private var messageResults: [ChatMessageSearchResult] = []
    @State private var isLoadingMessageResults = false
    @State private var messageSearchError: String?
    @State private var edgeSwipeDismissOffset: CGFloat = 0
    @State private var didDismissKeyboardForEdgeSwipe = false

    init(
        chatService: ChatService,
        onOpenConversation: @escaping (ChatConversationPreview) -> Void,
        onOpenGroup: @escaping (ChatGroupPreview) -> Void,
        onOpenMessage: @escaping (ChatMessageSearchResult) -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.chatService = chatService
        self.onOpenConversation = onOpenConversation
        self.onOpenGroup = onOpenGroup
        self.onOpenMessage = onOpenMessage
        self.onDismiss = onDismiss
    }

    private var normalizedQuery: String {
        queryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var presentationState: ChatInboxPresentationState {
        ChatInboxPresentationState(
            searchText: queryText,
            directConversations: chatService.conversations,
            groupConversations: chatService.groupConversations,
            displayNamesByConversationId: chatService.conversations.reduce(into: [UUID: String]()) {
                $0[$1.id] = chatService.displayName(for: $1)
            }
        )
    }

    private var results: [ChatInboxSectionItem] {
        presentationState.visibleSections.flatMap { $0.items }
    }

    private var conversationByID: [UUID: ChatConversationPreview] {
        Dictionary(uniqueKeysWithValues: chatService.conversations.map { ($0.id, $0) })
    }

    private var groupByID: [UUID: ChatGroupPreview] {
        Dictionary(uniqueKeysWithValues: chatService.groupConversations.map { ($0.id, $0) })
    }

    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                searchHeader

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        if normalizedQuery.isEmpty {
                            recentSearchesView
                        } else if isLoadingMessageResults && messageResults.isEmpty {
                            searchLoadingView
                        } else if results.isEmpty && messageResults.isEmpty {
                            emptySearchView
                        } else {
                            resultsView
                        }

                        Spacer(minLength: 120)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .cheeseTabBarHidden(true)
        .enableSwipeBackGesture()
        .dismissKeyboardOnTap()
        .onAppear {
            // Search is inserted as an immediate overlay, so there is no page
            // transition to coordinate with. UIKit will animate only the
            // keyboard after the field is attached to the window.
            isSearchFieldFocused = true
            edgeSwipeDismissOffset = 0
            didDismissKeyboardForEdgeSwipe = false
        }
        .offset(x: edgeSwipeDismissOffset)
        .simultaneousGesture(edgeSwipeDismissGesture)
        .task(id: normalizedQuery) {
            await loadMessageResults(for: normalizedQuery)
        }
        .onDisappear {
            dismissSearchKeyboard()
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Button {
                closeSearchPage()
            } label: {
                PostToolbarIconCircle(icon: "chevron.left")
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted)

                CheeseSearchTextField(
                    text: $queryText,
                    placeholder: "搜索聊天、群聊、消息内容",
                    fontSize: 15,
                    isFirstResponder: $isSearchFieldFocused,
                    onSubmit: recordCurrentQuery
                )
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 22)

                if !queryText.isEmpty {
                    Button {
                        queryText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(AppColors.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .cheeseInputChrome(cornerRadius: 14)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(AppColors.pageBackground)
    }

    private var edgeSwipeDismissGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard value.startLocation.x <= 32,
                      value.translation.width >= 0,
                      abs(value.translation.width) >= abs(value.translation.height)
                else { return }

                // Follow the finger during the edge swipe so the inbox is
                // revealed underneath, matching the native pop transition.
                edgeSwipeDismissOffset = value.translation.width

                // Dismiss as soon as the gesture becomes a horizontal edge
                // swipe. Waiting for the completion threshold makes the
                // keyboard visibly lag behind the page.
                if !didDismissKeyboardForEdgeSwipe {
                    didDismissKeyboardForEdgeSwipe = true
                    isSearchFieldFocused = false
                    dismissSearchKeyboard()
                }
            }
            .onEnded { value in
                let startedAtLeadingEdge = value.startLocation.x <= 32
                let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                let reachedDismissDistance = value.translation.width >= 56
                let projectedToDismiss = value.predictedEndTranslation.width >= 96

                guard startedAtLeadingEdge,
                      isHorizontal,
                      reachedDismissDistance || projectedToDismiss
                else {
                    withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.86)) {
                        edgeSwipeDismissOffset = 0
                    }
                    didDismissKeyboardForEdgeSwipe = false
                    return
                }

                let finalOffset = max(
                    UIScreen.main.bounds.width,
                    edgeSwipeDismissOffset
                )
                withAnimation(.easeOut(duration: 0.18)) {
                    edgeSwipeDismissOffset = finalOffset
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    closeSearchPage()
                }
            }
    }

    private func closeSearchPage() {
        isSearchFieldFocused = false
        dismissSearchKeyboard()
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private var recentSearchesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近搜索")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)

                Spacer()

                if !recentSearches.isEmpty {
                    Button {
                        recentSearches = []
                        ChatInboxSearchHistory.clear()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(AppColors.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除最近搜索")
                }
            }

            if recentSearches.isEmpty {
                Text("搜索聊天、群聊或消息内容")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textMuted)
                    .padding(.top, 8)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(recentSearches, id: \.self) { query in
                        Button {
                            queryText = query
                            isSearchFieldFocused = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "clock")
                                    .font(.system(size: 14))
                                    .foregroundStyle(AppColors.textMuted)
                                Text(query)
                                    .font(.system(size: 14))
                                    .foregroundStyle(AppColors.textPrimary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptySearchView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(AppColors.textMuted)
            Text("没有找到匹配的聊天")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
            Text("试试搜索备注名、昵称、群名称或历史消息内容。")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var searchLoadingView: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("正在搜索历史消息…")
                .font(.system(size: 14))
                .foregroundStyle(AppColors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !results.isEmpty {
                Text("聊天")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppColors.textMuted)

                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        searchResultRow(item)
                        if index < results.count - 1 {
                            Divider()
                                .padding(.leading, 84)
                        }
                    }
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .cheeseCardChrome(cornerRadius: 16)
            }

            if !messageResults.isEmpty {
                Text("消息")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppColors.textMuted)
                    .padding(.top, results.isEmpty ? 0 : 8)

                VStack(spacing: 0) {
                    ForEach(Array(messageResults.enumerated()), id: \.element.id) { index, result in
                        messageSearchResultRow(result)
                        if index < messageResults.count - 1 {
                            Divider()
                                .padding(.leading, 84)
                        }
                    }
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .cheeseCardChrome(cornerRadius: 16)
            }

            if let messageSearchError {
                Text(messageSearchError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func searchResultRow(_ item: ChatInboxSectionItem) -> some View {
        switch item {
        case .direct(let conversation):
            ChatRow(conversation: conversation, onAvatarTap: nil)
                .contentShape(Rectangle())
                .onTapGesture {
                    recordCurrentQuery()
                    onOpenConversation(conversation)
                }
        case .group(let group):
            GroupChatRow(group: group)
                .contentShape(Rectangle())
                .onTapGesture {
                    recordCurrentQuery()
                    onOpenGroup(group)
                }
        }
    }

    @ViewBuilder
    private func messageSearchResultRow(_ result: ChatMessageSearchResult) -> some View {
        if let conversationID = result.conversationID,
           let conversation = conversationByID[conversationID] {
            ChatInboxMessageSearchRow(
                title: chatService.displayName(for: conversation),
                subtitle: result.content,
                date: result.createdAt,
                avatarURL: conversation.otherUserAvatar,
                fallbackLetter: chatService.displayName(for: conversation).prefix(1).uppercased()
            )
            .contentShape(Rectangle())
            .onTapGesture {
                recordCurrentQuery()
                onOpenMessage(result)
            }
        } else if let groupID = result.groupID,
                  let group = groupByID[groupID] {
            ChatInboxMessageSearchRow(
                title: group.displayName,
                subtitle: result.content,
                date: result.createdAt,
                avatarURL: group.avatarURL,
                fallbackLetter: group.displayName.prefix(1).uppercased()
            )
            .contentShape(Rectangle())
            .onTapGesture {
                recordCurrentQuery()
                onOpenMessage(result)
            }
        }
    }

    private func recordCurrentQuery() {
        guard !normalizedQuery.isEmpty else { return }
        recentSearches = ChatInboxSearchHistory.record(normalizedQuery)
    }

    private func loadMessageResults(for query: String) async {
        guard !query.isEmpty else {
            messageResults = []
            messageSearchError = nil
            isLoadingMessageResults = false
            return
        }

        isLoadingMessageResults = true
        messageSearchError = nil
        messageResults = []

        do {
            try await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let fetched = try await chatService.searchMessages(query: query)
            guard !Task.isCancelled, query == normalizedQuery else { return }
            messageResults = fetched
            isLoadingMessageResults = false
        } catch is CancellationError {
            return
        } catch {
            guard query == normalizedQuery else { return }
            messageResults = []
            messageSearchError = AppErrorMessage.userMessage(for: error)
            isLoadingMessageResults = false
        }
    }

    private func dismissSearchKeyboard() {
        isSearchFieldFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

struct InlineErrorBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer()
        }
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .cheeseCardChrome(cornerRadius: 12)
    }
}

private struct ChatInboxMessageSearchRow: View {
    let title: String
    let subtitle: String
    let date: Date
    let avatarURL: String?
    let fallbackLetter: String

    var body: some View {
        HStack(spacing: 14) {
            avatarView

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(ChatListTimeFormatter.string(from: date))
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.textMuted)
                }

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textMuted)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white)
    }

    private var avatarView: some View {
        Group {
            if let avatarURL,
               !avatarURL.isEmpty,
               let url = URL(string: avatarURL) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        fallbackView
                    }
                }
            } else {
                fallbackView
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(Circle())
    }

    private var fallbackView: some View {
        Circle()
            .fill(Color.gray.opacity(0.15))
            .overlay {
                Text(fallbackLetter)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.gray)
            }
    }
}

struct ConversationSwipeActionRow: View {
    let conversation: ChatConversationPreview
    @Binding var activeSwipeConversationId: UUID?
    let onOpenConversation: () -> Void
    let onOpenProfile: () -> Void
    let onDelete: () -> Void

    var body: some View {
        SwipeableDeleteNavigationRow(
            rowID: conversation.id,
            activeSwipeConversationId: $activeSwipeConversationId,
            onOpenConversation: onOpenConversation,
            onDelete: onDelete
        ) {
            ChatRow(conversation: conversation, onAvatarTap: onOpenProfile)
        }
    }
}

struct GroupConversationSwipeActionRow: View {
    let group: ChatGroupPreview
    @Binding var activeSwipeConversationId: UUID?
    let onOpenConversation: () -> Void
    let onDelete: () -> Void

    var body: some View {
        SwipeableDeleteNavigationRow(
            rowID: group.id,
            activeSwipeConversationId: $activeSwipeConversationId,
            onOpenConversation: onOpenConversation,
            onDelete: onDelete
        ) {
            GroupChatRow(group: group)
        }
    }
}
