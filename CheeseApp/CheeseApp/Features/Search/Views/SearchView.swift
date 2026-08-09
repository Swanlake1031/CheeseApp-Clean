//
//  SearchView.swift
//  CheeseApp
//
//  🔍 搜索页面
//  聚合搜索二手与论坛真实数据
//

import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @Binding private var shouldAutoFocus: Bool
    private let showsBackButton: Bool
    @StateObject private var viewModel = SearchViewModel()
    @StateObject private var chatService = ChatService.shared
    @State private var searchText = ""
    @State private var isSearchFieldFocused = false
    @State private var selectedCategory: SearchCategory = .all
    @State private var selectedHotCategory: SearchCategory = .all
    @State private var destination: SearchNavigationDestination?
    @State private var selectedResolvedResult: SearchResolvedDestination?
    @State private var selectedProfile: SearchProfileResult?
    @State private var activeConversation: ChatConversationPreview?
    @State private var profileActionError: String?
    @State private var isOpeningResult = false
    @State private var resultOpenErrorMessage: String?
    @State private var isSearchPageVisible = false

    init(
        shouldAutoFocus: Binding<Bool> = .constant(false),
        showsBackButton: Bool = false
    ) {
        self._shouldAutoFocus = shouldAutoFocus
        self.showsBackButton = showsBackButton
    }

    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    searchBar

                    VStack(spacing: 20) {
                        categoryFilter

                        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            recentSearchesSection
                            hotByTypeSection
                        } else {
                            searchResults
                        }

                        Spacer(minLength: 100)
                    }
                    .frame(maxWidth: .infinity)
                    .prioritizeKeyboardDismissal(
                        while: isSearchFieldFocused,
                        onDismiss: dismissSearchKeyboard
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .cheeseLoadingOverlay(
            isPresented: isOpeningResult,
            message: L10n.tr("Opening post...", "正在打开贴文...")
        )
        .navigationBarBackButtonHidden(showsBackButton)
        .navigationDestination(item: $destination) { target in
            destinationView(for: target)
        }
        .navigationDestination(item: $selectedResolvedResult) { destination in
            resolvedDestinationView(for: destination)
        }
        .navigationDestination(item: $selectedProfile) { profile in
            UserPostsView(userId: profile.id)
        }
        .navigationDestination(item: $activeConversation) { conversation in
            ChatRoomView(conversation: conversation)
        }
        .task(id: authService.currentUser?.id) {
            viewModel.activateAccount(authService.currentUser?.id)
            await viewModel.loadInitialData()
            viewModel.updateSearch(text: searchText, category: selectedCategory)
        }
        .onReceive(NotificationCenter.default.publisher(for: PostFeatureEvents.postsDidChange)) { _ in
            Task {
                await viewModel.loadInitialData()
                await MainActor.run {
                    viewModel.updateSearch(text: searchText, category: selectedCategory)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProfileSocialEvents.followingDidChange)) { notification in
            guard let (targetUserID, isFollowing) = ProfileSocialEvents.change(
                from: notification
            ) else { return }
            viewModel.applyFollowChange(
                targetUserID: targetUserID,
                isFollowing: isFollowing
            )
        }
        .onAppear {
            isSearchPageVisible = true
            if !showsBackButton {
                CheeseTabBarVisibilityController.shared.resetVisibility()
            }
        }
        .task(id: shouldAutoFocus) {
            await focusSearchFieldIfRequested()
        }
        .onChange(of: searchText) { _, newValue in
            viewModel.updateSearch(text: newValue, category: selectedCategory)
        }
        .onChange(of: selectedCategory) { _, newValue in
            viewModel.updateSearch(text: searchText, category: newValue)
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { profileActionError != nil },
                set: { if !$0 { profileActionError = nil } }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(profileActionError ?? "")
        }
        .alert(
            L10n.tr("Unable to open post", "打开贴文失败"),
            isPresented: Binding(
                get: { resultOpenErrorMessage != nil },
                set: { if !$0 { resultOpenErrorMessage = nil } }
            )
        ) {
            Button(L10n.tr("OK", "确定"), role: .cancel) {}
        } message: {
            Text(resultOpenErrorMessage ?? "")
        }
        .onDisappear {
            isSearchPageVisible = false
            shouldAutoFocus = false
            dismissSearchKeyboard()
        }
        .cheeseTabBarHidden(showsBackButton)
    }

    // MARK: - 搜索框
    private var searchBar: some View {
        HStack(spacing: 12) {
            if showsBackButton {
                Button {
                    dismissSearchKeyboard()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回首页")
            }

            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)

            CheeseSearchTextField(
                text: $searchText,
                placeholder: L10n.tr(
                    "Search posts, people, or UID...",
                    "搜索帖子、用户或 UID..."
                ),
                fontSize: 16,
                isFirstResponder: $isSearchFieldFocused,
                onSubmit: {
                    guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    viewModel.addRecentSearch(searchText)
                    isSearchFieldFocused = false
                }
            )
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 24)

            if !searchText.isEmpty {
                Button(action: {
                    searchText = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .cheeseCardChrome(cornerRadius: 16)
    }

    @MainActor
    private func focusSearchFieldIfRequested() async {
        guard shouldAutoFocus else { return }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled,
              shouldAutoFocus,
              isSearchPageVisible
        else { return }
        isSearchFieldFocused = true
        shouldAutoFocus = false
    }

    // MARK: - 分类筛选
    private var categoryFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(SearchCategory.allCases, id: \.self) { category in
                    SearchCategoryPill(
                        category: category,
                        isSelected: selectedCategory == category
                    ) {
                        withAnimation(.spring(response: 0.3)) {
                            selectedCategory = category
                        }
                    }
                }
            }
        }
    }

    // MARK: - 最近搜索
    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.tr("Recent", "最近搜寻"))
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                if !viewModel.recentSearches.isEmpty {
                    Button(L10n.tr("Clear", "清除")) {
                        viewModel.clearRecentSearches()
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }

            if viewModel.recentSearches.isEmpty {
                Text(L10n.tr("Your recent searches will appear here", "你的最近搜寻会显示在这里"))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                FlowLayout(spacing: 10) {
                    ForEach(viewModel.recentSearches, id: \.self) { query in
                        Button(action: {
                            searchText = query
                            viewModel.updateSearch(text: query, category: selectedCategory)
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 12))
                                Text(query)
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(AppColors.cardBackground)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 热门榜（文字榜单 + 分类切换）
    private var hotByTypeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("Hot Ranking", "热门排行榜"))
                .font(.system(size: 18, weight: .semibold))

            hotCategorySwitch

            let rankingItems = viewModel.hotPosts(for: selectedHotCategory)

            switch viewModel.hotRankingLoadState(for: selectedHotCategory) {
            case .unresolved, .initialLoading:
                landingSectionLoadingCard(minHeight: 168)
            case .empty:
                Text(L10n.tr("No trending content yet", "目前没有热门内容"))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            case .loaded:
                VStack(spacing: 0) {
                    ForEach(Array(rankingItems.prefix(10).enumerated()), id: \.element.id) { index, item in
                        Button {
                            handleResultTap(item)
                        } label: {
                            TextHotRankRow(rank: index + 1, item: item)
                        }
                        .buttonStyle(.plain)

                        if index < min(rankingItems.count, 10) - 1 {
                            Divider()
                                .padding(.leading, 42)
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(AppColors.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .cheeseCardChrome(cornerRadius: 16)
            case .error(let message):
                ErrorView(message) {
                    Task { await viewModel.loadInitialData() }
                }
            }
        }
    }

    private var hotCategorySwitch: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchCategory.allCases, id: \.self) { category in
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            selectedHotCategory = category
                        }
                    } label: {
                        Text(category.hotRankingDisplayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selectedHotCategory == category ? .white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(selectedHotCategory == category ? AppColors.selectedBackground : AppColors.cardBackground)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func landingSectionLoadingCard(minHeight: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(AppColors.cardBackground)
            .frame(maxWidth: .infinity)
            .frame(minHeight: minHeight)
            .overlay {
                ProgressView()
                    .progressViewStyle(.circular)
            }
            .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 4)
    }

    // MARK: - 搜索结果
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("Results", "搜寻结果"))
                .font(.system(size: 18, weight: .semibold))

            if viewModel.isSearching && viewModel.filteredResults.isEmpty && viewModel.profileResults.isEmpty {
                ProgressView()
                    .padding(.vertical, 24)
            } else if viewModel.filteredResults.isEmpty && viewModel.profileResults.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("No matching result", "没有符合的结果"))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                if !viewModel.profileResults.isEmpty {
                    if viewModel.isSearching {
                        ProgressView()
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text("用户")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColors.textMuted)
                        .padding(.top, 2)

                    ForEach(viewModel.profileResults) { profile in
                        SearchProfileCard(
                            profile: profile,
                            isCurrentUser: authService.currentUser?.id == profile.id,
                            isFollowBusy: viewModel.isTogglingFollow(profile.id),
                            onOpenProfile: {
                                selectedProfile = profile
                            },
                            onFollowTap: {
                                Task {
                                    do {
                                        try await viewModel.toggleFollow(profile: profile)
                                    } catch {
                                        profileActionError = error.localizedDescription
                                    }
                                }
                            },
                            onMessageTap: {
                                Task {
                                    do {
                                        if authService.currentUser?.id == profile.id {
                                            throw NSError(
                                                domain: "",
                                                code: 400,
                                                userInfo: [NSLocalizedDescriptionKey: "不能给自己发送私信。"]
                                            )
                                        }
                                        let conversation = try await chatService.getOrCreateConversation(
                                            otherUserId: profile.id,
                                            relatedPostId: nil
                                        )
                                        activeConversation = conversation
                                    } catch {
                                        profileActionError = error.localizedDescription
                                    }
                                }
                            }
                        )
                    }
                }

                if !viewModel.filteredResults.isEmpty {
                    Text("帖子")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColors.textMuted)
                        .padding(.top, viewModel.profileResults.isEmpty ? 0 : 4)
                }

                ForEach(viewModel.filteredResults) { result in
                    Button(action: {
                        handleResultTap(result)
                    }) {
                        SearchResultCard(item: result)
                    }
                    .buttonStyle(.plain)
                }

                if viewModel.isLoadingMoreSearchResults {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else if viewModel.hasMoreSearchResults {
                    Button(L10n.tr("Load more", "加载更多")) {
                        Task { await viewModel.loadMoreSearchResults() }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                if let pageError = viewModel.searchPageErrorMessage {
                    Button {
                        Task { await viewModel.retrySearchPage() }
                    } label: {
                        Text("\(pageError) · \(L10n.tr("Retry", "重试"))")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func destinationView(for destination: SearchNavigationDestination) -> some View {
        switch destination {
        case .secondhand:
            SecondhandListView()
        case .forum:
            ForumListView()
        }
    }

    private func dismissSearchKeyboard() {
        isSearchFieldFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func handleResultTap(_ result: UnifiedSearchResult) {
        Task {
            await openResult(result)
        }
    }

    @MainActor
    private func openResult(_ result: UnifiedSearchResult) async {
        guard !isOpeningResult else { return }

        isOpeningResult = true
        defer { isOpeningResult = false }

        do {
            let destination: SearchResolvedDestination
            switch result.category {
            case .secondhand:
                destination = .secondhand(try await SecondhandService.shared.fetchItem(postId: result.id))
            case .forum:
                destination = .forum(try await ForumService.shared.fetchPost(postId: result.id))
            case .all:
                return
            }

            selectedResolvedResult = nil
            selectedResolvedResult = destination
        } catch {
            resultOpenErrorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func resolvedDestinationView(for destination: SearchResolvedDestination) -> some View {
        switch destination {
        case .secondhand(let item):
            SecondhandDetailView(item: item)
        case .forum(let post):
            ForumDetailView(post: post)
        }
    }
}

// MARK: - 搜索分类
enum SearchCategory: String, CaseIterable, Hashable {
    case all
    case secondhand
    case forum

    var displayName: String {
        switch self {
        case .all: return L10n.tr("All", "全部")
        case .secondhand: return L10n.tr("Secondhand", "二手")
        case .forum: return L10n.tr("Forum", "论坛")
        }
    }

    var hotRankingDisplayName: String {
        switch self {
        case .all: return L10n.tr("Overall", "综合")
        case .secondhand, .forum: return displayName
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .secondhand: return "bag"
        case .forum: return "bubble.left"
        }
    }

    var color: Color {
        switch self {
        case .all: return .secondary
        case .secondhand: return AppColors.categoryColor(for: "secondhand")
        case .forum: return AppColors.categoryColor(for: "forum")
        }
    }

    var navigationDestination: SearchNavigationDestination? {
        switch self {
        case .all: return nil
        case .secondhand: return .secondhand
        case .forum: return .forum
        }
    }
}

enum SearchNavigationDestination: String, Identifiable {
    case secondhand
    case forum

    var id: String { rawValue }
}

struct UnifiedSearchResult: Identifiable, Hashable {
    let id: UUID
    let title: String
    let subtitle: String
    let category: SearchCategory
    let createdAt: Date?
    let previewImageURL: String?
    let hotScore: Double
    let rankScore: Double

    var relativeTimeText: String {
        guard let createdAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }
}

private enum SearchResolvedDestination: Hashable, Identifiable {
    case secondhand(SecondhandItem)
    case forum(ForumPostItem)

    var id: UUID {
        switch self {
        case .secondhand(let item):
            return item.id
        case .forum(let post):
            return post.id
        }
    }
}

// MARK: - 搜索视图模型
@MainActor
final class SearchViewModel: ObservableObject {
    typealias PostPageLoader = (
        String,
        SearchCategory,
        SearchPostCursor?,
        Int
    ) async throws -> SearchPostPage
    typealias PostCountLoader = () async throws -> [SearchCategory: Int]
    typealias ProfileLoader = (String, Int) async throws -> [SearchProfileResult]

    @Published var recentSearches: [String] = []
    @Published var trendingItems: [UnifiedSearchResult] = []
    @Published var hotByCategory: [SearchCategory: [UnifiedSearchResult]] = [:]
    @Published var categoryCounts: [SearchCategory: Int] = [:]
    @Published var filteredResults: [UnifiedSearchResult] = []
    @Published var profileResults: [SearchProfileResult] = []
    @Published var isLoading = false
    @Published var isSearching = false
    @Published private(set) var isLoadingMoreSearchResults = false
    @Published private(set) var hasMoreSearchResults = false
    @Published private(set) var searchPageErrorMessage: String?
    @Published private(set) var hasResolvedInitialLandingLoad = false
    @Published private(set) var accountGeneration: UInt64 = 0
    @Published private(set) var togglingProfileIDs: Set<UUID> = []

    private var postSearchTask: Task<Void, Never>?
    private var currentPostSearchQuery: String = ""
    private var currentPostSearchCategory: SearchCategory = .all
    private var profileSearchTask: Task<Void, Never>?
    private var lastProfileQuery: String = ""
    private var searchCursor: SearchPostCursor?
    private var searchPageRequestID: UUID?
    private let recentSearchesKeyPrefix = "search_recent_queries."
    private let searchPageSize = 24
    private let hotPerCategoryLimit = 10
    private let searchService = SearchService.shared
    private let loadPostPage: PostPageLoader
    private let loadPostCounts: PostCountLoader
    private let loadProfiles: ProfileLoader
    private let searchDebounceNanoseconds: UInt64
    private let defaults: UserDefaults
    private var accountOwnerID: UUID?

    init(
        loadPostPage: @escaping PostPageLoader = { query, category, cursor, limit in
            try await SearchService.shared.searchPostsPage(
                query: query,
                category: category,
                after: cursor,
                limit: limit
            )
        },
        loadPostCounts: @escaping PostCountLoader = {
            try await SearchService.shared.fetchPostCounts()
        },
        loadProfiles: @escaping ProfileLoader = {
            try await SearchService.shared.searchProfiles(query: $0, limit: $1)
        },
        searchDebounceNanoseconds: UInt64 = 280_000_000,
        defaults: UserDefaults = .standard
    ) {
        self.loadPostPage = loadPostPage
        self.loadPostCounts = loadPostCounts
        self.loadProfiles = loadProfiles
        self.searchDebounceNanoseconds = searchDebounceNanoseconds
        self.defaults = defaults
    }

    func activateAccount(_ userID: UUID?) {
        guard accountOwnerID != userID else { return }
        accountGeneration &+= 1
        accountOwnerID = userID
        postSearchTask?.cancel()
        profileSearchTask?.cancel()
        postSearchTask = nil
        profileSearchTask = nil
        currentPostSearchQuery = ""
        currentPostSearchCategory = .all
        lastProfileQuery = ""
        searchCursor = nil
        searchPageRequestID = nil
        trendingItems = []
        hotByCategory = [:]
        categoryCounts = [:]
        filteredResults = []
        profileResults = []
        isLoading = false
        isSearching = false
        isLoadingMoreSearchResults = false
        hasMoreSearchResults = false
        searchPageErrorMessage = nil
        hasResolvedInitialLandingLoad = false
        togglingProfileIDs = []
        loadRecentSearches()
    }

    func loadInitialData() async {
        guard !isLoading else { return }
        let requestGeneration = accountGeneration
        isLoading = true
        defer {
            if accountGeneration == requestGeneration {
                isLoading = false
                if !Task.isCancelled {
                    hasResolvedInitialLandingLoad = true
                }
            }
        }

        async let counts = try? loadPostCounts()
        async let secondhand = try? loadPostPage("", .secondhand, nil, hotPerCategoryLimit)
        async let forum = try? loadPostPage("", .forum, nil, hotPerCategoryLimit)

        let landingCounts = await counts ?? [:]
        let categoryPages: [SearchCategory: [UnifiedSearchResult]] = [
            .secondhand: await secondhand?.results ?? [],
            .forum: await forum?.results ?? []
        ]

        guard accountGeneration == requestGeneration, !Task.isCancelled else { return }
        categoryCounts = landingCounts
        hotByCategory = categoryPages
        trendingItems = Array(
            categoryPages.values
                .flatMap { $0 }
                .sorted(by: isHigherPriorityForFeed)
                .prefix(5)
        )
    }

    func updateSearch(text: String, category: SearchCategory) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            postSearchTask?.cancel()
            currentPostSearchQuery = ""
            currentPostSearchCategory = category
            searchCursor = nil
            searchPageRequestID = nil
            hasMoreSearchResults = false
            isLoadingMoreSearchResults = false
            searchPageErrorMessage = nil
            profileSearchTask?.cancel()
            lastProfileQuery = ""
            filteredResults = []
            profileResults = []
            isSearching = false
            return
        }

        isSearching = true
        filteredResults = []
        searchCursor = nil
        searchPageRequestID = nil
        hasMoreSearchResults = false
        isLoadingMoreSearchResults = false
        searchPageErrorMessage = nil
        searchProfiles(with: query)
        scheduleRemotePostSearch(query: query, category: category)
    }

    private func scheduleRemotePostSearch(
        query: String,
        category: SearchCategory
    ) {
        postSearchTask?.cancel()
        currentPostSearchQuery = query
        currentPostSearchCategory = category
        let requestGeneration = accountGeneration
        postSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: searchDebounceNanoseconds)
            } catch {
                return
            }
            if Task.isCancelled { return }
            await self.reloadPostResults(
                query: query,
                category: category,
                generation: requestGeneration
            )
        }
    }

    private func reloadPostResults(
        query: String,
        category: SearchCategory,
        generation: UInt64
    ) async {
        guard accountGeneration == generation,
              currentPostSearchQuery == query,
              currentPostSearchCategory == category
        else { return }

        isSearching = true
        searchPageErrorMessage = nil
        defer {
            if accountGeneration == generation,
               currentPostSearchQuery == query,
               currentPostSearchCategory == category {
                isSearching = false
            }
        }

        do {
            let page = try await loadPostPage(query, category, nil, searchPageSize)
            if Task.isCancelled { return }
            guard accountGeneration == generation,
                  currentPostSearchQuery == query,
                  currentPostSearchCategory == category
            else { return }

            filteredResults = page.results
            searchCursor = page.nextCursor
            hasMoreSearchResults = page.nextCursor != nil
        } catch {
            if Task.isCancelled || error.isCancellationLike { return }
            guard accountGeneration == generation,
                  currentPostSearchQuery == query,
                  currentPostSearchCategory == category
            else { return }
            filteredResults = []
            searchPageErrorMessage = error.localizedDescription
        }
    }

    func loadMoreSearchResults() async {
        guard !isSearching,
              !isLoadingMoreSearchResults,
              hasMoreSearchResults,
              let cursor = searchCursor
        else { return }

        let query = currentPostSearchQuery
        let category = currentPostSearchCategory
        let requestID = UUID()
        let requestGeneration = accountGeneration
        searchPageRequestID = requestID
        isLoadingMoreSearchResults = true
        searchPageErrorMessage = nil

        do {
            let page = try await loadPostPage(query, category, cursor, searchPageSize)
            guard accountGeneration == requestGeneration,
                  searchPageRequestID == requestID,
                  currentPostSearchQuery == query,
                  currentPostSearchCategory == category
            else { return }

            let existingIDs = Set(filteredResults.map(\.id))
            filteredResults.append(
                contentsOf: page.results.filter { !existingIDs.contains($0.id) }
            )
            searchCursor = page.nextCursor
            hasMoreSearchResults = page.nextCursor != nil
        } catch {
            guard accountGeneration == requestGeneration,
                  searchPageRequestID == requestID,
                  currentPostSearchQuery == query,
                  currentPostSearchCategory == category
            else { return }
            if !error.isCancellationLike {
                searchPageErrorMessage = error.localizedDescription
            }
        }

        guard accountGeneration == requestGeneration,
              searchPageRequestID == requestID
        else { return }
        searchPageRequestID = nil
        isLoadingMoreSearchResults = false
    }

    func retrySearchPage() async {
        if filteredResults.isEmpty {
            await reloadPostResults(
                query: currentPostSearchQuery,
                category: currentPostSearchCategory,
                generation: accountGeneration
            )
        } else {
            await loadMoreSearchResults()
        }
    }

    func addRecentSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        recentSearches.removeAll(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        recentSearches.insert(trimmed, at: 0)

        if recentSearches.count > 8 {
            recentSearches = Array(recentSearches.prefix(8))
        }

        persistRecentSearches()
    }

    func clearRecentSearches() {
        recentSearches.removeAll()
        persistRecentSearches()
    }

    func count(for category: SearchCategory) -> Int {
        categoryCounts[category] ?? 0
    }

    func hotPosts(for category: SearchCategory) -> [UnifiedSearchResult] {
        if category == .all {
            return Array(
                hotByCategory.values
                    .flatMap { $0 }
                    .sorted(by: isHigherPriorityForFeed)
                    .prefix(hotPerCategoryLimit)
            )
        }
        return hotByCategory[category] ?? []
    }

    var landingLoadState: CollectionLoadState {
        CollectionLoadState.resolve(
            hasResolvedInitialLoad: hasResolvedInitialLandingLoad,
            isLoading: isLoading,
            hasContent: !categoryCounts.isEmpty,
            errorMessage: nil
        )
    }

    func hotRankingLoadState(for category: SearchCategory) -> CollectionLoadState {
        CollectionLoadState.resolve(
            hasResolvedInitialLoad: hasResolvedInitialLandingLoad,
            isLoading: isLoading,
            hasContent: !hotPosts(for: category).isEmpty,
            errorMessage: nil
        )
    }

    private func loadRecentSearches() {
        guard let key = recentSearchesStorageKey else {
            recentSearches = []
            return
        }
        recentSearches = defaults.stringArray(forKey: key) ?? []
    }

    private func persistRecentSearches() {
        guard let key = recentSearchesStorageKey else { return }
        defaults.set(recentSearches, forKey: key)
    }

    private var recentSearchesStorageKey: String? {
        accountOwnerID.map { recentSearchesKeyPrefix + $0.uuidString }
    }

    func toggleFollow(profile: SearchProfileResult) async throws {
        guard togglingProfileIDs.insert(profile.id).inserted else { return }
        defer { togglingProfileIDs.remove(profile.id) }

        let currentProfile = profileResults.first(where: { $0.id == profile.id })
            ?? profile
        if currentProfile.isFollowing {
            try await searchService.unfollowUser(targetUserId: currentProfile.id)
        } else {
            try await searchService.followUser(targetUserId: currentProfile.id)
        }

        await reloadProfileResults(query: lastProfileQuery)
    }

    func isTogglingFollow(_ userID: UUID) -> Bool {
        togglingProfileIDs.contains(userID)
    }

    func applyFollowChange(targetUserID: UUID, isFollowing: Bool) {
        profileResults = profileResults.map { profile in
            guard profile.id == targetUserID else { return profile }
            return profile.applyingFollowState(isFollowing)
        }
    }

    private func searchProfiles(with query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == lastProfileQuery { return }

        profileSearchTask?.cancel()
        lastProfileQuery = normalized
        let requestGeneration = accountGeneration
        profileSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: searchDebounceNanoseconds)
            } catch {
                return
            }
            if Task.isCancelled { return }
            await self.reloadProfileResults(
                query: normalized,
                generation: requestGeneration
            )
        }
    }

    private func reloadProfileResults(
        query: String,
        generation: UInt64? = nil
    ) async {
        let requestGeneration = generation ?? accountGeneration
        guard requestGeneration == accountGeneration else { return }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            profileResults = []
            return
        }

        do {
            let rows = try await loadProfiles(normalized, 20)

            if Task.isCancelled { return }
            guard requestGeneration == accountGeneration else { return }
            profileResults = rows
        } catch {
            if Task.isCancelled { return }
            guard requestGeneration == accountGeneration else { return }
            profileResults = []
        }
    }

    private func isHigherPriorityForFeed(_ lhs: UnifiedSearchResult, _ rhs: UnifiedSearchResult) -> Bool {
        if lhs.hotScore != rhs.hotScore {
            return lhs.hotScore > rhs.hotScore
        }
        let lhsDate = lhs.createdAt ?? .distantPast
        let rhsDate = rhs.createdAt ?? .distantPast
        return lhsDate > rhsDate
    }
}

// MARK: - 搜索分类胶囊
struct SearchCategoryPill: View {
    let category: SearchCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: category.icon)
                    .font(.system(size: 13, weight: .medium))
                Text(category.displayName)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? AppColors.selectedBackground : AppColors.cardBackground)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
        }
    }
}

// MARK: - 热门榜文字行
struct TextHotRankRow: View {
    let rank: Int
    let item: UnifiedSearchResult

    var body: some View {
        HStack(spacing: 14) {
            Text("\(rank)")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(rank <= 3 ? AppColors.accentStrong : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(item.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("#\(item.category.displayName)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.category.color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - 搜索结果卡片
struct SearchResultCard: View {
    let item: UnifiedSearchResult

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let previewImageURL = item.previewImageURL,
                   let url = URL(string: previewImageURL) {
                    CachedRemoteImage(url: url, targetPixelWidth: 192) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(item.category.color.opacity(0.15))
                            .overlay {
                                Image(systemName: item.category.icon)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(item.category.color)
                            }
                    }
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(item.category.color.opacity(0.15))
                        .overlay {
                            Image(systemName: item.category.icon)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(item.category.color)
                        }
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .tappableImagePreview(item.previewImageURL)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.category.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.category.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(item.category.color.opacity(0.12))
                    .cornerRadius(4)

                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(item.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !item.relativeTimeText.isEmpty {
                Text(item.relativeTimeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .cheeseCardChrome(cornerRadius: 14)
    }
}

struct SearchProfileCard: View {
    let profile: SearchProfileResult
    let isCurrentUser: Bool
    let isFollowBusy: Bool
    let onOpenProfile: () -> Void
    let onFollowTap: () -> Void
    let onMessageTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpenProfile) {
                HStack(spacing: 12) {
                    avatarView

                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.fullName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)

                        if let university = profile.university, !university.isEmpty {
                            Text(university)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppColors.textMuted)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let bio = profile.bio, !bio.isEmpty {
                Text(bio)
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textMuted)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                Button(action: onOpenProfile) {
                    Text("主页")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                if !isCurrentUser {
                    Button(action: onFollowTap) {
                        HStack(spacing: 6) {
                            if isFollowBusy {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(profile.isFollowing ? "已关注" : "关注")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(AppColors.accent)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isFollowBusy)

                    Button(action: onMessageTap) {
                        Text("私信")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(AppColors.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if profile.isMutualFollow {
                    Text("互关")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppColors.link)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(AppColors.link.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer()
            }
        }
        .padding(12)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .cheeseCardChrome(cornerRadius: 14)
    }

    private var avatarView: some View {
        Group {
            if let avatarURL = profile.avatarURL,
               let url = URL(string: avatarURL),
               !avatarURL.isEmpty {
                CachedRemoteImage(url: url, targetPixelWidth: 160) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    avatarFallback
                }
            } else {
                avatarFallback
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
    }

    private var avatarFallback: some View {
        Circle()
            .fill(AppColors.accent.opacity(0.2))
            .overlay {
                Text(String(profile.fullName.prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
            }
    }
}

// MARK: - Flow Layout
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth, x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: y + rowHeight)
        }
    }
}

#Preview {
    SearchView()
}
