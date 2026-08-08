//
//  SearchService.swift
//  CheeseApp
//
//  Search-owned backend access.
//

import Foundation

struct SearchPostCursor: Equatable {
    let rankScore: Double
    let createdAt: Date
    let id: UUID
}

struct SearchPostPage {
    let results: [UnifiedSearchResult]
    let nextCursor: SearchPostCursor?
}

@MainActor
final class SearchService {
    static let shared = SearchService()

    private let supabase = SupabaseManager.shared

    private init() {}

    func searchPostsPage(
        query: String,
        category: SearchCategory,
        after cursor: SearchPostCursor? = nil,
        limit: Int
    ) async throws -> SearchPostPage {
        let rows: [SearchPostResultRow] = try await supabase.client
            .rpc(
                "search_posts_page",
                params: SearchPostsParams(
                    pQuery: query,
                    pCategory: category.searchPostsRPCValue,
                    pAfterRankScore: cursor?.rankScore,
                    pAfterCreatedAt: cursor?.createdAt,
                    pAfterID: cursor?.id,
                    pLimit: limit
                )
            )
            .execute()
            .value

        return SearchPostPage(
            results: rows.compactMap(UnifiedSearchResult.init(searchRow:)),
            nextCursor: rows.count == limit
                ? rows.last.map {
                    SearchPostCursor(
                        rankScore: $0.rankScore,
                        createdAt: $0.createdAt,
                        id: $0.id
                    )
                }
                : nil
        )
    }

    func fetchPostCounts() async throws -> [SearchCategory: Int] {
        let rows: [SearchPostCountRow] = try await supabase.client
            .rpc("get_search_post_counts")
            .execute()
            .value

        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let category = SearchCategory(searchPostsRPCValue: row.category),
                  category != .all
            else { return nil }
            return (category, row.totalCount)
        })
    }

    func searchProfiles(
        query: String,
        limit: Int
    ) async throws -> [SearchProfileResult] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let profileID = UUID(uuidString: normalized) else {
            return try await searchProfilesUsingRPC(
                query: normalized,
                limit: limit
            )
        }

        let rpcRows = (try? await searchProfilesUsingRPC(
            query: normalized,
            limit: limit
        )) ?? []
        guard !rpcRows.contains(where: { $0.id == profileID }),
              let exactProfile = try? await exactProfileResult(userID: profileID)
        else { return rpcRows }

        return [exactProfile] + rpcRows
    }

    private func searchProfilesUsingRPC(
        query: String,
        limit: Int
    ) async throws -> [SearchProfileResult] {
        try await supabase.client
            .rpc("search_profiles", params: SearchProfilesParams(pQuery: query, pLimit: limit))
            .execute()
            .value
    }

    private func exactProfileResult(userID: UUID) async throws -> SearchProfileResult {
        let profile = try await ProfileService.fetchProfile(userId: userID)
        let normalizedName = profile.fullName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentUserID = AuthService.shared.currentUser?.id
        let relationship = await profileRelationship(
            currentUserID: currentUserID,
            targetUserID: userID
        )

        return SearchProfileResult(
            id: profile.id,
            fullName: normalizedName.isEmpty
                ? L10n.tr("Cheese user", "奶酪用户")
                : normalizedName,
            avatarURL: profile.avatarUrl,
            university: profile.school,
            bio: profile.bio,
            isFollowing: relationship.isFollowing,
            isMutualFollow: relationship.isMutualFollow
        )
    }

    private func profileRelationship(
        currentUserID: UUID?,
        targetUserID: UUID
    ) async -> (isFollowing: Bool, isMutualFollow: Bool) {
        guard let currentUserID, currentUserID != targetUserID else {
            return (false, false)
        }

        async let outgoingRows: [ProfileFollowLookupRow]? = try? await supabase
            .database("user_follows")
            .select("follower_id,following_id")
            .eq("follower_id", value: currentUserID.uuidString)
            .eq("following_id", value: targetUserID.uuidString)
            .limit(1)
            .execute()
            .value
        async let incomingRows: [ProfileFollowLookupRow]? = try? await supabase
            .database("user_follows")
            .select("follower_id,following_id")
            .eq("follower_id", value: targetUserID.uuidString)
            .eq("following_id", value: currentUserID.uuidString)
            .limit(1)
            .execute()
            .value

        let isFollowing = await outgoingRows?.isEmpty == false
        let followsCurrentUser = await incomingRows?.isEmpty == false
        return (isFollowing, isFollowing && followsCurrentUser)
    }

    func followUser(targetUserId: UUID) async throws {
        let currentUserId = try await AuthService.shared.requireAuthUserId()
        try await supabase
            .database("user_follows")
            .insert([
                "follower_id": currentUserId.uuidString,
                "following_id": targetUserId.uuidString
            ])
            .execute()
    }

    func unfollowUser(targetUserId: UUID) async throws {
        let currentUserId = try await AuthService.shared.requireAuthUserId()
        try await supabase
            .database("user_follows")
            .delete()
            .eq("follower_id", value: currentUserId.uuidString)
            .eq("following_id", value: targetUserId.uuidString)
            .execute()
    }
}

private struct ProfileFollowLookupRow: Decodable {
    let followerID: UUID
    let followingID: UUID

    enum CodingKeys: String, CodingKey {
        case followerID = "follower_id"
        case followingID = "following_id"
    }
}

private struct SearchPostResultRow: Codable {
    let id: UUID
    let category: String
    let title: String
    let subtitle: String
    let previewImageURL: String?
    let createdAt: Date
    let hotScore: Double?
    let rankScore: Double

    enum CodingKeys: String, CodingKey {
        case id
        case category
        case title
        case subtitle
        case previewImageURL = "preview_image_url"
        case createdAt = "created_at"
        case hotScore = "hot_score"
        case rankScore = "rank_score"
    }
}

private struct SearchPostCountRow: Decodable {
    let category: String
    let totalCount: Int

    enum CodingKeys: String, CodingKey {
        case category
        case totalCount = "total_count"
    }
}

private struct SearchProfilesParams: Encodable {
    let pQuery: String
    let pLimit: Int

    enum CodingKeys: String, CodingKey {
        case pQuery = "p_query"
        case pLimit = "p_limit"
    }
}

private struct SearchPostsParams: Encodable {
    let pQuery: String
    let pCategory: String
    let pAfterRankScore: Double?
    let pAfterCreatedAt: Date?
    let pAfterID: UUID?
    let pLimit: Int

    enum CodingKeys: String, CodingKey {
        case pQuery = "p_query"
        case pCategory = "p_category"
        case pAfterRankScore = "p_after_rank_score"
        case pAfterCreatedAt = "p_after_created_at"
        case pAfterID = "p_after_id"
        case pLimit = "p_limit"
    }
}

private extension UnifiedSearchResult {
    init?(searchRow row: SearchPostResultRow) {
        guard let category = SearchCategory(searchPostsRPCValue: row.category), category != .all else {
            return nil
        }

        self.init(
            id: row.id,
            title: row.title,
            subtitle: row.subtitle,
            category: category,
            createdAt: row.createdAt,
            previewImageURL: row.previewImageURL,
            hotScore: row.hotScore ?? 0,
            rankScore: row.rankScore
        )
    }
}

extension SearchCategory {
    var searchPostsRPCValue: String {
        self == .secondhand ? "market" : rawValue
    }

    init?(searchPostsRPCValue: String) {
        if searchPostsRPCValue == "market" {
            self = .secondhand
        } else {
            self.init(rawValue: searchPostsRPCValue)
        }
    }
}
