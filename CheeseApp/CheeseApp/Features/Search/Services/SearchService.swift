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
        return try await searchProfilesUsingRPC(query: normalized, limit: limit)
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

    func followUser(targetUserId: UUID) async throws {
        try await ProfileSocialService.shared.follow(targetUserId: targetUserId)
    }

    func unfollowUser(targetUserId: UUID) async throws {
        try await ProfileSocialService.shared.unfollow(targetUserId: targetUserId)
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
