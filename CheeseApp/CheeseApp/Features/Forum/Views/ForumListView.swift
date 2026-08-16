//
//  ForumListView.swift
//  CheeseApp
//
//  Independent Forum board page.
//

import SwiftUI

struct ForumBoardView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @StateObject private var service = ForumService.shared
    @StateObject private var postEditor = UserPostsService()

    @State private var showingCreatePost = false
    @State private var showingSearch = false
    private let boardID: UUID

    @State private var selectedSort: ForumPostSort = .hottest
    @State private var selectedPost: ForumPostItem?
    @State private var editingPost: UserPostSummary?
    @State private var sharingPost: PostSharePayload?
    @State private var rulesBoard: ForumBoard?
    @State private var shareActionToastMessage: String?
    @State private var hasLoadedInitialData = false
    @State private var feedReloadGeneration = 0

    init(boardID: UUID) {
        self.boardID = boardID
    }

    var body: some View {
        ZStack {
            AppColors.pageBackground.ignoresSafeArea()
            feed
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showingCreatePost) {
            CreateForumView(initialBoard: selectedBoard)
        }
        .navigationDestination(isPresented: $showingSearch) {
            ForumSearchView(initialBoard: selectedBoard)
        }
        .navigationDestination(item: $selectedPost) { post in
            ForumDetailView(post: post)
        }
        .sheet(item: $rulesBoard) { board in
            ForumBoardRulesSheet(board: board)
        }
        .navigationDestination(item: $editingPost) { post in
            EditPostSheet(post: post) { payload in
                try await postEditor.update(payload: payload)
                feedReloadGeneration &+= 1
            }
        }
        .cheesePostSharePanel(item: $sharingPost) { targetName in
            ShareFeedbackPresenter.show("已分享到 \(targetName)") {
                shareActionToastMessage = $0
            }
        }
        .task {
            guard !hasLoadedInitialData else { return }
            hasLoadedInitialData = true
            await refreshContent()
        }
        .onReceive(NotificationCenter.default.publisher(for: PostFeatureEvents.postsDidChange)) { note in
            guard PostFeatureEvents.changedPostKind(from: note) == .forum else { return }
            feedReloadGeneration &+= 1
        }
        .shareFeedbackToast(message: $shareActionToastMessage)
        .enableSwipeBackGesture()
    }

    private var feed: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .padding(.top, 8)

            if let board = selectedBoard {
                ForumChannelPageView(
                    board: board,
                    sort: $selectedSort,
                    accountGeneration: service.accountGeneration,
                    reloadGeneration: feedReloadGeneration,
                    currentUserID: authService.currentUser?.id,
                    onOpen: { selectedPost = $0 },
                    onEdit: { editingPost = $0.editableSummary },
                    onShare: { sharingPost = $0.sharePayload },
                    onOpenRules: { rulesBoard = $0 }
                )
                .id(board.id)
            } else {
                ProgressView(L10n.tr("Loading board…", "正在载入板块…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                showingCreatePost = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(AppColors.accentStrong)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.18), radius: 9, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20)
            .padding(
                .bottom,
                CheeseTabBarLayout.contentBottomClearance - 16
            )
            .accessibilityLabel(L10n.tr("Create Forum post", "发布论坛帖子"))
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                PostToolbarIconCircle(icon: "chevron.left")
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: { showingSearch = true }) {
                PostToolbarIconCircle(icon: "magnifyingglass", size: 16, frameSize: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    private var selectedBoard: ForumBoard? {
        service.boards.first {
            $0.id == boardID && $0.status != .archived
        }
    }

    private func refreshContent() async {
        await service.fetchBoards()

        feedReloadGeneration &+= 1
    }

}

private struct ForumChannelPageView: View {
    let board: ForumBoard
    @Binding var sort: ForumPostSort
    let accountGeneration: UInt64
    let reloadGeneration: Int
    let currentUserID: UUID?
    let onOpen: (ForumPostItem) -> Void
    let onEdit: (ForumPostItem) -> Void
    let onShare: (ForumPostItem) -> Void
    let onOpenRules: (ForumBoard) -> Void

    @StateObject private var model: ForumChannelFeedModel
    @State private var likingPostIDs: Set<UUID> = []
    @State private var favoritingPostIDs: Set<UUID> = []
    @State private var appliedReloadGeneration = 0

    init(
        board: ForumBoard,
        sort: Binding<ForumPostSort>,
        accountGeneration: UInt64,
        reloadGeneration: Int,
        currentUserID: UUID?,
        onOpen: @escaping (ForumPostItem) -> Void,
        onEdit: @escaping (ForumPostItem) -> Void,
        onShare: @escaping (ForumPostItem) -> Void,
        onOpenRules: @escaping (ForumBoard) -> Void
    ) {
        self.board = board
        self._sort = sort
        self.accountGeneration = accountGeneration
        self.reloadGeneration = reloadGeneration
        self.currentUserID = currentUserID
        self.onOpen = onOpen
        self.onEdit = onEdit
        self.onShare = onShare
        self.onOpenRules = onOpenRules
        _model = StateObject(
            wrappedValue: ForumChannelFeedModel(boardID: board.id)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ForumBoardIntroductionCard(
                    board: board,
                    onRulesTap: { onOpenRules(board) }
                )

                ForumBoardSortPicker(selection: $sort)
            }
            .padding(.horizontal, 16)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    feedContent

                    if model.hasMore {
                        paginationFooter
                    }

                    Spacer(minLength: 100)
                }
                .padding(.horizontal, 16)
            }
            .refreshable {
                await model.load(
                    generation: accountGeneration,
                    sort: sort,
                    force: true
                )
            }
        }
        .background(AppColors.pageBackground)
        .task(id: loadTaskID) {
            let shouldForce = reloadGeneration > appliedReloadGeneration
            appliedReloadGeneration = max(
                appliedReloadGeneration,
                reloadGeneration
            )
            await model.load(
                generation: accountGeneration,
                sort: sort,
                force: shouldForce
            )
        }
    }

    @ViewBuilder
    private var feedContent: some View {
        switch model.loadState {
        case .unresolved, .initialLoading:
            ProgressView(L10n.tr("Loading posts…", "正在载入内容…"))
                .frame(height: 180)
        case .empty:
            emptyState
        case .error(let message):
            ErrorView(message) {
                Task {
                    await model.load(
                        generation: accountGeneration,
                        sort: sort,
                        force: true
                    )
                }
            }
            .frame(height: 220)
        case .loaded:
            ForEach(model.posts) { post in
                ForumPostCardView(
                    post: post,
                    isOwnPost: currentUserID == post.authorId,
                    headerStyle: .author,
                    onTap: { onOpen(post) },
                    onLikeTap: { await toggleLike(for: post) },
                    onFavoriteTap: { await toggleFavorite(for: post) },
                    onEditTap: { onEdit(post) },
                    onShareTap: { onShare(post) },
                    onBoardTap: nil
                )
            }
        }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if model.isLoadingNextPage {
            ProgressView()
        } else if let message = model.pageErrorMessage {
            Button(message) {
                Task {
                    await model.loadNextPage(
                        generation: accountGeneration,
                        sort: sort
                    )
                }
            }
            .font(.footnote)
        } else {
            ProgressView()
                .onAppear {
                    Task {
                        await model.loadNextPage(
                            generation: accountGeneration,
                            sort: sort
                        )
                    }
                }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(L10n.tr("No posts yet", "还没有帖子"))
                .font(.headline)
            Text(
                L10n.tr(
                    "Be the first to start a conversation.",
                    "来发布第一篇讨论吧。"
                )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }

    private var loadTaskID: String {
        "\(accountGeneration):\(reloadGeneration):\(sort.rawValue)"
    }

    @MainActor
    private func toggleLike(for post: ForumPostItem) async {
        guard likingPostIDs.insert(post.id).inserted else { return }
        defer { likingPostIDs.remove(post.id) }

        let store = PostInteractionStore.shared
        let previous = store.state(
            for: post.id,
            fallbackLikeCount: post.likes,
            fallbackIsLiked: post.isLiked
        )
        let optimisticLiked = !previous.isLiked
        guard store.beginLikeMutation(
            postID: post.id,
            desiredIsLiked: optimisticLiked
        ) else { return }
        store.replace(
            postID: post.id,
            with: PostInteractionState(
                likeCount: max(previous.likeCount + (optimisticLiked ? 1 : -1), 0),
                isLiked: optimisticLiked,
                isFavorited: previous.isFavorited
            )
        )

        do {
            let isLiked = try await ForumService.shared.toggleLike(
                postId: post.id,
                currentlyLiked: previous.isLiked
            )
            model.applyLike(postID: post.id, isLiked: isLiked)
            store.finishLikeMutation(
                postID: post.id,
                committedIsLiked: isLiked
            )
        } catch {
            store.replace(postID: post.id, with: previous)
            store.finishLikeMutation(
                postID: post.id,
                committedIsLiked: nil
            )
        }
    }

    @MainActor
    private func toggleFavorite(for post: ForumPostItem) async {
        guard favoritingPostIDs.insert(post.id).inserted else { return }
        defer { favoritingPostIDs.remove(post.id) }

        let store = PostInteractionStore.shared
        let previous = store.state(
            for: post.id,
            fallbackLikeCount: post.likes,
            fallbackIsLiked: post.isLiked
        )
        store.setFavorite(postID: post.id, isFavorited: !previous.isFavorited)

        do {
            let confirmed = try await ForumService.shared.toggleFavorite(
                postId: post.id,
                currentlyFavorited: previous.isFavorited
            )
            store.setFavorite(postID: post.id, isFavorited: confirmed)
        } catch {
            store.replace(postID: post.id, with: previous)
        }
    }
}

private struct ForumBoardIntroductionCard: View {
    let board: ForumBoard
    let onRulesTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: board.icon)
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(AppColors.accentStrong)
                    .frame(width: 50, height: 50)
                    .background(AppColors.accent.opacity(0.14))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 15,
                            style: .continuous
                        )
                    )

                Text(board.name)
                    .font(.system(size: 21, weight: .bold))
                Spacer()
            }

            Text(board.description)
                .font(.system(size: 14))
                .foregroundStyle(AppColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onRulesTap) {
                Label(
                    L10n.tr("Rules", "板块规则"),
                    systemImage: "doc.text"
                )
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppColors.accentStrong)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(AppColors.divider)
        }
        .accessibilityLabel(
            L10n.tr(
                "\(board.name), \(board.description)",
                "\(board.name)，\(board.description)"
            )
        )
    }
}

private struct ForumBoardSortPicker: View {
    @Binding var selection: ForumPostSort

    private let options: [ForumPostSort] = [.hottest, .latest]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                Button {
                    guard selection != option else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selection = option
                    }
                } label: {
                    VStack(spacing: 8) {
                        Text(title(for: option))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(
                                selection == option
                                    ? AppColors.textPrimary
                                    : AppColors.textMuted
                            )

                        Capsule()
                            .fill(
                                selection == option
                                    ? AppColors.accentStrong
                                    : Color.clear
                            )
                            .frame(height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(
                    selection == option ? .isSelected : []
                )
            }
        }
        .overlay(alignment: .bottom) {
            Divider().overlay(AppColors.divider)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Post sorting", "帖子排序"))
    }

    private func title(for option: ForumPostSort) -> String {
        switch option {
        case .hottest:
            return L10n.tr("Popular", "热门")
        case .latest:
            return L10n.tr("Latest", "最新")
        }
    }
}

@MainActor
private final class ForumChannelFeedModel: ObservableObject {
    @Published private(set) var posts: [ForumPostItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingNextPage = false
    @Published private(set) var hasMore = true
    @Published private(set) var hasResolvedInitialLoad = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var pageErrorMessage: String?

    let boardID: UUID

    private let service = ForumService.shared
    private var cursor: ForumPostPageCursor?
    private var latestRequestID: UUID?
    private var stateGeneration: UInt64?
    private var loadedSort: ForumPostSort?

    init(boardID: UUID) {
        self.boardID = boardID
    }

    var loadState: CollectionLoadState {
        CollectionLoadState.resolve(
            hasResolvedInitialLoad: hasResolvedInitialLoad,
            isLoading: isLoading,
            hasContent: !posts.isEmpty,
            errorMessage: errorMessage
        )
    }

    func load(
        generation: UInt64,
        sort: ForumPostSort,
        force: Bool = false
    ) async {
        guard service.isCurrentAccountRequest(generation: generation) else {
            return
        }
        resetIfAccountChanged(generation: generation)
        guard force || loadedSort != sort || !hasResolvedInitialLoad else {
            return
        }

        let requestID = UUID()
        latestRequestID = requestID
        isLoading = true
        errorMessage = nil
        pageErrorMessage = nil
        if force, posts.isEmpty {
            hasResolvedInitialLoad = false
        }

        defer {
            if latestRequestID == requestID,
               service.isCurrentAccountRequest(generation: generation) {
                isLoading = false
            }
        }

        do {
            let page = try await service.fetchPostPage(
                boardID: boardID,
                sort: sort,
                after: nil
            )
            let favoritePostIDs = await PostFavoriteService.shared
                .fetchFavoritePostIds(postIds: page.items.map(\.id))
            guard latestRequestID == requestID,
                  service.isCurrentAccountRequest(generation: generation)
            else { return }

            mergeInteractionState(
                for: page.items,
                favoritePostIDs: favoritePostIDs
            )
            posts = page.items
            cursor = page.cursor
            hasMore = page.hasMore
            loadedSort = sort
            hasResolvedInitialLoad = true
        } catch {
            guard latestRequestID == requestID,
                  service.isCurrentAccountRequest(generation: generation),
                  !error.isCancellationLike
            else { return }

            errorMessage = L10n.tr(
                "Unable to load posts.",
                "帖子加载失败。"
            )
            hasResolvedInitialLoad = true
        }
    }

    func loadNextPage(
        generation: UInt64,
        sort: ForumPostSort
    ) async {
        resetIfAccountChanged(generation: generation)
        guard hasResolvedInitialLoad,
              hasMore,
              !isLoading,
              !isLoadingNextPage,
              loadedSort == sort,
              service.isCurrentAccountRequest(generation: generation)
        else { return }

        let expectedRequestID = latestRequestID
        isLoadingNextPage = true
        pageErrorMessage = nil
        defer {
            if latestRequestID == expectedRequestID,
               service.isCurrentAccountRequest(generation: generation) {
                isLoadingNextPage = false
            }
        }

        do {
            let page = try await service.fetchPostPage(
                boardID: boardID,
                sort: sort,
                after: cursor
            )
            guard latestRequestID == expectedRequestID,
                  service.isCurrentAccountRequest(generation: generation)
            else { return }

            let existingIDs = Set(posts.map(\.id))
            let newPosts = page.items.filter { !existingIDs.contains($0.id) }
            let favoritePostIDs = await PostFavoriteService.shared
                .fetchFavoritePostIds(postIds: newPosts.map(\.id))
            guard latestRequestID == expectedRequestID,
                  service.isCurrentAccountRequest(generation: generation)
            else { return }

            mergeInteractionState(
                for: newPosts,
                favoritePostIDs: favoritePostIDs
            )
            posts.append(contentsOf: newPosts)
            cursor = page.cursor ?? cursor
            hasMore = page.hasMore
        } catch {
            guard latestRequestID == expectedRequestID,
                  service.isCurrentAccountRequest(generation: generation),
                  !error.isCancellationLike
            else { return }

            pageErrorMessage = L10n.tr(
                "Unable to load more posts. Tap to retry.",
                "加载更多帖子失败，点击重试。"
            )
        }
    }

    func applyLike(postID: UUID, isLiked: Bool) {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else {
            return
        }
        guard posts[index].isLiked != isLiked else { return }

        posts[index].isLiked = isLiked
        posts[index].likes = max(
            posts[index].likes + (isLiked ? 1 : -1),
            0
        )
    }

    private func mergeInteractionState(
        for posts: [ForumPostItem],
        favoritePostIDs: Set<UUID>
    ) {
        PostInteractionStore.shared.mergeServerSnapshots(
            posts.map { post in
                PostInteractionStore.Update(
                    postID: post.id,
                    likeCount: post.likes,
                    isLiked: post.isLiked,
                    isFavorited: favoritePostIDs.contains(post.id)
                )
            }
        )
    }

    private func resetIfAccountChanged(generation: UInt64) {
        guard stateGeneration != generation else { return }
        stateGeneration = generation
        loadedSort = nil
        latestRequestID = nil
        cursor = nil
        posts = []
        isLoading = false
        isLoadingNextPage = false
        hasMore = true
        hasResolvedInitialLoad = false
        errorMessage = nil
        pageErrorMessage = nil
    }
}
