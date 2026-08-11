import Foundation
import Supabase

enum ProfileActivityKind: String, CaseIterable, Identifiable {
    case published
    case liked
    case privateContent = "private_content"
    case favorited

    var id: String { rawValue }

    var title: String {
        switch self {
        case .published: return L10n.tr("Posts", "发布")
        case .liked: return L10n.tr("Likes", "喜欢")
        case .privateContent: return L10n.tr("Private", "私密内容")
        case .favorited: return L10n.tr("Saved", "收藏")
        }
    }

    var emptyTitle: String {
        switch self {
        case .published: return L10n.tr("No posts yet", "尚未发布内容")
        case .liked: return L10n.tr("No liked content yet", "尚未喜欢任何内容")
        case .privateContent: return L10n.tr("No private content yet", "暂无私密内容")
        case .favorited: return L10n.tr("No saved content yet", "尚未收藏内容")
        }
    }
}

enum PublishedPostVisibility: String, Hashable {
    case visible
    case hidden
}

enum PostHiddenReason: String, Decodable, Hashable {
    case user
    case autoExpired = "auto_expired"
}

struct ProfileActivityItem: Decodable, Identifiable, Hashable {
    let activityID: UUID
    let postID: UUID
    let postType: String
    let postTitle: String
    let postSummary: String
    let activitySummary: String
    let commentID: UUID?
    let activityCreatedAt: Date
    let price: Double?
    let coverImage: String?

    var id: UUID { activityID }
    var kind: PostKind? { PostKind(remoteValue: postType) }

    enum CodingKeys: String, CodingKey {
        case activityID = "activity_id"
        case postID = "post_id"
        case postType = "post_type"
        case postTitle = "post_title"
        case postSummary = "post_summary"
        case activitySummary = "activity_summary"
        case commentID = "comment_id"
        case activityCreatedAt = "activity_created_at"
        case price
        case coverImage = "cover_image"
    }
}

struct ProfileActivityCursor: Equatable {
    let createdAt: Date
    let id: UUID
}

struct ProfileActivityPage {
    let items: [ProfileActivityItem]
    let nextCursor: ProfileActivityCursor?
}

enum CompletedSecondhandRole: String, CaseIterable, Identifiable, Codable {
    case buyer
    case seller

    var id: String { rawValue }

    var title: String {
        switch self {
        case .buyer: return "我买的"
        case .seller: return "我卖的"
        }
    }
}

struct CompletedSecondhandTransaction: Decodable, Identifiable, Hashable {
    let transactionID: UUID
    let listingID: UUID
    let role: CompletedSecondhandRole
    let listingTitle: String
    let price: Double
    let coverImage: String?
    let counterpartyID: UUID
    let counterpartyName: String
    let counterpartyAvatar: String?
    let completedAt: Date

    var id: UUID { transactionID }

    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case listingID = "listing_id"
        case role
        case listingTitle = "listing_title"
        case price
        case coverImage = "cover_image"
        case counterpartyID = "counterparty_id"
        case counterpartyName = "counterparty_name"
        case counterpartyAvatar = "counterparty_avatar"
        case completedAt = "completed_at"
    }
}

@MainActor
final class CompletedSecondhandTransactionsService: ObservableObject {
    @Published private(set) var selectedRole: CompletedSecondhandRole = .buyer
    @Published private(set) var items: [CompletedSecondhandTransaction] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasResolved = false
    @Published var errorMessage: String?

    private var cache: [CompletedSecondhandRole: [CompletedSecondhandTransaction]] = [:]
    private var generation: UInt64 = 0

    var loadState: CollectionLoadState {
        CollectionLoadState.resolve(
            hasResolvedInitialLoad: hasResolved,
            isLoading: isLoading,
            hasContent: !items.isEmpty,
            errorMessage: errorMessage
        )
    }

    func select(_ role: CompletedSecondhandRole, force: Bool = false) async {
        if selectedRole != role {
            selectedRole = role
            generation &+= 1
            if let cached = cache[role], !force {
                items = cached
                hasResolved = true
                errorMessage = nil
                return
            }
            items = []
            hasResolved = false
            errorMessage = nil
        } else if hasResolved && !force {
            return
        }

        let requestGeneration = generation
        let requestRole = selectedRole
        isLoading = true
        errorMessage = nil
        defer {
            if requestGeneration == generation && requestRole == selectedRole {
                isLoading = false
            }
        }

        do {
            let rows: [CompletedSecondhandTransaction] = try await SupabaseManager
                .shared.client
                .rpc(
                    "get_my_completed_secondhand_transactions",
                    params: CompletedSecondhandTransactionsParams(role: requestRole)
                )
                .execute()
                .value
            guard requestGeneration == generation, requestRole == selectedRole else {
                return
            }
            items = rows
            cache[requestRole] = rows
            hasResolved = true
        } catch {
            guard requestGeneration == generation, requestRole == selectedRole else {
                return
            }
            if error.isCancellationLike { return }
            hasResolved = true
            errorMessage = error.localizedDescription
        }
    }
}

private struct CompletedSecondhandTransactionsParams: Encodable {
    let role: CompletedSecondhandRole

    enum CodingKeys: String, CodingKey {
        case role = "p_role"
    }
}

@MainActor
final class ProfileActivityService: ObservableObject {
    typealias PageLoader = (
        ProfileActivityKind,
        PostKind?,
        PublishedPostVisibility,
        ProfileActivityCursor?,
        Int
    ) async throws -> ProfileActivityPage
    typealias PrivacyLoader = (
        ProfileActivityKind,
        [UUID]
    ) async throws -> Set<UUID>
    private typealias VisibilityLoader = (
        ProfileActivityKind,
        [UUID]
    ) async throws -> ProfileActivityVisibilitySnapshot
    typealias ReactionToggler = (UUID, Bool) async throws -> Bool

    @Published private(set) var selectedKind: ProfileActivityKind
    @Published private(set) var selectedPublishedPostKind: PostKind?
    @Published private(set) var selectedPublishedVisibility: PublishedPostVisibility
    @Published private(set) var items: [ProfileActivityItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingNextPage = false
    @Published private(set) var hasResolvedInitialLoad = false
    @Published private(set) var hasMore = true
    @Published private(set) var privatePostIDs: Set<UUID> = []
    @Published private(set) var autoHiddenPostIDs: Set<UUID> = []
    @Published var errorMessage: String?

    private let pageSize: Int
    private let loadPage: PageLoader
    private let loadVisibility: VisibilityLoader
    private let toggleLike: ReactionToggler
    private let toggleFavorite: ReactionToggler
    private var ownerID: UUID?
    private var generation: UInt64 = 0
    private var cursor: ProfileActivityCursor?
    private var cachedPages: [ActivityCacheKey: CachedPage] = [:]

    init(
        initialKind: ProfileActivityKind = .published,
        initialPublishedVisibility: PublishedPostVisibility = .visible,
        pageSize: Int = 30,
        loadPage: PageLoader? = nil,
        privacyLoader: PrivacyLoader? = nil,
        likeToggler: ReactionToggler? = nil,
        favoriteToggler: ReactionToggler? = nil
    ) {
        selectedKind = initialKind
        selectedPublishedPostKind = nil
        selectedPublishedVisibility = initialPublishedVisibility
        self.pageSize = pageSize
        self.loadPage = loadPage ?? Self.remotePage
        self.toggleLike = likeToggler ?? { postID, isLiked in
            try await PostReactionService.shared.toggle(
                postId: postID,
                currentlyLiked: isLiked
            )
        }
        self.toggleFavorite = favoriteToggler ?? { postID, isFavorited in
            try await PostFavoriteService.shared.toggleFavorite(
                postId: postID,
                currentlyFavorited: isFavorited
            )
        }
        if let privacyLoader {
            self.loadVisibility = { kind, postIDs in
                ProfileActivityVisibilitySnapshot(
                    privatePostIDs: try await privacyLoader(kind, postIDs),
                    autoHiddenPostIDs: []
                )
            }
        } else {
            self.loadVisibility = loadPage == nil
                ? Self.remoteVisibility
                : { _, _ in .empty }
        }
    }

    var loadState: CollectionLoadState {
        CollectionLoadState.resolve(
            hasResolvedInitialLoad: hasResolvedInitialLoad,
            isLoading: isLoading,
            hasContent: !items.isEmpty,
            errorMessage: errorMessage
        )
    }

    func activateAccount(_ userID: UUID?) {
        guard ownerID != userID else { return }
        ownerID = userID
        generation &+= 1
        cachedPages.removeAll()
        resetPage()
    }

    func select(
        _ kind: ProfileActivityKind,
        publishedPostKind: PostKind? = nil,
        publishedVisibility: PublishedPostVisibility = .visible
    ) async {
        let normalizedPostKind = kind == .published ? publishedPostKind : nil
        let normalizedVisibility = kind == .published ? publishedVisibility : .visible
        if selectedKind != kind
            || selectedPublishedPostKind != normalizedPostKind
            || selectedPublishedVisibility != normalizedVisibility {
            cacheCurrentPageIfResolved()
            selectedKind = kind
            selectedPublishedPostKind = normalizedPostKind
            selectedPublishedVisibility = normalizedVisibility
            generation &+= 1
            restoreCachedPageOrReset(
                for: ActivityCacheKey(
                    kind: kind,
                    publishedPostKind: normalizedPostKind,
                    publishedVisibility: normalizedVisibility
                )
            )
        }
        await loadInitial()
    }

    func loadInitial(force: Bool = false) async {
        guard let waitingOwner = ownerID else { return }
        let waitingGeneration = generation
        let waitingKind = selectedKind
        let waitingPostKind = selectedPublishedPostKind
        let waitingVisibility = selectedPublishedVisibility

        guard await waitForInitialLoadSlot(
            owner: waitingOwner,
            generation: waitingGeneration,
            kind: waitingKind,
            publishedPostKind: waitingPostKind,
            publishedVisibility: waitingVisibility
        ) else { return }
        if hasResolvedInitialLoad && !force { return }

        let requestOwner = ownerID
        let requestGeneration = generation
        let requestKind = selectedKind
        let requestPostKind = selectedPublishedPostKind
        let requestVisibility = selectedPublishedVisibility
        isLoading = true
        errorMessage = nil
        defer {
            if isCurrent(
                owner: requestOwner,
                generation: requestGeneration,
                kind: requestKind,
                publishedPostKind: requestPostKind,
                publishedVisibility: requestVisibility
            ) {
                isLoading = false
            }
        }

        do {
            let page = try await loadPage(
                requestKind,
                requestPostKind,
                requestVisibility,
                nil,
                pageSize
            )
            let visibility = try await loadVisibility(
                requestKind,
                page.items.map(\.postID)
            )
            guard isCurrent(
                owner: requestOwner,
                generation: requestGeneration,
                kind: requestKind,
                publishedPostKind: requestPostKind,
                publishedVisibility: requestVisibility
            ) else { return }
            items = page.items
            privatePostIDs = visibility.privatePostIDs
            autoHiddenPostIDs = visibility.autoHiddenPostIDs
            cursor = page.nextCursor
            hasMore = page.nextCursor != nil
            hasResolvedInitialLoad = true
            cacheCurrentPageIfResolved()
        } catch {
            guard isCurrent(
                owner: requestOwner,
                generation: requestGeneration,
                kind: requestKind,
                publishedPostKind: requestPostKind,
                publishedVisibility: requestVisibility
            ) else { return }
            if error.isCancellationLike { return }
            errorMessage = error.localizedDescription
            hasResolvedInitialLoad = true
            cacheCurrentPageIfResolved()
        }
    }

    func loadNextPageIfNeeded(currentItem: ProfileActivityItem) async {
        guard currentItem.id == items.last?.id,
              hasMore,
              !isLoadingNextPage,
              let cursor
        else { return }

        let requestOwner = ownerID
        let requestGeneration = generation
        let requestKind = selectedKind
        let requestPostKind = selectedPublishedPostKind
        let requestVisibility = selectedPublishedVisibility
        isLoadingNextPage = true
        defer {
            if isCurrent(
                owner: requestOwner,
                generation: requestGeneration,
                kind: requestKind,
                publishedPostKind: requestPostKind,
                publishedVisibility: requestVisibility
            ) {
                isLoadingNextPage = false
            }
        }

        do {
            let page = try await loadPage(
                requestKind,
                requestPostKind,
                requestVisibility,
                cursor,
                pageSize
            )
            let visibility = try await loadVisibility(
                requestKind,
                page.items.map(\.postID)
            )
            guard isCurrent(
                owner: requestOwner,
                generation: requestGeneration,
                kind: requestKind,
                publishedPostKind: requestPostKind,
                publishedVisibility: requestVisibility
            ) else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter {
                !known.contains($0.id)
            })
            privatePostIDs.formUnion(visibility.privatePostIDs)
            autoHiddenPostIDs.formUnion(visibility.autoHiddenPostIDs)
            self.cursor = page.nextCursor
            hasMore = page.nextCursor != nil
            errorMessage = nil
            cacheCurrentPageIfResolved()
        } catch {
            guard isCurrent(
                owner: requestOwner,
                generation: requestGeneration,
                kind: requestKind,
                publishedPostKind: requestPostKind,
                publishedVisibility: requestVisibility
            ) else { return }
            if error.isCancellationLike { return }
            errorMessage = error.localizedDescription
            cacheCurrentPageIfResolved()
        }
    }

    func toggleReaction(
        _ item: ProfileActivityItem,
        currentlyActive: Bool
    ) async {
        do {
            switch selectedKind {
            case .liked:
                _ = try await toggleLike(item.postID, currentlyActive)
            case .favorited:
                _ = try await toggleFavorite(item.postID, currentlyActive)
            case .published, .privateContent:
                return
            }
            // Keep the current page snapshot stable. The shared interaction
            // store updates the icon immediately; membership is reconciled
            // from server truth when the user next enters this tab or refreshes.
            errorMessage = nil
        } catch {
            if error.isCancellationLike { return }
            errorMessage = error.localizedDescription
        }
    }

    func isPostPrivate(_ postID: UUID) -> Bool {
        privatePostIDs.contains(postID)
    }

    func hiddenReason(_ postID: UUID) -> PostHiddenReason? {
        guard privatePostIDs.contains(postID) else { return nil }
        return autoHiddenPostIDs.contains(postID) ? .autoExpired : .user
    }

    private func resetPage() {
        items = []
        cursor = nil
        isLoading = false
        isLoadingNextPage = false
        hasResolvedInitialLoad = false
        hasMore = true
        privatePostIDs = []
        autoHiddenPostIDs = []
        errorMessage = nil
    }

    private func cacheCurrentPageIfResolved() {
        guard hasResolvedInitialLoad else { return }
        cachedPages[
            ActivityCacheKey(
                kind: selectedKind,
                publishedPostKind: selectedPublishedPostKind,
                publishedVisibility: selectedPublishedVisibility
            )
        ] = CachedPage(
            items: items,
            cursor: cursor,
            hasMore: hasMore,
            privatePostIDs: privatePostIDs,
            autoHiddenPostIDs: autoHiddenPostIDs,
            errorMessage: errorMessage
        )
    }

    private func restoreCachedPageOrReset(
        for key: ActivityCacheKey
    ) {
        guard let page = cachedPages[key] else {
            resetPage()
            return
        }

        items = page.items
        cursor = page.cursor
        isLoading = false
        isLoadingNextPage = false
        hasResolvedInitialLoad = true
        hasMore = page.hasMore
        privatePostIDs = page.privatePostIDs
        autoHiddenPostIDs = page.autoHiddenPostIDs
        errorMessage = page.errorMessage
    }

    private func isCurrent(
        owner: UUID?,
        generation: UInt64,
        kind: ProfileActivityKind,
        publishedPostKind: PostKind?,
        publishedVisibility: PublishedPostVisibility
    ) -> Bool {
        ownerID == owner
            && self.generation == generation
            && selectedKind == kind
            && selectedPublishedPostKind == publishedPostKind
            && selectedPublishedVisibility == publishedVisibility
    }

    private func waitForInitialLoadSlot(
        owner: UUID,
        generation: UInt64,
        kind: ProfileActivityKind,
        publishedPostKind: PostKind?,
        publishedVisibility: PublishedPostVisibility
    ) async -> Bool {
        while isLoading {
            guard !Task.isCancelled,
                  isCurrent(
                    owner: owner,
                    generation: generation,
                    kind: kind,
                    publishedPostKind: publishedPostKind,
                    publishedVisibility: publishedVisibility
                  )
            else { return false }

            do {
                try await Task.sleep(for: .milliseconds(40))
            } catch {
                return false
            }
        }

        return !Task.isCancelled
            && isCurrent(
                owner: owner,
                generation: generation,
                kind: kind,
                publishedPostKind: publishedPostKind,
                publishedVisibility: publishedVisibility
            )
    }

    private static func remotePage(
        kind: ProfileActivityKind,
        publishedPostKind: PostKind?,
        publishedVisibility: PublishedPostVisibility,
        cursor: ProfileActivityCursor?,
        limit: Int
    ) async throws -> ProfileActivityPage {
        let rows: [ProfileActivityItem] = try await SupabaseManager.shared.client
            .rpc(
                "get_my_profile_activity_page",
                params: ProfileActivityPageParams(
                    activityKind: kind.rawValue,
                    postType: publishedPostKind?.rawValue,
                    visibility: publishedVisibility.rawValue,
                    beforeCreatedAt: cursor?.createdAt,
                    beforeID: cursor?.id,
                    limit: limit
                )
            )
            .execute()
            .value

        return ProfileActivityPage(
            items: rows,
            nextCursor: rows.count == limit
                ? rows.last.map {
                    ProfileActivityCursor(
                        createdAt: $0.activityCreatedAt,
                        id: $0.activityID
                    )
                }
                : nil
        )
    }

    private static func remoteVisibility(
        _ kind: ProfileActivityKind,
        _ postIDs: [UUID]
    ) async throws -> ProfileActivityVisibilitySnapshot {
        guard kind == .published, !postIDs.isEmpty else { return .empty }

        let rows: [ProfileActivityVisibilityRow] = try await SupabaseManager.shared
            .database("posts")
            .select("id,is_private,hidden_reason")
            .in("id", values: Array(Set(postIDs)).map(\.uuidString))
            .execute()
            .value

        return ProfileActivityVisibilitySnapshot(
            privatePostIDs: Set(rows.lazy.filter(\.isPrivate).map(\.id)),
            autoHiddenPostIDs: Set(
                rows.lazy.filter {
                    $0.isPrivate && $0.hiddenReason == .autoExpired
                }.map(\.id)
            )
        )
    }

    private struct CachedPage {
        let items: [ProfileActivityItem]
        let cursor: ProfileActivityCursor?
        let hasMore: Bool
        let privatePostIDs: Set<UUID>
        let autoHiddenPostIDs: Set<UUID>
        let errorMessage: String?
    }

    private struct ActivityCacheKey: Hashable {
        let kind: ProfileActivityKind
        let publishedPostKind: PostKind?
        let publishedVisibility: PublishedPostVisibility
    }
}

private struct ProfileActivityVisibilitySnapshot {
    let privatePostIDs: Set<UUID>
    let autoHiddenPostIDs: Set<UUID>

    static let empty = ProfileActivityVisibilitySnapshot(
        privatePostIDs: [],
        autoHiddenPostIDs: []
    )
}

private struct ProfileActivityVisibilityRow: Decodable {
    let id: UUID
    let isPrivate: Bool
    let hiddenReason: PostHiddenReason?

    enum CodingKeys: String, CodingKey {
        case id
        case isPrivate = "is_private"
        case hiddenReason = "hidden_reason"
    }
}

private struct ProfileActivityPageParams: Encodable {
    let activityKind: String
    let postType: String?
    let visibility: String
    let beforeCreatedAt: Date?
    let beforeID: UUID?
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case activityKind = "p_activity_kind"
        case postType = "p_post_type"
        case visibility = "p_visibility"
        case beforeCreatedAt = "p_before_created_at"
        case beforeID = "p_before_id"
        case limit = "p_limit"
    }
}
