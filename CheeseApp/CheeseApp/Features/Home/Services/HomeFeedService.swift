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
}

struct RecommendationSessionPaginationState: Equatable {
    let sessionID: UUID
    private(set) var offset = 0

    mutating func recordPage(itemCount: Int) {
        offset += max(itemCount, 0)
    }
}

final class HomeFeedService {
    static let shared = HomeFeedService()

    private let supabase = SupabaseManager.shared

    private init() {}

    func fetchFeaturedBundle(secondhandLimit: Int) async throws -> HomeFeaturedFeedBundle {
        let secondhand = try await fetchFeaturedSecondhandRows(limit: secondhandLimit)
        return HomeFeaturedFeedBundle(
            secondhandPosts: secondhand.map(Self.makeSecondhandPost),
            secondhandRows: secondhand
        )
    }

    func fetchHomeFeaturedPosts(limit: Int = 12) async throws -> [HomeFeaturedPost] {
        try await supabase
            .database("home_featured_posts")
            .select("post_id,badge,display_order")
            .eq("is_enabled", value: true)
            .order("display_order", ascending: true)
            .order("post_id", ascending: true)
            .limit(limit)
            .execute()
            .value
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

    /// Returns nil when server-side rollout keeps this account on the legacy
    /// feed. A V1 session owns ordering; hydration below preserves that order.
    func fetchRecommendationForumPreview(
        limit: Int = 36,
        forceRefresh: Bool
    ) async throws -> HomeForumRecommendationBundle? {
        let mode: RecommendationFeedModeRow = try await supabase.client
            .rpc("get_recommendation_feed_mode")
            .execute()
            .value
        guard mode.useRecommendations else { return nil }

        let sessionID: UUID? = try await supabase.client
            .rpc(
                "create_recommendation_feed_session",
                params: CreateRecommendationSessionParams(
                    forceRefresh: forceRefresh,
                    shadow: false,
                    userID: nil
                )
            )
            .execute()
            .value
        guard let sessionID else { return nil }

        var references: [RecommendationFeedPageRow] = []
        var pagination = RecommendationSessionPaginationState(sessionID: sessionID)
        let boundedLimit = min(max(limit, 1), 60)
        while references.count < boundedLimit {
            let page: [RecommendationFeedPageRow] = try await supabase.client
                .rpc(
                    "get_recommendation_feed_page",
                    params: RecommendationFeedPageParams(
                        sessionID: sessionID,
                        offset: pagination.offset,
                        limit: min(20, boundedLimit - references.count)
                    )
                )
                .execute()
                .value
            references.append(contentsOf: page)
            guard page.count == min(20, boundedLimit - (references.count - page.count)) else {
                break
            }
            pagination.recordPage(itemCount: page.count)
        }

        let postIDs = references.map(\.postID)
        guard !postIDs.isEmpty else {
            return HomeForumRecommendationBundle(
                sessionID: sessionID,
                algorithmVersion: mode.algorithmVersion,
                posts: [],
                positions: [:]
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
            )
        )
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

private struct RecommendationFeedPageRow: Decodable {
    let sessionID: UUID
    let postID: UUID
    let position: Int

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case postID = "post_id"
        case position
    }
}

private struct CreateRecommendationSessionParams: Encodable {
    let forceRefresh: Bool
    let shadow: Bool
    let userID: UUID?

    enum CodingKeys: String, CodingKey {
        case forceRefresh = "p_force_refresh"
        case shadow = "p_shadow"
        case userID = "p_user_id"
    }
}

private struct RecommendationFeedPageParams: Encodable {
    let sessionID: UUID
    let offset: Int
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case sessionID = "p_session_id"
        case offset = "p_offset"
        case limit = "p_limit"
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
