//
//  ForumPost.swift
//  CheeseApp
//
//  Board contracts shared by Forum views and services.
//

import Foundation

struct ForumBoard: Codable, Identifiable, Hashable {
    private static let anonymousBoardID = UUID(
        uuidString: "f0000000-0000-0000-0000-000000000005"
    )!

    enum Status: String, Codable {
        case active
        case closed
        case archived
    }

    enum MembershipRole: String, Codable {
        case member
        case moderator
        case admin
    }

    let id: UUID
    let slug: String
    let name: String
    let description: String
    let rules: String
    let icon: String
    let coverImageURL: String?
    let schoolID: UUID?
    let isOfficial: Bool
    let allowsAnonymousPosts: Bool
    let status: Status
    let createdBy: UUID?
    let createdAt: Date
    let updatedAt: Date
    var memberCount: Int
    var isJoined: Bool
    let viewerRole: MembershipRole?
    let canManage: Bool
    let canAdminister: Bool

    /// The canonical Anonymous board never exposes an identity choice. The
    /// stable ID fallback keeps this safe while migration 133 rolls out.
    var requiresAnonymousPosts: Bool {
        slug == "anonymous" || id == Self.anonymousBoardID
    }

    enum CodingKeys: String, CodingKey {
        case id, slug, name, description, rules, icon, status
        case coverImageURL = "cover_image_url"
        case schoolID = "school_id"
        case isOfficial = "is_official"
        case allowsAnonymousPosts = "allows_anonymous_posts"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case memberCount = "member_count"
        case isJoined = "is_joined"
        case viewerRole = "viewer_role"
        case canManage = "can_manage"
        case canAdminister = "can_administer"
    }
}

enum ForumPostSort: String, CaseIterable, Identifiable {
    case latest
    case hottest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latest: return L10n.tr("Latest", "最新")
        case .hottest: return L10n.tr("Hottest", "最热")
        }
    }
}

struct ForumBoardModerator: Codable, Identifiable, Hashable {
    let id: UUID
    let fullName: String?
    let avatarURL: String?
    let role: ForumBoard.MembershipRole

    enum CodingKeys: String, CodingKey {
        case id = "user_id"
        case fullName = "full_name"
        case avatarURL = "avatar_url"
        case role
    }
}

struct ForumBoardReport: Identifiable, Hashable {
    enum Status: String, CaseIterable {
        case pending
        case reviewing
        case resolved
        case dismissed
    }

    let id: UUID
    let postID: UUID
    let postTitle: String
    let reason: String
    let details: String?
    var status: Status
    let createdAt: Date
}
