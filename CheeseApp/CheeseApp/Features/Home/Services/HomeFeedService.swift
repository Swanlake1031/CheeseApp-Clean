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
    let orderIndex: Int?
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
            images: (row.images ?? []).map {
                HomeFeedImage(url: $0.url, orderIndex: $0.orderIndex)
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
