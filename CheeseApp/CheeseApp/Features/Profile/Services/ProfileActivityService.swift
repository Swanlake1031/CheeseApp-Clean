import Foundation
import Supabase

enum ProfileActivityKind: String, CaseIterable, Identifiable {
    case published
    case liked
    case commented
    case favorited

    var id: String { rawValue }

    var title: String {
        switch self {
        case .published: return L10n.tr("Posts", "发布")
        case .liked: return L10n.tr("Likes", "喜欢")
        case .commented: return L10n.tr("Comments", "评论")
        case .favorited: return L10n.tr("Saved", "收藏")
        }
    }

    var emptyTitle: String {
        switch self {
        case .published: return L10n.tr("No posts yet", "尚未发布内容")
        case .liked: return L10n.tr("No liked content yet", "尚未喜欢任何内容")
        case .commented: return L10n.tr("No comments yet", "尚未发表评论")
        case .favorited: return L10n.tr("No saved content yet", "尚未收藏内容")
        }
    }
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

@MainActor
final class ProfileActivityService: ObservableObject {
    typealias PageLoader = (
        ProfileActivityKind,
        PostKind?,
        ProfileActivityCursor?,
        Int
    ) async throws -> ProfileActivityPage
    typealias PrivacyLoader = (
        ProfileActivityKind,
        [UUID]
    ) async throws -> Set<UUID>

    @Published private(set) var selectedKind: ProfileActivityKind
    @Published private(set) var selectedPublishedPostKind: PostKind?
    @Published private(set) var items: [ProfileActivityItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingNextPage = false
    @Published private(set) var hasResolvedInitialLoad = false
    @Published private(set) var hasMore = true
    @Published private(set) var privatePostIDs: Set<UUID> = []
    @Published var errorMessage: String?

    private let pageSize: Int
    private let loadPage: PageLoader
    private let loadPrivatePostIDs: PrivacyLoader
    private var ownerID: UUID?
    private var generation: UInt64 = 0
    private var cursor: ProfileActivityCursor?
    private var cachedPages: [ActivityCacheKey: CachedPage] = [:]

    init(
        initialKind: ProfileActivityKind = .published,
        pageSize: Int = 30,
        loadPage: PageLoader? = nil,
        privacyLoader: PrivacyLoader? = nil
    ) {
        selectedKind = initialKind
        selectedPublishedPostKind = nil
        self.pageSize = pageSize
        self.loadPage = loadPage ?? Self.remotePage
        self.loadPrivatePostIDs = privacyLoader
            ?? (loadPage == nil ? Self.remotePrivatePostIDs : { _, _ in [] })
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
        publishedPostKind: PostKind? = nil
    ) async {
        let normalizedPostKind = kind == .published ? publishedPostKind : nil
        if selectedKind != kind
            || selectedPublishedPostKind != normalizedPostKind {
            cacheCurrentPageIfResolved()
            selectedKind = kind
            selectedPublishedPostKind = normalizedPostKind
            generation &+= 1
            restoreCachedPageOrReset(
                for: ActivityCacheKey(
                    kind: kind,
                    publishedPostKind: normalizedPostKind
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

        guard await waitForInitialLoadSlot(
            owner: waitingOwner,
            generation: waitingGeneration,
            kind: waitingKind,
            publishedPostKind: waitingPostKind
        ) else { return }
        if hasResolvedInitialLoad && !force { return }

        let requestOwner = ownerID
        let requestGeneration = generation
        let requestKind = selectedKind
        let requestPostKind = selectedPublishedPostKind
        isLoading = true
        errorMessage = nil
        defer {
            if isCurrent(
                owner: requestOwner,
                generation: requestGeneration,
                kind: requestKind,
                publishedPostKind: requestPostKind
            ) {
                isLoading = false
            }
        }

        do {
            let page = try await loadPage(
                requestKind,
                requestPostKind,
                nil,
                pageSize
            )
            let loadedPrivatePostIDs = try await loadPrivatePostIDs(
                requestKind,
                page.items.map(\.postID)
            )
            guard isCurrent(
                owner: requestOwner,
                generation: requestGeneration,
                kind: requestKind,
                publishedPostKind: requestPostKind
            ) else { return }
            items = page.items
            privatePostIDs = loadedPrivatePostIDs
            cursor = page.nextCursor
            hasMore = page.nextCursor != nil
            hasResolvedInitialLoad = true
            cacheCurrentPageIfResolved()
        } catch {
            guard isCurrent(
                owner: requestOwner,
                generation: requestGeneration,
                kind: requestKind,
                publishedPostKind: requestPostKind
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
        isLoadingNextPage = true
        defer {
            if isCurrent(
                owner: requestOwner,
                generation: requestGeneration,
                kind: requestKind,
                publishedPostKind: requestPostKind
            ) {
                isLoadingNextPage = false
            }
        }

        do {
            let page = try await loadPage(
                requestKind,
                requestPostKind,
                cursor,
                pageSize
            )
            let loadedPrivatePostIDs = try await loadPrivatePostIDs(
                requestKind,
                page.items.map(\.postID)
            )
            guard isCurrent(
                owner: requestOwner,
                generation: requestGeneration,
                kind: requestKind,
                publishedPostKind: requestPostKind
            ) else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter {
                !known.contains($0.id)
            })
            privatePostIDs.formUnion(loadedPrivatePostIDs)
            self.cursor = page.nextCursor
            hasMore = page.nextCursor != nil
            errorMessage = nil
            cacheCurrentPageIfResolved()
        } catch {
            guard isCurrent(
                owner: requestOwner,
                generation: requestGeneration,
                kind: requestKind,
                publishedPostKind: requestPostKind
            ) else { return }
            if error.isCancellationLike { return }
            errorMessage = error.localizedDescription
            cacheCurrentPageIfResolved()
        }
    }

    func removeReaction(_ item: ProfileActivityItem) async {
        do {
            switch selectedKind {
            case .liked:
                _ = try await PostReactionService.shared.toggle(
                    postId: item.postID,
                    currentlyLiked: true
                )
            case .favorited:
                _ = try await PostFavoriteService.shared.toggleFavorite(
                    postId: item.postID,
                    currentlyFavorited: true
                )
            case .published, .commented:
                return
            }
            items.removeAll { $0.id == item.id }
            errorMessage = nil
            cacheCurrentPageIfResolved()
        } catch {
            if error.isCancellationLike { return }
            errorMessage = error.localizedDescription
        }
    }

    func isPostPrivate(_ postID: UUID) -> Bool {
        privatePostIDs.contains(postID)
    }

    private func resetPage() {
        items = []
        cursor = nil
        isLoading = false
        isLoadingNextPage = false
        hasResolvedInitialLoad = false
        hasMore = true
        privatePostIDs = []
        errorMessage = nil
    }

    private func cacheCurrentPageIfResolved() {
        guard hasResolvedInitialLoad else { return }
        cachedPages[
            ActivityCacheKey(
                kind: selectedKind,
                publishedPostKind: selectedPublishedPostKind
            )
        ] = CachedPage(
            items: items,
            cursor: cursor,
            hasMore: hasMore,
            privatePostIDs: privatePostIDs,
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
        errorMessage = page.errorMessage
    }

    private func isCurrent(
        owner: UUID?,
        generation: UInt64,
        kind: ProfileActivityKind,
        publishedPostKind: PostKind?
    ) -> Bool {
        ownerID == owner
            && self.generation == generation
            && selectedKind == kind
            && selectedPublishedPostKind == publishedPostKind
    }

    private func waitForInitialLoadSlot(
        owner: UUID,
        generation: UInt64,
        kind: ProfileActivityKind,
        publishedPostKind: PostKind?
    ) async -> Bool {
        while isLoading {
            guard !Task.isCancelled,
                  isCurrent(
                    owner: owner,
                    generation: generation,
                    kind: kind,
                    publishedPostKind: publishedPostKind
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
                publishedPostKind: publishedPostKind
            )
    }

    private static func remotePage(
        kind: ProfileActivityKind,
        publishedPostKind: PostKind?,
        cursor: ProfileActivityCursor?,
        limit: Int
    ) async throws -> ProfileActivityPage {
        let rows: [ProfileActivityItem] = try await SupabaseManager.shared.client
            .rpc(
                "get_my_profile_activity_page",
                params: ProfileActivityPageParams(
                    activityKind: kind.rawValue,
                    postType: publishedPostKind?.rawValue,
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

    private static func remotePrivatePostIDs(
        _ kind: ProfileActivityKind,
        _ postIDs: [UUID]
    ) async throws -> Set<UUID> {
        guard kind == .published, !postIDs.isEmpty else { return [] }

        let rows: [ProfileActivityPrivacyRow] = try await SupabaseManager.shared
            .database("posts")
            .select("id,is_private")
            .in("id", values: Array(Set(postIDs)).map(\.uuidString))
            .execute()
            .value

        return Set(rows.lazy.filter(\.isPrivate).map(\.id))
    }

    private struct CachedPage {
        let items: [ProfileActivityItem]
        let cursor: ProfileActivityCursor?
        let hasMore: Bool
        let privatePostIDs: Set<UUID>
        let errorMessage: String?
    }

    private struct ActivityCacheKey: Hashable {
        let kind: ProfileActivityKind
        let publishedPostKind: PostKind?
    }
}

private struct ProfileActivityPrivacyRow: Decodable {
    let id: UUID
    let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case isPrivate = "is_private"
    }
}

private struct ProfileActivityPageParams: Encodable {
    let activityKind: String
    let postType: String?
    let beforeCreatedAt: Date?
    let beforeID: UUID?
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case activityKind = "p_activity_kind"
        case postType = "p_post_type"
        case beforeCreatedAt = "p_before_created_at"
        case beforeID = "p_before_id"
        case limit = "p_limit"
    }
}
