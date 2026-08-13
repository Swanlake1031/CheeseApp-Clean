//
//  ForumListView.swift
//  CheeseApp
//
//  Aggregate Forum feed with reusable board navigation.
//

import SwiftUI

struct ForumListView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @StateObject private var service = ForumService.shared
    @StateObject private var postEditor = UserPostsService()

    @State private var showingCreatePost = false
    @State private var showingSearch = false
    @State private var selectedFeedBoardID: UUID?
    @State private var selectedPost: ForumPostItem?
    @State private var editingPost: UserPostSummary?
    @State private var sharingPost: PostSharePayload?
    @State private var rulesBoard: ForumBoard?
    @State private var shareActionToastMessage: String?
    @State private var hasLoadedInitialData = false
    @State private var feedReloadGeneration = 0

    init(initialBoardID: UUID? = nil) {
        _selectedFeedBoardID = State(initialValue: initialBoardID)
    }

    var body: some View {
        ZStack {
            AppColors.pageBackground.ignoresSafeArea()
            feed
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showingCreatePost) {
            CreateForumView(initialBoard: selectedFeedBoard)
        }
        .navigationDestination(isPresented: $showingSearch) {
            ForumSearchView(initialBoard: selectedFeedBoard)
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

            ExpandableCategoryPicker(
                selection: selectedBoardBinding,
                options: visibleBoards,
                recommendedTitle: L10n.tr("Recommended", "推荐"),
                accessibilityTitle: L10n.tr("Forum categories", "论坛分区"),
                title: { $0.name },
                icon: { $0.icon }
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            ForumChannelPageView(
                board: selectedFeedBoard,
                boardID: selectedFeedBoardID,
                accountGeneration: service.accountGeneration,
                reloadGeneration: feedReloadGeneration,
                currentUserID: authService.currentUser?.id,
                onOpen: { selectedPost = $0 },
                onEdit: { editingPost = $0.editableSummary },
                onShare: { sharingPost = $0.sharePayload },
                onOpenBoard: { openBoard($0) },
                onOpenRules: { rulesBoard = $0 }
            )
            .id(selectedFeedBoardID)
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
            .padding(.bottom, CheeseTabBarLayout.contentBottomClearance)
            .accessibilityLabel(L10n.tr("Create Forum post", "发布论坛帖子"))
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                PostToolbarIconCircle(icon: "chevron.left")
            }
            .buttonStyle(.plain)

            Text(L10n.tr("Forum", "论坛"))
                .font(.system(size: 25, weight: .bold))
            Spacer()

            Button(action: { showingSearch = true }) {
                PostToolbarIconCircle(icon: "magnifyingglass", size: 16, frameSize: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    private var visibleBoards: [ForumBoard] {
        service.boards.filter { $0.status != .archived }
    }

    private var selectedFeedBoard: ForumBoard? {
        visibleBoards.first { $0.id == selectedFeedBoardID }
    }

    private var selectedBoardBinding: Binding<ForumBoard?> {
        Binding(
            get: { selectedFeedBoard },
            set: { selectFeedBoard($0?.id) }
        )
    }

    private func selectFeedBoard(_ boardID: UUID?) {
        guard selectedFeedBoardID != boardID else { return }
        withAnimation(.easeInOut(duration: 0.24)) {
            selectedFeedBoardID = boardID
        }
    }

    private func refreshContent() async {
        await service.fetchBoards()

        if let selectedFeedBoardID,
           !visibleBoards.contains(where: { $0.id == selectedFeedBoardID }) {
            self.selectedFeedBoardID = nil
        }
        feedReloadGeneration &+= 1
    }

    private func openBoard(_ boardID: UUID) {
        guard visibleBoards.contains(where: { $0.id == boardID }) else { return }
        selectFeedBoard(boardID)
    }

}

private struct ForumChannelPageView: View {
    let board: ForumBoard?
    let accountGeneration: UInt64
    let reloadGeneration: Int
    let currentUserID: UUID?
    let onOpen: (ForumPostItem) -> Void
    let onEdit: (ForumPostItem) -> Void
    let onShare: (ForumPostItem) -> Void
    let onOpenBoard: (UUID) -> Void
    let onOpenRules: (ForumBoard) -> Void

    @StateObject private var model: ForumChannelFeedModel
    @State private var likingPostIDs: Set<UUID> = []
    @State private var appliedReloadGeneration = 0

    init(
        board: ForumBoard?,
        boardID: UUID? = nil,
        accountGeneration: UInt64,
        reloadGeneration: Int,
        currentUserID: UUID?,
        onOpen: @escaping (ForumPostItem) -> Void,
        onEdit: @escaping (ForumPostItem) -> Void,
        onShare: @escaping (ForumPostItem) -> Void,
        onOpenBoard: @escaping (UUID) -> Void,
        onOpenRules: @escaping (ForumBoard) -> Void
    ) {
        self.board = board
        self.accountGeneration = accountGeneration
        self.reloadGeneration = reloadGeneration
        self.currentUserID = currentUserID
        self.onOpen = onOpen
        self.onEdit = onEdit
        self.onShare = onShare
        self.onOpenBoard = onOpenBoard
        self.onOpenRules = onOpenRules
        _model = StateObject(
            wrappedValue: ForumChannelFeedModel(boardID: boardID ?? board?.id)
        )
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 10) {
                if let board {
                    ForumBoardIntroductionCard(
                        board: board,
                        onRulesTap: { onOpenRules(board) }
                    )
                }

                feedContent

                if model.hasMore {
                    paginationFooter
                }

                Spacer(minLength: 100)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .background(AppColors.pageBackground)
        .refreshable {
            await model.load(
                generation: accountGeneration,
                force: true
            )
        }
        .task(id: loadTaskID) {
            let shouldForce = reloadGeneration > appliedReloadGeneration
            appliedReloadGeneration = max(
                appliedReloadGeneration,
                reloadGeneration
            )
            await model.load(
                generation: accountGeneration,
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
                    onTap: { onOpen(post) },
                    onLikeTap: { await toggleLike(for: post) },
                    onEditTap: { onEdit(post) },
                    onShareTap: { onShare(post) },
                    onBoardTap: { onOpenBoard(post.boardID) }
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
                        generation: accountGeneration
                    )
                }
            }
            .font(.footnote)
        } else {
            ProgressView()
                .onAppear {
                    Task {
                        await model.loadNextPage(
                            generation: accountGeneration
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
        "\(accountGeneration):\(reloadGeneration)"
    }

    @MainActor
    private func toggleLike(for post: ForumPostItem) async {
        guard likingPostIDs.insert(post.id).inserted else { return }
        defer { likingPostIDs.remove(post.id) }

        do {
            let interaction = PostInteractionStore.shared.state(
                for: post.id,
                fallbackLikeCount: post.likes,
                fallbackIsLiked: post.isLiked
            )
            let isLiked = try await ForumService.shared.toggleLike(
                postId: post.id,
                currentlyLiked: interaction.isLiked
            )
            model.applyLike(postID: post.id, isLiked: isLiked)
        } catch {
            // The card stays on its last confirmed state when the request fails.
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .cheeseCardChrome(cornerRadius: 18)
        .accessibilityLabel(
            L10n.tr(
                "\(board.name), \(board.description)",
                "\(board.name)，\(board.description)"
            )
        )
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

    let boardID: UUID?

    private let service = ForumService.shared
    private var cursor: ForumPostPageCursor?
    private var latestRequestID: UUID?
    private var stateGeneration: UInt64?

    init(boardID: UUID?) {
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

    func load(generation: UInt64, force: Bool = false) async {
        guard service.isCurrentAccountRequest(generation: generation) else {
            return
        }
        resetIfAccountChanged(generation: generation)
        guard force || !hasResolvedInitialLoad else { return }

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
                sort: .latest,
                after: nil
            )
            guard latestRequestID == requestID,
                  service.isCurrentAccountRequest(generation: generation)
            else { return }

            posts = boardID == nil
                ? ForumService.spreadingBoards(in: page.items)
                : page.items
            cursor = page.cursor
            hasMore = page.hasMore
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

    func loadNextPage(generation: UInt64) async {
        resetIfAccountChanged(generation: generation)
        guard hasResolvedInitialLoad,
              hasMore,
              !isLoading,
              !isLoadingNextPage,
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
                sort: .latest,
                after: cursor
            )
            guard latestRequestID == expectedRequestID,
                  service.isCurrentAccountRequest(generation: generation)
            else { return }

            let existingIDs = Set(posts.map(\.id))
            let newPosts = page.items.filter { !existingIDs.contains($0.id) }
            posts.append(contentsOf: boardID == nil
                ? ForumService.spreadingBoards(in: newPosts)
                : newPosts
            )
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

    private func resetIfAccountChanged(generation: UInt64) {
        guard stateGeneration != generation else { return }
        stateGeneration = generation
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
