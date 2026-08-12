//
//  HomeViewModel.swift
//  CheeseApp
//
//  首页数据状态与刷新编排
//

import SwiftUI

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
    private var activeRefreshTask: Task<Bool, Never>?
    private var activeRefreshID: UUID?
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
        guard Self.shouldReload(
            hasResolvedData: hasResolvedInitialData,
            lastSuccessfulRefreshAt: lastSuccessfulRefreshAt,
            now: now,
            cacheLifetime: Self.cacheLifetime
        ) else { return }

        await refresh(userID: userID, now: now)
    }

    func refresh(
        userID: UUID? = nil,
        now: Date = Date()
    ) async {
        establishAccountScope(for: userID)
        if let activeRefreshTask {
            _ = await activeRefreshTask.value
            return
        }

        let refreshID = UUID()
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performRefresh(userID: userID)
        }
        activeRefreshID = refreshID
        activeRefreshTask = task
        let completed = await task.value

        if activeRefreshID == refreshID {
            activeRefreshTask = nil
            activeRefreshID = nil
            if completed {
                lastSuccessfulRefreshAt = now
            }
        }
    }

    func cancelPendingRefreshes() {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        activeRefreshID = nil
    }

    var forumFeaturedLoadState: CollectionLoadState {
        CollectionLoadState.resolve(
            hasResolvedInitialLoad: hasResolvedInitialForumLoad,
            isLoading: isLoading,
            hasContent: !forumCards.isEmpty,
            errorMessage: nil
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
        HomeRecommendationRanker.ranked(
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

        guard let snapshot = await fetchFollowingSnapshot(userID: userID),
              !Task.isCancelled,
              requestGeneration == followingRequestGeneration,
              requestScopeKey == accountScopeKey
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
        interactionStore.merge(interactionUpdates)
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
        } catch {
            interactionStore.replace(postID: postID, with: previous)
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
        } catch {
            interactionStore.replace(postID: postID, with: previous)
            throw error
        }
    }

    // MARK: - 私有方法

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

    private func performRefresh(userID: UUID?) async -> Bool {
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

        async let featuredTask = fetchFeaturedSnapshot()
        async let forumTask = fetchForumSnapshot()
        async let homeFeaturedTask = fetchHomeFeaturedSnapshot()
        async let followingTask = fetchFollowingSnapshot(userID: userID)
        let (featured, forum, homeFeatured, following) = await (
            featuredTask,
            forumTask,
            homeFeaturedTask,
            followingTask
        )
        guard !Task.isCancelled,
              requestGeneration == followingRequestGeneration,
              requestScopeKey == accountScopeKey
        else { return false }
        guard featured != nil || forum != nil || homeFeatured != nil || following != nil else {
            return false
        }

        let nextSeed = recommendationSeed &+ 0x9E37_79B9_7F4A_7C15
        let nextForumCards = HomeRecommendationRanker.ranked(
            forum?.cards ?? forumCards,
            seed: nextSeed ^ 0xF04D_F04D,
            limit: (forum?.cards ?? forumCards).count
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
        let interactionUpdates = await fetchPostInteractionUpdates(
            for: nextForumCards
                + nextHomeFeaturedCards
                + nextSecondhandCards
                + nextFollowingCards
        )
        guard !Task.isCancelled,
              requestGeneration == followingRequestGeneration,
              requestScopeKey == accountScopeKey
        else { return false }

        var nextSnapshot = contentSnapshot
        if let forum {
            nextSnapshot.forumPostsByID.merge(
                forum.postsByID,
                uniquingKeysWith: { _, refreshed in refreshed }
            )
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
        nextSnapshot.hasResolvedInitialForumLoad = true
        nextSnapshot.hasResolvedInitialHomeFeaturedLoad = true
        nextSnapshot.hasResolvedInitialFollowingLoad = true
        var commitTransaction = Transaction()
        commitTransaction.disablesAnimations = true
        withTransaction(commitTransaction) {
            interactionStore.merge(interactionUpdates)
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

    private func fetchHomeFeaturedSnapshot() async -> HomeFeaturedSnapshot? {
        do {
            let configurations = try await feedService.fetchHomeFeaturedPosts()
            let posts = try await ForumService.shared.fetchPosts(
                postIDs: configurations.map(\.postID)
            )
            guard !Task.isCancelled else { return nil }
            let postsByID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
            return HomeFeaturedSnapshot(
                items: HomeFeaturedForumItem.resolve(
                    configurations: configurations,
                    postsByID: postsByID
                ),
                postsByID: postsByID
            )
        } catch {
            return nil
        }
    }

    private func fetchFeaturedSnapshot() async -> FeaturedSnapshot? {
        do {
            let bundle = try await feedService.fetchFeaturedBundle(secondhandLimit: 36)
            guard !Task.isCancelled else { return nil }
            let secondhandItems = await SecondhandService.shared.resolveItems(
                from: bundle.secondhandRows,
                seedInteractions: false
            )
            guard !Task.isCancelled else { return nil }
            let itemsByID = Dictionary(
                uniqueKeysWithValues: secondhandItems.map { ($0.id, $0) }
            )
            return FeaturedSnapshot(
                cards: bundle.secondhandPosts
                    .filter { itemsByID[$0.id] != nil }
                    .map(makeSecondhandCard),
                itemsByID: itemsByID
            )
        } catch {
            return nil
        }
    }

    private func fetchForumSnapshot() async -> ForumSnapshot? {
        do {
            let previews = try await feedService.fetchForumPreview(limit: 36)
            let posts = try await ForumService.shared.fetchPosts(
                postIDs: previews.map(\.id)
            )
            guard !Task.isCancelled else { return nil }
            let postsByID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
            return ForumSnapshot(
                cards: previews.compactMap { preview in
                    postsByID[preview.id].map { post in
                        makeForumCard(post, saveCount: preview.saveCount)
                    }
                },
                postsByID: postsByID
            )
        } catch {
            return nil
        }
    }

    private func fetchFollowingSnapshot(userID: UUID?) async -> FollowingSnapshot? {
        guard let userID else {
            return FollowingSnapshot(
                cards: [],
                followedAuthorIDs: [],
                forumPostsByID: [:],
                secondhandItemsByID: [:]
            )
        }

        do {
            let bundle = try await feedService.fetchFollowingFeed(userID: userID)
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
            guard !Task.isCancelled else { return nil }

            let forumPostsByID = Dictionary(
                uniqueKeysWithValues: resolvedForumPosts.map { ($0.id, $0) }
            )
            let secondhandItemsByID = Dictionary(
                uniqueKeysWithValues: resolvedSecondhandItems.map { ($0.id, $0) }
            )
            let forumEntries: [(card: HomeCardItem, createdAt: Date)] = bundle.forumPosts.compactMap { preview in
                forumPostsByID[preview.id].map {
                    (card: makeForumCard($0), createdAt: preview.createdAt)
                }
            }
            let secondhandEntries: [(card: HomeCardItem, createdAt: Date)] = bundle.secondhandPosts.compactMap { preview in
                guard secondhandItemsByID[preview.id] != nil else { return nil }
                return (card: makeSecondhandCard(from: preview), createdAt: preview.createdAt)
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
        } catch {
            return nil
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
                guard let imageURL = post.images.first?.url,
                      let url = URL(string: imageURL)
                else {
                    return .placeholder
                }
                return .url(url)
            }(),
            title: post.title,
            subtitle: "",
            footer: .posted(
                name: post.isAnonymous
                    ? L10n.tr("Anonymous seller", "匿名卖家")
                    : post.userName ?? L10n.tr("Unavailable user", "用户资料不可用"),
                avatar: avatar
            ),
            category: .secondhand,
            viewCount: post.viewCount,
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
            image: item.displayImageUrls.first
                .flatMap(URL.init(string:))
                .map(ImageSource.url) ?? .placeholder,
            title: item.title,
            subtitle: item.description,
            footer: .posted(name: item.seller, avatar: avatar),
            category: .secondhand,
            timeText: item.timeAgo,
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
        let avatar = post.authorAvatar
            .flatMap(URL.init(string:))
            .map(ImageSource.url) ?? .placeholder

        return HomeCardItem(
            postId: post.id,
            authorId: post.authorId,
            image: post.imageUrls.first
                .flatMap(URL.init(string:))
                .map(ImageSource.url) ?? .placeholder,
            title: post.title,
            subtitle: post.content,
            footer: .posted(name: post.authorName, avatar: avatar),
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
