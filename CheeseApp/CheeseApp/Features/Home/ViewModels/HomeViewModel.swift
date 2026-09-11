//
//  HomeViewModel.swift
//  CheeseApp
//
//  首页数据状态与刷新编排
//

import SwiftUI
import OSLog

enum HomeFeedAuthFailurePolicy {
    static func shouldRetry(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == 401 || nsError.code == 403 || nsError.code == 42_501 {
            return true
        }

        let message = nsError.localizedDescription.lowercased()
        return message.contains("unauthorized")
            || message.contains("not authenticated")
            || message.contains("jwt")
            || message.contains("permission denied")
    }
}

struct HomeFeaturedForumItem: Identifiable, Hashable {
    let configuration: HomeFeaturedPost
    let post: ForumPostItem

    var id: UUID { post.id }
    var badge: String? { configuration.badge }

    var badgeText: String {
        let configured = configuration.badge?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty {
            return configured
        }
        return post.isAuthorOfficial
            ? L10n.tr("Cheese Official", "奶酪官方")
            : L10n.tr("Campus Pick", "校园精选")
    }

    var cardAccessibilityLabel: String {
        "\(badgeText)，\(post.title)"
    }

    static func resolve(
        configurations: [HomeFeaturedPost],
        postsByID: [UUID: ForumPostItem]
    ) -> [HomeFeaturedForumItem] {
        configurations
            .sorted { $0.displayOrder < $1.displayOrder }
            .compactMap { configuration in
                postsByID[configuration.postID].map {
                    HomeFeaturedForumItem(configuration: configuration, post: $0)
                }
            }
    }
}

// MARK: - 首页视图模型
@MainActor
class HomeViewModel: ObservableObject {

    private struct FeaturedSnapshot {
        let cards: [HomeCardItem]
        let itemsByID: [UUID: SecondhandItem]
    }

    private struct ForumSnapshot {
        let cards: [HomeCardItem]
        let postsByID: [UUID: ForumPostItem]
        let recommendationSessionID: UUID?
        let recommendationPositions: [UUID: Int]
        let resolution: HomeForumSessionResolution?
    }

    private struct HomeFeaturedSnapshot {
        let items: [HomeFeaturedForumItem]
        let postsByID: [UUID: ForumPostItem]
    }

    private struct FollowingSnapshot {
        let cards: [HomeCardItem]
        let followedAuthorIDs: Set<UUID>
        let forumPostsByID: [UUID: ForumPostItem]
        let secondhandItemsByID: [UUID: SecondhandItem]
    }

    /// All content that must move from one coherent Home state to the next.
    /// Loading flags stay outside this value so a background refresh can report
    /// progress without replacing the last valid content snapshot.
    private struct HomeContentSnapshot {
        var featuredSecondhandCards: [HomeCardItem] = []
        var homeFeaturedForumPosts: [HomeFeaturedForumItem] = []
        var forumCards: [HomeCardItem] = []
        var followingCards: [HomeCardItem] = []
        var followedAuthorIDs: Set<UUID> = []
        var forumPostsByID: [UUID: ForumPostItem] = [:]
        var secondhandItemsByID: [UUID: SecondhandItem] = [:]
        var recommendationSessionID: UUID?
        var recommendationPositions: [UUID: Int] = [:]
        var forumPresentation = HomeForumPresentation()
        var forumContinuationCards: [HomeCardItem] = []
        var forumSessionExpiresAt: Date?
        var hasResolvedInitialFeaturedBundleLoad = false
        var hasResolvedInitialForumLoad = false
        var hasResolvedInitialHomeFeaturedLoad = false
        var hasResolvedInitialFollowingLoad = false
        var recommendationSeed: UInt64 = 0xC4EE_5EED
    }

    /// Loading presentation is one coherent value so initial-load transitions do
    /// not publish three independent invalidations to the Home view hierarchy.
    private struct HomeLoadingSnapshot: Equatable {
        var isLoading = false
        var isHomeFeaturedLoading = false
        var isFollowingLoading = false
    }

    // MARK: - Published 属性

    @Published private var contentSnapshot = HomeContentSnapshot()
    @Published private var loadingSnapshot = HomeLoadingSnapshot()
    @Published private(set) var isLoadingMoreForum = false
    @Published private(set) var hasMoreForum = true
    @Published private(set) var forumPaginationError: String?
    @Published private(set) var forumPageNumber = 0
    @Published private(set) var isRefreshingForum = false
    @Published private(set) var forumRefreshError: String?
    @Published private(set) var forumSessionDiagnostics: HomeForumSessionResolution?
    private let lifecycleLogger = Logger(subsystem: "com.timonayf.cheeseapp", category: "ForumLifecycle")
    private var forumContinuationPosition = HomeForumContinuationPosition()
    private var forumPaginationGeneration: UInt64 = 0

    var isHomeFeaturedLoading: Bool {
        loadingSnapshot.isHomeFeaturedLoading
    }

    var isFollowingLoading: Bool {
        loadingSnapshot.isFollowingLoading
    }

    var isLoading: Bool {
        loadingSnapshot.isLoading
    }

    var featuredSecondhandCards: [HomeCardItem] {
        contentSnapshot.featuredSecondhandCards
    }

    var homeFeaturedForumPosts: [HomeFeaturedForumItem] {
        contentSnapshot.homeFeaturedForumPosts
    }

    var forumCards: [HomeCardItem] {
        contentSnapshot.forumCards
    }

    /// The Home Forum tab consumes server-ordered V2 cards, not recommendedCards
    /// (which is the older mixed-content preview). Featured rows are already
    /// checked by the same server eligibility gate in HomeFeedService.
    func forumTabCards(selectedBoardID: UUID?) -> [HomeCardItem] {
        Self.composeForumTabCards(
            featured: homeFeaturedForumCards,
            ranked: forumCards,
            selectedBoardID: selectedBoardID
        )
    }

    static func composeForumTabCards(
        featured: [HomeCardItem], ranked: [HomeCardItem], selectedBoardID: UUID?
    ) -> [HomeCardItem] {
        var seen = Set<UUID>()
        let unique = (featured + ranked).filter { card in
            (selectedBoardID == nil || card.boardID == selectedBoardID)
                && seen.insert(card.postId ?? card.id).inserted
        }
        // Preserve the existing system-pinned placement, then exact RPC order.
        return unique.filter(\.isSystemPinned)
            + unique.filter { !$0.isSystemPinned }
    }

    static func orderForumCards(
        _ cards: [HomeCardItem], sessionID: UUID?, seed: UInt64
    ) -> [HomeCardItem] {
        guard sessionID == nil else { return cards }
        return HomeRecommendationRanker.ranked(cards, seed: seed, limit: cards.count)
    }

    var followingCards: [HomeCardItem] {
        contentSnapshot.followingCards
    }

    var followedAuthorIDs: Set<UUID> {
        contentSnapshot.followedAuthorIDs
    }

    var hasResolvedInitialFeaturedBundleLoad: Bool {
        contentSnapshot.hasResolvedInitialFeaturedBundleLoad
    }

    var hasResolvedInitialForumLoad: Bool {
        contentSnapshot.hasResolvedInitialForumLoad
    }

    var hasResolvedInitialHomeFeaturedLoad: Bool {
        contentSnapshot.hasResolvedInitialHomeFeaturedLoad
    }

    var hasResolvedInitialFollowingLoad: Bool {
        contentSnapshot.hasResolvedInitialFollowingLoad
    }

    var recommendationSeed: UInt64 {
        contentSnapshot.recommendationSeed
    }

    var forumPostsByID: [UUID: ForumPostItem] {
        contentSnapshot.forumPostsByID
    }

    var secondhandItemsByID: [UUID: SecondhandItem] {
        contentSnapshot.secondhandItemsByID
    }

    private let feedService = HomeFeedService.shared
    private let reactionService = PostReactionService.shared
    private let favoriteService = PostFavoriteService.shared
    private let interactionStore = PostInteractionStore.shared
    private let refreshCoordinator = HomeRefreshCoordinator()
    private var accountScopeKey: String?
    private var lastSuccessfulRefreshAt: Date?
    private var pendingLikePostIDs = Set<UUID>()
    private var pendingFavoritePostIDs = Set<UUID>()
    private var followingRequestGeneration: UInt64 = 0
    private static let cacheLifetime: TimeInterval = 5 * 60

    // MARK: - 公开方法

    func loadIfNeeded(
        userID: UUID?,
        now: Date = Date()
    ) async {
        establishAccountScope(for: userID)
        let loadTransition = AuthService.shared.accountTransitionGeneration
        guard let userID,
              await AuthService.shared.prepareAuthenticatedRequest(
                expectedUserID: userID
              ),
              (contentSnapshot.forumSessionExpiresAt.map { $0 <= now } == true || Self.shouldReload(
            hasResolvedData: hasResolvedInitialData,
            lastSuccessfulRefreshAt: lastSuccessfulRefreshAt,
            now: now,
            cacheLifetime: Self.cacheLifetime
        )) else { return }

        guard loadTransition == AuthService.shared.accountTransitionGeneration,
              accountScopeKey == userID.uuidString else { return }
        await refresh(userID: userID, now: now)
    }

    func refresh(
        userID: UUID? = nil,
        now: Date = Date(),
        intent: HomeRefreshIntent = .normal
    ) async {
        establishAccountScope(for: userID)
        let transition = AuthService.shared.accountTransitionGeneration
        guard let userID,
              await AuthService.shared.prepareAuthenticatedRequest(
                expectedUserID: userID
              )
        else { return }
        guard transition == AuthService.shared.accountTransitionGeneration,
              accountScopeKey == userID.uuidString else { return }
        let completed = await refreshCoordinator.run(intent: intent) { [weak self] in
            guard let self else { return false }
            return await self.performRefresh(userID: userID)
        }
        if completed, transition == AuthService.shared.accountTransitionGeneration,
           accountScopeKey == userID.uuidString {
            lastSuccessfulRefreshAt = now
        }
    }

    func cancelPendingRefreshes() {
        refreshCoordinator.cancel()
    }

    var forumFeaturedLoadState: CollectionLoadState {
        CollectionLoadState.resolve(
            hasResolvedInitialLoad: hasResolvedInitialForumLoad,
            isLoading: isLoading,
            hasContent: !forumCards.isEmpty,
            errorMessage: forumRefreshError
        )
    }

    var followingLoadState: CollectionLoadState {
        CollectionLoadState.resolve(
            hasResolvedInitialLoad: hasResolvedInitialFollowingLoad,
            isLoading: isLoading || isFollowingLoading,
            hasContent: !followingCards.isEmpty,
            errorMessage: nil
        )
    }

    var isFollowingAnyone: Bool {
        !followedAuthorIDs.isEmpty
    }

    /// 推荐使用真实互动指标与每次刷新生成的随机种子统一排序。
    /// 系统置顶内容始终位于算法内容之前。
    var recommendedCards: [HomeCardItem] {
        if contentSnapshot.recommendationSessionID != nil {
            var seen = Set<UUID>()
            return Array(
                (homeFeaturedForumCards + forumCards)
                    .filter { seen.insert($0.postId ?? $0.id).inserted }
                    .prefix(12)
            )
        }
        return HomeRecommendationRanker.ranked(
            homeFeaturedForumCards + forumCards + featuredSecondhandCards,
            seed: recommendationSeed,
            limit: 12
        )
    }

    var recommendedLoadState: CollectionLoadState {
        CollectionLoadState.resolve(
            hasResolvedInitialLoad: hasResolvedInitialForumLoad
                && hasResolvedInitialHomeFeaturedLoad
                && hasResolvedInitialFeaturedBundleLoad,
            isLoading: isLoading || isHomeFeaturedLoading,
            hasContent: !recommendedCards.isEmpty,
            errorMessage: nil
        )
    }

    func featuredLoadState(for kind: PostKind) -> CollectionLoadState {
        switch kind {
        case .forum:
            return forumFeaturedLoadState
        case .secondhand:
            return CollectionLoadState.resolve(
                hasResolvedInitialLoad: hasResolvedInitialFeaturedBundleLoad,
                isLoading: isLoading,
                hasContent: !featuredSecondhandCards.isEmpty,
                errorMessage: nil
            )
        }
    }

    func forumPost(id: UUID) -> ForumPostItem? {
        forumPostsByID[id]
    }

    func secondhandItem(id: UUID) -> SecondhandItem? {
        secondhandItemsByID[id]
    }

    func homeCard(id: UUID) -> HomeCardItem? {
        (homeFeaturedForumCards + forumCards + featuredSecondhandCards)
            .first { $0.postId == id }
    }

    func recommendationContext(
        for card: HomeCardItem
    ) -> ForumRecommendationEventContext? {
        guard let postID = card.postId,
              let sessionID = contentSnapshot.recommendationSessionID,
              let position = contentSnapshot.recommendationPositions[postID]
        else { return nil }
        return ForumRecommendationEventContext(
            sessionID: sessionID,
            position: position
        )
    }

    func promoteCreatedPost(kind: PostKind, postID: UUID) async -> Bool {
        do {
            var nextSnapshot = contentSnapshot
            switch kind {
            case .forum:
                let post = try await ForumService.shared.fetchPost(postId: postID)
                nextSnapshot.forumPostsByID[post.id] = post
                nextSnapshot.forumCards.removeAll { $0.postId == post.id }
                nextSnapshot.forumCards.append(makeForumCard(post))
            case .secondhand:
                let item = try await SecondhandService.shared.fetchItem(postId: postID)
                nextSnapshot.secondhandItemsByID[item.id] = item
                nextSnapshot.featuredSecondhandCards.removeAll { $0.postId == item.id }
                nextSnapshot.featuredSecondhandCards.append(makeSecondhandCard(from: item))
                interactionStore.merge(
                    postID: item.id,
                    likeCount: 0,
                    isLiked: false,
                    isFavorited: item.isFavorited
                )
            }
            contentSnapshot = nextSnapshot
            return true
        } catch {
            return false
        }
    }

    func interactionState(for card: HomeCardItem) -> PostInteractionState? {
        guard let postID = card.postId else { return nil }
        return interactionStore.state(
            for: postID,
            fallbackLikeCount: card.likeCount,
            fallbackIsLiked: card.initiallyLiked
        )
    }

    func resetAccountScopedState() {
        resetForumPagination()
        isRefreshingForum = false
        forumRefreshError = nil
        forumSessionDiagnostics = nil
        cancelPendingRefreshes()
        accountScopeKey = nil
        lastSuccessfulRefreshAt = nil
        contentSnapshot = HomeContentSnapshot()
        pendingLikePostIDs = []
        pendingFavoritePostIDs = []
        loadingSnapshot = HomeLoadingSnapshot()
        followingRequestGeneration &+= 1
    }

    func applyFollowChange(targetUserID: UUID, isFollowing: Bool) {
        var nextSnapshot = contentSnapshot
        if isFollowing {
            nextSnapshot.followedAuthorIDs.insert(targetUserID)
        } else {
            nextSnapshot.followedAuthorIDs.remove(targetUserID)
            nextSnapshot.followingCards.removeAll { $0.authorId == targetUserID }
        }
        contentSnapshot = nextSnapshot
    }

    func refreshFollowing(userID: UUID?) async {
        establishAccountScope(for: userID)
        guard let userID,
              await AuthService.shared.prepareAuthenticatedRequest(
                expectedUserID: userID
              )
        else { return }

        followingRequestGeneration &+= 1
        let requestGeneration = followingRequestGeneration
        let requestScopeKey = accountScopeKey
        loadingSnapshot.isFollowingLoading = true
        defer {
            if requestGeneration == followingRequestGeneration,
               requestScopeKey == accountScopeKey {
                loadingSnapshot.isFollowingLoading = false
            }
        }

        guard let snapshot = await fetchFollowingSnapshot(
                userID: userID,
                expectedUserID: userID
              ),
              !Task.isCancelled,
              requestGeneration == followingRequestGeneration,
              requestScopeKey == accountScopeKey,
              AuthService.shared.isAuthenticatedRequestReady(for: userID)
        else { return }

        let interactionUpdates = await fetchPostInteractionUpdates(
            for: forumCards
                + homeFeaturedForumCards
                + featuredSecondhandCards
                + snapshot.cards
        )
        guard !Task.isCancelled,
              requestGeneration == followingRequestGeneration,
              requestScopeKey == accountScopeKey
        else { return }

        var nextSnapshot = contentSnapshot
        nextSnapshot.forumPostsByID.merge(
            snapshot.forumPostsByID,
            uniquingKeysWith: { _, refreshed in refreshed }
        )
        nextSnapshot.secondhandItemsByID.merge(
            snapshot.secondhandItemsByID,
            uniquingKeysWith: { _, refreshed in refreshed }
        )
        nextSnapshot.followedAuthorIDs = snapshot.followedAuthorIDs
        nextSnapshot.followingCards = snapshot.cards
        nextSnapshot.hasResolvedInitialFollowingLoad = true
        interactionStore.mergeServerSnapshots(interactionUpdates)
        contentSnapshot = nextSnapshot
    }

    func toggleLike(for card: HomeCardItem) async throws {
        guard card.category != .secondhand,
              let postID = card.postId,
              pendingLikePostIDs.insert(postID).inserted
        else { return }
        defer { pendingLikePostIDs.remove(postID) }

        let previous = interactionState(for: card) ?? PostInteractionState(
            likeCount: card.likeCount,
            isLiked: card.initiallyLiked,
            isFavorited: false
        )
        let optimisticLiked = !previous.isLiked
        guard interactionStore.beginLikeMutation(
            postID: postID,
            desiredIsLiked: optimisticLiked
        ) else { return }
        interactionStore.replace(postID: postID, with: PostInteractionState(
            likeCount: max(previous.likeCount + (optimisticLiked ? 1 : -1), 0),
            isLiked: optimisticLiked,
            isFavorited: previous.isFavorited
        ))

        do {
            let confirmedLiked = try await reactionService.toggle(
                postId: postID,
                currentlyLiked: previous.isLiked
            )
            var confirmed = interactionStore.state(
                for: postID,
                fallbackLikeCount: previous.likeCount,
                fallbackIsLiked: previous.isLiked,
                fallbackIsFavorited: previous.isFavorited
            )
            confirmed.isLiked = confirmedLiked
            interactionStore.replace(postID: postID, with: confirmed)
            interactionStore.finishLikeMutation(
                postID: postID,
                committedIsLiked: confirmedLiked
            )
            if let context = recommendationContext(for: card) {
                await ForumService.shared.recordRecommendationEvent(
                    postID: postID,
                    type: confirmedLiked ? .like : .unlike,
                    context: context
                )
            }
        } catch {
            interactionStore.replace(postID: postID, with: previous)
            interactionStore.finishLikeMutation(
                postID: postID,
                committedIsLiked: nil
            )
            throw error
        }
    }

    func toggleFavorite(for card: HomeCardItem) async throws {
        guard let postID = card.postId,
              pendingFavoritePostIDs.insert(postID).inserted
        else { return }
        defer { pendingFavoritePostIDs.remove(postID) }

        let previous = interactionState(for: card) ?? PostInteractionState(
            likeCount: card.likeCount,
            isLiked: card.initiallyLiked,
            isFavorited: false
        )
        interactionStore.replace(postID: postID, with: PostInteractionState(
            likeCount: previous.likeCount,
            isLiked: previous.isLiked,
            isFavorited: !previous.isFavorited
        ))

        do {
            let confirmedFavorited = try await favoriteService.toggleFavorite(
                postId: postID,
                currentlyFavorited: previous.isFavorited
            )
            var confirmed = interactionStore.state(
                for: postID,
                fallbackLikeCount: previous.likeCount,
                fallbackIsLiked: previous.isLiked,
                fallbackIsFavorited: previous.isFavorited
            )
            confirmed.isFavorited = confirmedFavorited
            interactionStore.replace(postID: postID, with: confirmed)
            if card.category == .forum,
               let context = recommendationContext(for: card) {
                await ForumService.shared.recordRecommendationEvent(
                    postID: postID,
                    type: confirmedFavorited ? .save : .unsave,
                    context: context
                )
            }
        } catch {
            interactionStore.replace(postID: postID, with: previous)
            throw error
        }
    }

    // MARK: - 私有方法

    private func resetForumPagination(sessionID: UUID? = nil) {
        forumPaginationGeneration &+= 1
        forumContinuationPosition = HomeForumContinuationPosition(sessionID: sessionID)
        forumPageNumber = 0
        hasMoreForum = true
        isLoadingMoreForum = false
        forumPaginationError = nil
    }

    func loadMoreForum(userID: UUID?) async {
        guard let userID, hasResolvedInitialForumLoad, hasMoreForum,
              !isLoadingMoreForum, !isRefreshingForum,
              accountScopeKey == userID.uuidString else { return }
        if contentSnapshot.forumSessionExpiresAt.map({ $0 <= Date() }) == true {
            await refresh(userID: userID)
            return
        }
        let generation = forumPaginationGeneration
        let transition = AuthService.shared.accountTransitionGeneration
        isLoadingMoreForum = true
        forumPaginationError = nil
        defer {
            if generation == forumPaginationGeneration { isLoadingMoreForum = false }
        }
        // Fixed exclusion set: all initial recommendations were fetched (up to
        // the session's 60 rows). Continuation uses a keyset, never a growing offset.
        if forumContinuationPosition.exclusions == nil {
            forumContinuationPosition.exclusions = Array(Set((forumCards + homeFeaturedForumCards).compactMap(\.postId)))
        }
        do {
            let references = try await feedService.fetchForumContinuation(
                excluding: forumContinuationPosition.exclusions ?? [], before: forumContinuationPosition.cursor)
            let posts = try await ForumService.shared.fetchPosts(postIDs: references.map(\.post_id))
            let postsByID = Dictionary(posts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let cards = references.compactMap { postsByID[$0.post_id].map { makeForumCard($0) } }
            let interactions = await fetchPostInteractionUpdates(for: cards)
            guard !Task.isCancelled, generation == forumPaginationGeneration,
                  transition == AuthService.shared.accountTransitionGeneration,
                  accountScopeKey == userID.uuidString,
                  AuthService.shared.isAuthenticatedRequestReady(for: userID) else { return }
            var next = contentSnapshot
            let unseen = HomeForumContinuationPosition.unseen(
                cards.compactMap(\.postId),
                after: (next.forumCards + homeFeaturedForumCards).compactMap(\.postId))
            let cardsByID = Dictionary(cards.map { ($0.postId ?? $0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
            let appended = unseen.compactMap { cardsByID[$0] }
            next.forumCards += appended
            next.forumContinuationCards += appended
            next.forumPostsByID.merge(postsByID, uniquingKeysWith: { _, new in new })
            contentSnapshot = next
            interactionStore.mergeServerSnapshots(interactions)
            // Advance from raw RPC rows, including rows removed during hydration.
            forumContinuationPosition.cursor = references.last ?? forumContinuationPosition.cursor
            hasMoreForum = references.count == 20
            forumPageNumber += 1
        } catch {
            guard generation == forumPaginationGeneration,
                  accountScopeKey == userID.uuidString else { return }
            forumPaginationError = L10n.tr("Couldn’t load more posts. Tap to retry.", "加载失败，点击重试")
        }
    }

    private var hasResolvedInitialData: Bool {
        hasResolvedInitialFeaturedBundleLoad
            && hasResolvedInitialForumLoad
            && hasResolvedInitialHomeFeaturedLoad
            && hasResolvedInitialFollowingLoad
    }

    static func shouldReload(
        hasResolvedData: Bool,
        lastSuccessfulRefreshAt: Date?,
        now: Date,
        cacheLifetime: TimeInterval = 5 * 60
    ) -> Bool {
        guard hasResolvedData, let lastSuccessfulRefreshAt else { return true }
        return now.timeIntervalSince(lastSuccessfulRefreshAt) >= cacheLifetime
    }

    static func shouldPublishInitialLoading(hasResolvedData: Bool) -> Bool {
        !hasResolvedData
    }

    private func establishAccountScope(for userID: UUID?) {
        let newScopeKey = userID?.uuidString ?? "signed-out"
        guard accountScopeKey != newScopeKey else { return }
        resetAccountScopedState()
        accountScopeKey = newScopeKey
    }

    private func performRefresh(userID: UUID) async -> Bool {
        let accountTransitionGeneration = AuthService.shared.accountTransitionGeneration
        // Invalidate in-flight append requests before replacing a feed snapshot.
        forumPaginationGeneration &+= 1
        isLoadingMoreForum = false
        isRefreshingForum = true
        defer {
            if accountScopeKey == userID.uuidString,
               accountTransitionGeneration == AuthService.shared.accountTransitionGeneration,
               !Task.isCancelled { isRefreshingForum = false }
        }
        guard await AuthService.shared.prepareAuthenticatedRequest(
            expectedUserID: userID
        ), !Task.isCancelled,
           accountTransitionGeneration == AuthService.shared.accountTransitionGeneration,
           accountScopeKey == userID.uuidString else { return false }

        followingRequestGeneration &+= 1
        let requestGeneration = followingRequestGeneration
        let requestScopeKey = accountScopeKey
        let shouldPublishInitialLoading = Self.shouldPublishInitialLoading(
            hasResolvedData: hasResolvedInitialData
        )
        if shouldPublishInitialLoading {
            loadingSnapshot = HomeLoadingSnapshot(
                isLoading: true,
                isHomeFeaturedLoading: true,
                isFollowingLoading: true
            )
        }
        defer {
            if shouldPublishInitialLoading,
               requestGeneration == followingRequestGeneration,
               requestScopeKey == accountScopeKey {
                loadingSnapshot = HomeLoadingSnapshot()
            }
        }

        async let featuredTask = fetchFeaturedSnapshot(expectedUserID: userID)
        async let forumTask = fetchForumSnapshot(expectedUserID: userID)
        async let homeFeaturedTask = fetchHomeFeaturedSnapshot(expectedUserID: userID)
        async let followingTask = fetchFollowingSnapshot(
            userID: userID,
            expectedUserID: userID
        )
        let (featured, forum, homeFeatured, following) = await (
            featuredTask,
            forumTask,
            homeFeaturedTask,
            followingTask
        )
        guard !Task.isCancelled,
              requestGeneration == followingRequestGeneration,
              requestScopeKey == accountScopeKey,
              accountTransitionGeneration == AuthService.shared.accountTransitionGeneration,
              AuthService.shared.isAuthenticatedRequestReady(for: userID)
        else { return false }
        guard featured != nil || forum != nil || homeFeatured != nil || following != nil else {
            forumRefreshError = L10n.tr("Couldn’t refresh Forum. Pull to retry.", "论坛刷新失败，请下拉重试")
            return false
        }

        let nextSeed = recommendationSeed &+ 0x9E37_79B9_7F4A_7C15
        let forumSourceCards = forum?.cards ?? forumCards
        // A failed forum refresh retains BOTH the prior cards and their session.
        // It must not send a cached V2 sequence through the legacy random ranker.
        let nextForumSessionID = forum != nil
            ? forum?.recommendationSessionID
            : contentSnapshot.recommendationSessionID
        var nextForumCards = Self.orderForumCards(
            forumSourceCards, sessionID: nextForumSessionID, seed: nextSeed ^ 0xF04D_F04D
        )
        let nextSecondhandCards = HomeRecommendationRanker.ranked(
            featured?.cards ?? featuredSecondhandCards,
            seed: nextSeed ^ 0x5EC0_0DAD,
            limit: (featured?.cards ?? featuredSecondhandCards).count
        )
        let nextHomeFeaturedItems = homeFeatured?.items ?? homeFeaturedForumPosts
        let nextFollowingCards = following?.cards ?? followingCards
        let nextHomeFeaturedCards = nextHomeFeaturedItems.map {
            makeForumCard(
                $0.post,
                badge: $0.badgeText,
                isSystemPinned: true
            )
        }
        // Validate cached browsing rows without changing their chronological order
        // or cursor. A validation error keeps the whole prior Forum snapshot.
        var retainedContinuation: [HomeCardItem] = []
        var canCommitForum = forum != nil
        if let forum, forum.recommendationSessionID == contentSnapshot.recommendationSessionID {
            do {
                let allowed = try await feedService.validateForumPosts(contentSnapshot.forumContinuationCards.compactMap(\.postId))
                retainedContinuation = contentSnapshot.forumContinuationCards.filter { allowed.contains($0.postId ?? $0.id) }
            } catch { canCommitForum = false }
        }
        let interactionUpdates = await fetchPostInteractionUpdates(
            for: nextForumCards
                + nextHomeFeaturedCards
                + nextSecondhandCards
                + nextFollowingCards
        )
        guard !Task.isCancelled,
              requestGeneration == followingRequestGeneration,
              requestScopeKey == accountScopeKey,
              accountTransitionGeneration == AuthService.shared.accountTransitionGeneration,
              AuthService.shared.isAuthenticatedRequestReady(for: userID)
        else { return false }

        var nextSnapshot = contentSnapshot
        if let forum, canCommitForum {
            let changedSession = forum.recommendationSessionID != contentSnapshot.recommendationSessionID
            if forumContinuationPosition.resolve(session: forum.recommendationSessionID) {
                resetForumPagination(sessionID: forum.recommendationSessionID)
                retainedContinuation = []
            }
            if let sessionID = forum.recommendationSessionID {
                let priorGeneration = nextSnapshot.forumPresentation.generation
                nextSnapshot.forumPresentation.resolve(account: userID, session: sessionID,
                    candidates: forum.cards.compactMap(\.postId),
                    featured: Set(nextHomeFeaturedCards.compactMap(\.postId)),
                    intent: refreshCoordinator.explicitPullRequested ? .explicitPull : .normal)
                let byID = Dictionary(uniqueKeysWithValues: forum.cards.map { ($0.postId ?? $0.id, $0) })
                let presented = nextSnapshot.forumPresentation.orderedIDs.compactMap { byID[$0] }
                let ids = Set(presented.compactMap(\.postId))
                retainedContinuation.removeAll { ids.contains($0.postId ?? $0.id) }
                nextForumCards = presented + retainedContinuation
                let generation = nextSnapshot.forumPresentation.generation
                let tiers = nextSnapshot.forumPresentation.tierCounts.map(String.init).joined(separator: ",")
                let rotated = !changedSession && generation > priorGeneration
                lifecycleLogger.info("session=\(sessionID.uuidString, privacy: .public) reused=\(forum.resolution?.reused ?? false) reason=\(forum.resolution?.reason ?? "unknown", privacy: .public) refresh_generation=\(generation) rotation_applied=\(rotated) tiers=\(tiers, privacy: .public)")
            } else {
                nextSnapshot.forumPresentation = HomeForumPresentation()
            }
            nextSnapshot.forumContinuationCards = retainedContinuation
            nextSnapshot.forumSessionExpiresAt = forum.resolution?.expires_at
            forumSessionDiagnostics = forum.resolution
            forumRefreshError = nil
            nextSnapshot.forumPostsByID.merge(
                forum.postsByID,
                uniquingKeysWith: { _, refreshed in refreshed }
            )
            nextSnapshot.recommendationSessionID = forum.recommendationSessionID
            nextSnapshot.recommendationPositions = forum.recommendationPositions
            ForumService.shared.registerRecommendationContexts(
                sessionID: forum.recommendationSessionID,
                positions: forum.recommendationPositions
            )
        } else {
            nextForumCards = forumCards
            forumRefreshError = L10n.tr("Couldn’t refresh Forum. Pull to retry.", "论坛刷新失败，请下拉重试")
        }
        if let homeFeatured {
            nextSnapshot.forumPostsByID.merge(
                homeFeatured.postsByID,
                uniquingKeysWith: { _, refreshed in refreshed }
            )
        }
        if let featured {
            nextSnapshot.secondhandItemsByID.merge(
                featured.itemsByID,
                uniquingKeysWith: { _, refreshed in refreshed }
            )
        }
        if let following {
            nextSnapshot.forumPostsByID.merge(
                following.forumPostsByID,
                uniquingKeysWith: { _, refreshed in refreshed }
            )
            nextSnapshot.secondhandItemsByID.merge(
                following.secondhandItemsByID,
                uniquingKeysWith: { _, refreshed in refreshed }
            )
        }

        nextSnapshot.recommendationSeed = nextSeed
        nextSnapshot.forumCards = nextForumCards
        nextSnapshot.homeFeaturedForumPosts = nextHomeFeaturedItems
        nextSnapshot.featuredSecondhandCards = nextSecondhandCards
        nextSnapshot.followingCards = nextFollowingCards
        if let following {
            nextSnapshot.followedAuthorIDs = following.followedAuthorIDs
        }
        nextSnapshot.hasResolvedInitialFeaturedBundleLoad = true
        nextSnapshot.hasResolvedInitialForumLoad = canCommitForum || contentSnapshot.hasResolvedInitialForumLoad
        nextSnapshot.hasResolvedInitialHomeFeaturedLoad = true
        nextSnapshot.hasResolvedInitialFollowingLoad = true
        var commitTransaction = Transaction()
        commitTransaction.disablesAnimations = true
        withTransaction(commitTransaction) {
            interactionStore.mergeServerSnapshots(interactionUpdates)
            contentSnapshot = nextSnapshot
        }
        return true
    }

    private func fetchPostInteractionUpdates(
        for cards: [HomeCardItem]
    ) async -> [PostInteractionStore.Update] {
        let uniqueCards = cards.reduce(into: [UUID: HomeCardItem]()) { result, card in
            guard let postID = card.postId else { return }
            if let current = result[postID], current.likeCount > card.likeCount {
                return
            }
            result[postID] = card
        }
        let postIDs = Array(uniqueCards.keys)
        guard !postIDs.isEmpty else { return [] }

        let likeablePostIDs = uniqueCards.compactMap { postID, card in
            card.category == .secondhand ? nil : postID
        }
        async let reactions = reactionService.fetchStates(postIds: likeablePostIDs)
        async let favorites = favoriteService.fetchFavoritePostIds(postIds: postIDs)
        let (reactionStates, favoriteIDs) = await (reactions, favorites)
        guard !Task.isCancelled else { return [] }

        return uniqueCards.map { postID, card in
            let isLikePending = pendingLikePostIDs.contains(postID)
            let isFavoritePending = pendingFavoritePostIDs.contains(postID)
            return PostInteractionStore.Update(
                postID: postID,
                likeCount: isLikePending
                    ? nil
                    : (card.category == .secondhand ? 0 : card.likeCount),
                isLiked: isLikePending
                    ? nil
                    : (card.category == .secondhand
                        ? false
                        : (reactionStates[postID]?.isLiked ?? card.initiallyLiked)),
                isFavorited: isFavoritePending ? nil : favoriteIDs.contains(postID)
            )
        }
    }

    private func fetchHomeFeaturedSnapshot(
        expectedUserID: UUID
    ) async -> HomeFeaturedSnapshot? {
        do {
            return try await withAuthenticatedRetry(expectedUserID: expectedUserID) {
                let configurations = try await self.feedService.fetchHomeFeaturedPosts()
                let posts = try await ForumService.shared.fetchPosts(
                    postIDs: configurations.map(\.postID)
                )
                try Task.checkCancellation()
                let postsByID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
                return HomeFeaturedSnapshot(
                    items: HomeFeaturedForumItem.resolve(
                        configurations: configurations,
                        postsByID: postsByID
                    ),
                    postsByID: postsByID
                )
            }
        } catch {
            return nil
        }
    }

    private func fetchFeaturedSnapshot(
        expectedUserID: UUID
    ) async -> FeaturedSnapshot? {
        do {
            return try await withAuthenticatedRetry(expectedUserID: expectedUserID) {
                let bundle = try await self.feedService.fetchFeaturedBundle(secondhandLimit: 36)
                try Task.checkCancellation()
                let secondhandItems = await SecondhandService.shared.resolveItems(
                    from: bundle.secondhandRows,
                    seedInteractions: false
                )
                try Task.checkCancellation()
                let itemsByID = Dictionary(
                    uniqueKeysWithValues: secondhandItems.map { ($0.id, $0) }
                )
                return FeaturedSnapshot(
                    cards: bundle.secondhandPosts
                        .filter { itemsByID[$0.id] != nil }
                        .map(self.makeSecondhandCard),
                    itemsByID: itemsByID
                )
            }
        } catch {
            return nil
        }
    }

    private func fetchForumSnapshot(
        expectedUserID: UUID
    ) async -> ForumSnapshot? {
        do {
            return try await withAuthenticatedRetry(expectedUserID: expectedUserID) {
                // An RPC failure must not bypass V2 eligibility through legacy
                // fetching. Only an explicit server-off response returns nil.
                let recommendation = try await self.feedService
                    .resolveRecommendationForumPreview()
                let previews: [HomeForumPreview]
                let sessionID: UUID?
                let positions: [UUID: Int]
                if let recommendation {
                    previews = recommendation.posts
                    sessionID = recommendation.sessionID
                    positions = recommendation.positions
                } else {
                    previews = try await self.feedService.fetchForumPreview(limit: 36)
                    sessionID = nil
                    positions = [:]
                }
                let posts = try await ForumService.shared.fetchPosts(
                    postIDs: previews.map(\.id)
                )
                try Task.checkCancellation()
                let postsByID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
                return ForumSnapshot(
                    cards: previews.compactMap { preview in
                        postsByID[preview.id].map { post in
                            self.makeForumCard(post, saveCount: preview.saveCount)
                        }
                    },
                    postsByID: postsByID,
                    recommendationSessionID: sessionID,
                    recommendationPositions: positions,
                    resolution: recommendation?.resolution
                )
            }
        } catch {
            return nil
        }
    }

    private func fetchFollowingSnapshot(
        userID: UUID,
        expectedUserID: UUID
    ) async -> FollowingSnapshot? {
        do {
            return try await withAuthenticatedRetry(expectedUserID: expectedUserID) {
                let bundle = try await self.feedService.fetchFollowingFeed(userID: userID)
                async let forumPosts = ForumService.shared.fetchPosts(
                    postIDs: bundle.forumPosts.map(\.id)
                )
                async let secondhandItems = SecondhandService.shared.resolveItems(
                    from: bundle.secondhandRows,
                    seedInteractions: false
                )
                let (resolvedForumPosts, resolvedSecondhandItems) = try await (
                    forumPosts,
                    secondhandItems
                )
                try Task.checkCancellation()

                let forumPostsByID = Dictionary(
                    uniqueKeysWithValues: resolvedForumPosts.map { ($0.id, $0) }
                )
                let secondhandItemsByID = Dictionary(
                    uniqueKeysWithValues: resolvedSecondhandItems.map { ($0.id, $0) }
                )
                let forumEntries: [(card: HomeCardItem, createdAt: Date)] = bundle.forumPosts.compactMap { preview in
                    forumPostsByID[preview.id].map {
                        (card: self.makeForumCard($0), createdAt: preview.createdAt)
                    }
                }
                let secondhandEntries: [(card: HomeCardItem, createdAt: Date)] = bundle.secondhandPosts.compactMap { preview in
                    guard secondhandItemsByID[preview.id] != nil else { return nil }
                    return (card: self.makeSecondhandCard(from: preview), createdAt: preview.createdAt)
                }
                return FollowingSnapshot(
                    cards: (forumEntries + secondhandEntries)
                        .sorted { lhs, rhs in
                            if lhs.createdAt != rhs.createdAt {
                                return lhs.createdAt > rhs.createdAt
                            }
                            return lhs.card.id.uuidString > rhs.card.id.uuidString
                        }
                        .map(\.card),
                    followedAuthorIDs: bundle.followedAuthorIDs,
                    forumPostsByID: forumPostsByID,
                    secondhandItemsByID: secondhandItemsByID
                )
            }
        } catch {
            return nil
        }
    }

    private func withAuthenticatedRetry<T>(
        expectedUserID: UUID,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        guard await AuthService.shared.prepareAuthenticatedRequest(
            expectedUserID: expectedUserID
        ) else {
            throw CancellationError()
        }

        do {
            return try await operation()
        } catch {
            guard !Task.isCancelled,
                  HomeFeedAuthFailurePolicy.shouldRetry(error),
                  await AuthService.shared.recoverAuthenticatedRequest(
                    expectedUserID: expectedUserID
                  )
            else {
                throw error
            }
            return try await operation()
        }
    }

    private func makeSecondhandCard(from post: HomeFeaturedSecondhandPost) -> HomeCardItem {
        let avatar: ImageSource = {
            guard !post.isAnonymous else { return .placeholder }
            guard let userAvatar = post.userAvatar,
                  let url = URL(string: userAvatar)
            else {
                return .placeholder
            }
            return .url(url)
        }()
        return HomeCardItem(
            postId: post.id,
            authorId: post.isAnonymous ? nil : post.userId,
            image: {
                guard let url = SupabasePublicImageURLResolver.url(
                    fromStoredURL: post.images.first?.url,
                    purpose: .feedThumbnail
                )
                else {
                    return .placeholder
                }
                return .url(url)
            }(),
            images: post.images.first
                .flatMap {
                    SupabasePublicImageURLResolver.url(
                        fromStoredURL: $0.url,
                        purpose: .feedThumbnail
                    )
                }
                .map { [.url($0)] } ?? [],
            originalImageURLs: post.images.first
                .flatMap { URL(string: $0.url) }
                .map { [$0] } ?? [],
            title: post.title,
            subtitle: "",
            footer: .posted(
                name: post.isAnonymous
                    ? L10n.tr("Anonymous seller", "匿名卖家")
                    : post.userName ?? L10n.tr("Unavailable user", "用户资料不可用"),
                avatar: avatar
            ),
            isAnonymous: post.isAnonymous,
            isAuthorMcMasterVerified: post.isUserMcMasterVerified,
            category: .secondhand,
            viewCount: post.viewCount,
            createdAt: post.createdAt,
            priceText: formattedPrice(post.price),
            originalPriceText: post.originalPrice.flatMap { price in
                price > 0 ? formattedPrice(price) : nil
            },
            likeCount: post.likeCount,
            saveCount: post.saveCount
        )
    }

    private func makeSecondhandCard(from item: SecondhandItem) -> HomeCardItem {
        let avatar = item.isAnonymous
            ? ImageSource.placeholder
            : item.sellerAvatar.flatMap(URL.init(string:)).map(ImageSource.url) ?? .placeholder

        return HomeCardItem(
            postId: item.id,
            authorId: item.isAnonymous ? nil : item.sellerId,
            image: item.feedThumbnailURL
                .map(ImageSource.url) ?? .placeholder,
            images: item.feedThumbnailURL.map { [.url($0)] } ?? [],
            originalImageURLs: item.displayImageUrls.first
                .flatMap(URL.init(string:))
                .map { [$0] } ?? [],
            title: item.title,
            subtitle: item.description,
            footer: .posted(name: item.seller, avatar: avatar),
            isAnonymous: item.isAnonymous,
            isAuthorMcMasterVerified: !item.isAnonymous && item.isSellerMcMasterVerified,
            category: .secondhand,
            timeText: item.timeAgo,
            createdAt: Date(),
            priceText: formattedPrice(item.price),
            originalPriceText: item.originalPrice.flatMap {
                $0 > 0 ? formattedPrice($0) : nil
            }
        )
    }

    var homeFeaturedForumCards: [HomeCardItem] {
        homeFeaturedForumPosts.map { item in
            makeForumCard(
                item.post,
                badge: item.badgeText,
                isSystemPinned: true
            )
        }
    }

    private func makeForumCard(
        _ post: ForumPostItem,
        badge: String? = nil,
        saveCount: Int = 0,
        isSystemPinned: Bool = false
    ) -> HomeCardItem {
        let avatar = post.isAnonymous
            ? ImageSource.placeholder
            : post.authorAvatar
                .flatMap(URL.init(string:))
                .map(ImageSource.url) ?? .placeholder

        return HomeCardItem(
            postId: post.id,
            authorId: post.isAnonymous ? nil : post.authorId,
            image: post.imageUrls.first
                .flatMap(URL.init(string:))
                .map(ImageSource.url) ?? .placeholder,
            images: post.imageUrls
                .compactMap(URL.init(string:))
                .map(ImageSource.url),
            title: post.title,
            subtitle: post.content,
            footer: .posted(name: post.authorName, avatar: avatar),
            isAnonymous: post.isAnonymous,
            isAuthorOfficial: !post.isAnonymous && post.isAuthorOfficial,
            isAuthorMcMasterVerified: !post.isAnonymous && post.isAuthorMcMasterVerified,
            category: .forum,
            viewCount: post.views,
            badgeText: badge ?? post.boardName,
            boardID: post.boardID,
            boardIcon: post.boardIcon,
            timeText: post.timeAgo,
            likeCount: post.likes,
            commentCount: post.comments,
            saveCount: saveCount,
            isSystemPinned: isSystemPinned || post.isPinned,
            initiallyLiked: post.isLiked
        )
    }

    private func shouldIgnore(_ error: Error) -> Bool {
        error.isCancellationLike
    }

    private func formattedPrice(_ price: Double) -> String {
        if abs(price - price.rounded()) < 0.01 {
            return "CAD \(Int(price.rounded()))"
        }
        return String(format: "CAD %.2f", price)
    }

}
