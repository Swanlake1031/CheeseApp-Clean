import Foundation

struct SearchProfileResult: Codable, Identifiable, Hashable {
    let id: UUID
    let publicID: String
    let fullName: String
    let avatarURL: String?
    let university: String?
    let bio: String?
    let isFollowing: Bool
    let isMutualFollow: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case publicID = "public_uid"
        case fullName = "full_name"
        case avatarURL = "avatar_url"
        case university
        case bio
        case isFollowing = "is_following"
        case isMutualFollow = "is_mutual_follow"
    }

    func applyingFollowState(_ isFollowing: Bool) -> SearchProfileResult {
        SearchProfileResult(
            id: id,
            publicID: publicID,
            fullName: fullName,
            avatarURL: avatarURL,
            university: university,
            bio: bio,
            isFollowing: isFollowing,
            isMutualFollow: isFollowing ? isMutualFollow : false
        )
    }
}
