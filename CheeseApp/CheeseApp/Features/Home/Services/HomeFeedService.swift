import Foundation
import Supabase

struct HomeFeaturedFeedBundle {
    let secondhandPosts: [HomeFeaturedSecondhandPost]
    let secondhandRows: [DBSecondhandPost]
}

struct HomeFollowingFeedBundle {
    let followedAuthorIDs: Set<UUID>
    let forumPosts: [HomeForumPreview]
    let secondhandPosts: [HomeFeaturedSecondhandPost]
    let secondhandRows: [DBSecondhandPost]
}

struct HomeFeaturedPost: Decodable, Hashable, Identifiable {
    let postID: UUID
    let badge: String?
    let displayOrder: Int

    var id: UUID { postID }

    enum CodingKeys: String, CodingKey {
        case postID = "post_id"
        case badge
        case displayOrder = "display_order"
    }
}

struct HomeFeedImage {
    let url: String
}

struct HomeFeaturedSecondhandPost {
    let id: UUID
    let userId: UUID
    let title: String
    let price: Double
    let originalPrice: Double?
    let userName: String?
    let userAvatar: String?
    let isAnonymous: Bool
    let isUserMcMasterVerified: Bool
    let images: [HomeFeedImage]
    let likeCount: Int
    let viewCount: Int
    let saveCount: Int
    let createdAt: Date
}

struct HomeForumPreview {
    let id: UUID
    let userId: UUID?
    let title: String
    let isAnonymous: Bool
    let userName: String?
    let userAvatar: String?
    let imageURL: String?
    let viewCount: Int
    let saveCount: Int
    let createdAt: Date
}

struct HomeForumRecommendationBundle {
    let sessionID: UUID
    let algorithmVersion: String
    let posts: [HomeForumPreview]
    let positions: [UUID: Int]
    let resolution: HomeForumSessionResolution
}

struct HomeForumSessionResolution: Decodable {
    let session_id: UUID
    let created_at: Date
    let expires_at: Date
    let reused: Bool
    let reason: String
    let items: [RecommendationFeedPageRow]
}

enum HomeRefreshIntent { case normal, explicitPull }

/// Presentation only. No ranking scores, exposure signals or continuation IDs.
struct HomeForumPresentation {
    private(set) var accountID: UUID?
    private(set) var sessionID: UUID?
    private(set) var orderedIDs: [UUID] = []
    private(set) var recentTops: [[UUID]] = []
    private(set) var generation = 0
    private(set) var tierCounts = [0, 0, 0]

    static func tiers(_ candidates: [UUID], previous: [UUID], older: [UUID]) -> [[UUID]] {
        let last = Set(previous), before = Set(older)
        return [candidates.filter { !last.contains($0) && !before.contains($0) },
                candidates.filter { !last.contains($0) && before.contains($0) },
                candidates.filter { last.contains($0) }]
    }

    mutating func resolve(account: UUID, session: UUID, candidates: [UUID], featured: Set<UUID>, intent: HomeRefreshIntent) {
        var seen = Set<UUID>()
        let organic = candidates.filter { !featured.contains($0) && seen.insert($0).inserted }
        let changed = accountID != account || sessionID != session
        if changed {
            self = HomeForumPresentation()
            accountID = account; sessionID = session
            orderedIDs = organic
            // Seed first display so the first pull can rotate away from its top.
            recentTops = [Array(organic.prefix(20))]
            return
        }
        recentTops = recentTops.map { $0.filter { seen.contains($0) } }
        guard intent == .explicitPull else {
            let prior = Set(orderedIDs)
            orderedIDs = orderedIDs.filter { seen.contains($0) } + organic.filter { !prior.contains($0) }
            return
        }
        let groups = Self.tiers(organic, previous: recentTops.first ?? [], older: recentTops.dropFirst().first ?? [])
        tierCounts = groups.map(\.count)
        orderedIDs = groups.flatMap { $0 }
        recentTops = Array(([Array(orderedIDs.prefix(20))] + recentTops).prefix(2))
        generation += 1
    }
}

/// One request/commit for overlapping pulls; a pull arriving during a normal
/// request upgrades that operation's presentation intent, without another RPC.
@MainActor
final class HomeRefreshCoordinator {
    private var task: Task<Bool, Never>?
    private var token: UUID?
    private(set) var explicitPullRequested = false

    func run(intent: HomeRefreshIntent, operation: @escaping @MainActor () async -> Bool) async -> Bool {
        if intent == .explicitPull { explicitPullRequested = true }
        if let task { return await task.value }
        let id = UUID()
        token = id
        let newTask = Task { await operation() }
        task = newTask
        let result = await newTask.value
        if token == id { task = nil; token = nil; explicitPullRequested = false }
        return result
    }

    func cancel() {
        task?.cancel(); task = nil; token = nil; explicitPullRequested = false
    }
}

/// Keep the database timestamp verbatim: converting through Date loses cursor precision.
struct ForumContinuationReference: Codable, Equatable {
    let post_id: UUID
    let created_at: String
}

/// Presentation rotation has no access to this session-scoped browsing cursor.
struct HomeForumContinuationPosition {
    private(set) var sessionID: UUID?
    var cursor: ForumContinuationReference?
    var exclusions: [UUID]?

    static func allowsAutomaticLoad(refreshError: String?, paginationError: String?) -> Bool {
        refreshError == nil && paginationError == nil
    }

    mutating func resolve(session: UUID?) -> Bool {
        guard session == nil || sessionID != session else { return false }
        self = HomeForumContinuationPosition(sessionID: session)
        return true
    }

    static func unseen(_ ids: [UUID], after existing: [UUID]) -> [UUID] {
        var seen = Set(existing)
        return ids.filter { seen.insert($0).inserted }
    }
}

private struct ForumContinuationParams: Encodable {
    let p_excluded_ids: [UUID]
    let p_before_time: String?
    let p_before_id: UUID?
    let p_limit: Int
}

final class HomeFeedService {
    static let shared = HomeFeedService()

    private let supabase = SupabaseManager.shared

    private init() {}

    func fetchForumContinuation(excluding: [UUID], before: ForumContinuationReference?) async throws -> [ForumContinuationReference] {
        try await supabase.client
            .rpc("get_forum_continuation_page", params: ForumContinuationParams(
                p_excluded_ids: excluding, p_before_time: before?.created_at,
                p_before_id: before?.post_id, p_limit: 20))
            .setHeader(name: "x-cheese-recommendation-contract", value: "2")
            .execute().value
    }

    func fetchFeaturedBundle(secondhandLimit: Int) async throws -> HomeFeaturedFeedBundle {
        let secondhand = try await fetchFeaturedSecondhandRows(limit: secondhandLimit)
        return HomeFeaturedFeedBundle(
            secondhandPosts: secondhand.map(Self.makeSecondhandPost),
            secondhandRows: secondhand
        )
    }

    func fetchHomeFeaturedPosts(limit: Int = 12) async throws -> [HomeFeaturedPost] {
        let rows: [HomeFeaturedPost] = try await supabase
            .database("home_featured_posts")
            .select("post_id,badge,display_order")
            .eq("is_enabled", value: true)
            .order("display_order", ascending: true)
            .order("post_id", ascending: true)
            .limit(limit)
            .execute()
            .value
        guard !rows.isEmpty else { return [] }
        let allowed: [UUID] = try await supabase.client
            .rpc("filter_cross_school_recommendation_posts",
                 params: CrossSchoolPostIDsParams(postIDs: rows.map(\.postID)))
            .setHeader(name: "x-cheese-recommendation-contract", value: "2")
            .execute()
            .value
        return Self.eligibleFeaturedPosts(rows, allowedIDs: Set(allowed))
    }

    static func eligibleFeaturedPosts(_ rows: [HomeFeaturedPost], allowedIDs: Set<UUID>) -> [HomeFeaturedPost] {
        rows.filter { allowedIDs.contains($0.postID) }
    }

    func fetchForumPreview(limit: Int) async throws -> [HomeForumPreview] {
        let rows: [ForumPreviewRow] = try await supabase
            .database("forum_posts_view")
            .select()
            .eq("is_private", value: false)
            .order("view_count", ascending: false)
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .limit(limit)
            .execute()
            .value

        return rows.map(Self.makeForumPreview)
    }

    /// Normal loads and pulls both resolve the same valid server session.
    /// Only an explicit server-off mode may return nil; errors never fall back.
    func resolveRecommendationForumPreview() async throws -> HomeForumRecommendationBundle? {
        let mode: RecommendationFeedModeRow = try await supabase.client
            .rpc("get_recommendation_feed_mode")
            .setHeader(name: "x-cheese-recommendation-contract", value: "2")
            .execute()
            .value
        guard mode.useRecommendations else { return nil }

        let resolution: HomeForumSessionResolution? = try await supabase.client
            .rpc("resolve_home_forum_session")
            .setHeader(name: "x-cheese-recommendation-contract", value: "2")
            .execute()
            .value
        guard let resolution else { throw PostgrestError(code: "P0001", message: "Recommendation mode changed; retry") }
        let sessionID = resolution.session_id
        let references = resolution.items

        let postIDs = references.map(\.postID)
        guard !postIDs.isEmpty else {
            return HomeForumRecommendationBundle(
                sessionID: sessionID,
                algorithmVersion: mode.algorithmVersion,
                posts: [],
                positions: [:], resolution: resolution
            )
        }
        let rows: [ForumPreviewRow] = try await supabase
            .database("forum_posts_view")
            .select()
            .in("id", values: postIDs.map(\.uuidString))
            .execute()
            .value
        let rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return HomeForumRecommendationBundle(
            sessionID: sessionID,
            algorithmVersion: mode.algorithmVersion,
            posts: references.compactMap { reference in
                rowByID[reference.postID].map(Self.makeForumPreview)
            },
            positions: Dictionary(
                uniqueKeysWithValues: references.map { ($0.postID, $0.position) }
            ), resolution: resolution
        )
    }

    func validateForumPosts(_ ids: [UUID]) async throws -> Set<UUID> {
        var allowed = Set<UUID>()
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = Array(ids[start..<min(start + 100, ids.count)])
            let rows: [UUID] = try await supabase.client
                .rpc("validate_home_forum_posts", params: CrossSchoolPostIDsParams(postIDs: batch))
                .setHeader(name: "x-cheese-recommendation-contract", value: "2").execute().value
            allowed.formUnion(rows)
        }
        return allowed
    }

    func fetchFollowingFeed(
        userID: UUID,
        limitPerKind: Int = 60
    ) async throws -> HomeFollowingFeedBundle {
        let followRows: [HomeFollowingRow] = try await supabase
            .database("user_follows")
            .select("following_id")
            .eq("follower_id", value: userID.uuidString)
            .execute()
            .value
        let followedAuthorIDs = Set(followRows.map(\.followingID))
        guard !followedAuthorIDs.isEmpty else {
            return HomeFollowingFeedBundle(
                followedAuthorIDs: [],
                forumPosts: [],
                secondhandPosts: [],
                secondhandRows: []
            )
        }

        let authorIDValues = followedAuthorIDs.map(\.uuidString)
        async let forumRows: [ForumPreviewRow] = supabase
            .database("forum_posts_view")
            .select()
            .in("user_id", values: authorIDValues)
            .eq("is_private", value: false)
            .eq("is_anonymous", value: false)
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .limit(limitPerKind)
            .execute()
            .value
        async let secondhandRows: [DBSecondhandPost] = supabase
            .database("secondhand_posts_view")
            .select()
            .in("user_id", values: authorIDValues)
            .eq("is_private", value: false)
            .eq("is_anonymous", value: false)
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .limit(limitPerKind)
            .execute()
            .value
        let (resolvedForumRows, resolvedSecondhandRows) = try await (
            forumRows,
            secondhandRows
        )

        return HomeFollowingFeedBundle(
            followedAuthorIDs: followedAuthorIDs,
            forumPosts: resolvedForumRows.map(Self.makeForumPreview),
            secondhandPosts: resolvedSecondhandRows.map(Self.makeSecondhandPost),
            secondhandRows: resolvedSecondhandRows
        )
    }

    private func fetchFeaturedSecondhandRows(limit: Int) async throws -> [DBSecondhandPost] {
        try await supabase
            .database("secondhand_posts_view")
            .select()
            .eq("is_private", value: false)
            .order("view_count", ascending: false)
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    private static func makeSecondhandPost(
        _ row: DBSecondhandPost
    ) -> HomeFeaturedSecondhandPost {
        HomeFeaturedSecondhandPost(
            id: row.id,
            userId: row.userId,
            title: row.title,
            price: row.price,
            originalPrice: row.originalPrice,
            userName: row.userName,
            userAvatar: row.userAvatar,
            isAnonymous: row.isAnonymous,
            isUserMcMasterVerified: !row.isAnonymous && row.userMcMasterVerified == true,
            images: DBSecondhandImage.stablySorted(row.images ?? [])
                .prefix(1)
                .map {
                    HomeFeedImage(
                        url: $0.url(for: .original)?.absoluteString ?? $0.url
                    )
                },
            likeCount: row.likeCount ?? 0,
            viewCount: row.viewCount ?? 0,
            saveCount: row.saveCount ?? 0,
            createdAt: row.createdAt
        )
    }

    private static func makeForumPreview(_ row: ForumPreviewRow) -> HomeForumPreview {
        HomeForumPreview(
            id: row.id,
            userId: row.userId,
            title: row.title,
            isAnonymous: row.isAnonymous,
            userName: row.userName,
            userAvatar: row.userAvatar,
            imageURL: row.images?.first?.url,
            viewCount: row.viewCount ?? 0,
            saveCount: row.saveCount ?? 0,
            createdAt: row.createdAt
        )
    }

}

private struct RecommendationFeedModeRow: Decodable {
    let algorithmVersion: String
    let shadowEnabled: Bool
    let useRecommendations: Bool

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case shadowEnabled = "shadow_enabled"
        case useRecommendations = "use_recommendations"
    }
}

private struct CrossSchoolPostIDsParams: Encodable {
    let postIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case postIDs = "p_post_ids"
    }
}

struct RecommendationFeedPageRow: Decodable {
    let sessionID: UUID
    let postID: UUID
    let position: Int

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case postID = "post_id"
        case position
    }
}

private struct HomeFollowingRow: Decodable {
    let followingID: UUID

    enum CodingKeys: String, CodingKey {
        case followingID = "following_id"
    }
}

private struct ForumPreviewRow: Decodable {
    let id: UUID
    let userId: UUID?
    let title: String
    let isAnonymous: Bool
    let userName: String?
    let userAvatar: String?
    let images: [ForumPreviewImageRow]?
    let viewCount: Int?
    let saveCount: Int?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case isAnonymous = "is_anonymous"
        case userName = "user_name"
        case userAvatar = "user_avatar"
        case images
        case viewCount = "view_count"
        case saveCount = "save_count"
        case createdAt = "created_at"
    }
}

private struct ForumPreviewImageRow: Decodable {
    let url: String
}
