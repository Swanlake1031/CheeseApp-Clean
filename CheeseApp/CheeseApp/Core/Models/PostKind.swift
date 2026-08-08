import Foundation

enum PostKind: String, Codable, CaseIterable, Hashable {
    case secondhand
    case forum

    init?(remoteValue: String) {
        self.init(
            rawValue: remoteValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        )
    }

    var displayName: String {
        switch self {
        case .secondhand: return "二手"
        case .forum: return "论坛"
        }
    }

    var icon: String {
        switch self {
        case .secondhand: return "bag.fill"
        case .forum: return "bubble.left.and.bubble.right.fill"
        }
    }

    var supportsPriceEditing: Bool {
        switch self {
        case .secondhand:
            return true
        case .forum:
            return false
        }
    }
}

enum PostFeatureEvents {
    enum Change: String {
        case created
        case updated
    }

    static let postsDidChange = Notification.Name("PostsDidChangeNotification")
    private static let postKindUserInfoKey = "postKind"
    private static let authorIdUserInfoKey = "authorId"
    private static let postIdUserInfoKey = "postId"
    private static let changeUserInfoKey = "change"

    static func postDidChange(
        kind: PostKind,
        authorId: UUID?,
        postId: UUID? = nil,
        change: Change = .updated,
        center: NotificationCenter = .default
    ) {
        var userInfo: [String: Any] = [
            postKindUserInfoKey: kind.rawValue,
            changeUserInfoKey: change.rawValue
        ]
        if let authorId {
            userInfo[authorIdUserInfoKey] = authorId
        }
        if let postId {
            userInfo[postIdUserInfoKey] = postId
        }
        center.post(name: postsDidChange, object: nil, userInfo: userInfo)
    }

    static func changedPostKind(from notification: Notification) -> PostKind? {
        guard let rawValue = notification.userInfo?[postKindUserInfoKey] as? String else {
            return nil
        }
        return PostKind(remoteValue: rawValue)
    }

    static func changedAuthorId(from notification: Notification) -> UUID? {
        notification.userInfo?[authorIdUserInfoKey] as? UUID
    }

    static func changedPostId(from notification: Notification) -> UUID? {
        notification.userInfo?[postIdUserInfoKey] as? UUID
    }

    static func change(from notification: Notification) -> Change {
        guard let rawValue = notification.userInfo?[changeUserInfoKey] as? String else {
            return .updated
        }
        return Change(rawValue: rawValue) ?? .updated
    }
}
