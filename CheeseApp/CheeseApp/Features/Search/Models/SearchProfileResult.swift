import Foundation

struct SearchProfileResult: Codable, Identifiable, Hashable {
    let id: UUID
    let fullName: String
    let avatarURL: String?
    let university: String?
    let bio: String?
    let isFollowing: Bool
    let isMutualFollow: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case avatarURL = "avatar_url"
        case university
        case bio
        case isFollowing = "is_following"
        case isMutualFollow = "is_mutual_follow"
    }
}
