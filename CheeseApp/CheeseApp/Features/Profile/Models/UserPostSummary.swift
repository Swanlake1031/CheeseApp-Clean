import Foundation

struct UserPostSummary: Identifiable, Hashable {
    let id: UUID
    let kind: PostKind
    let title: String
    let description: String
    let subtitle: String
    let price: Double?
    let createdAt: Date
    let authorId: UUID
    let authorName: String
    let authorAvatarURL: String?
    var isPrivate: Bool = false
    var isArchived: Bool = false

    init(
        id: UUID,
        kind: PostKind,
        title: String,
        description: String,
        subtitle: String,
        price: Double?,
        createdAt: Date,
        authorId: UUID,
        authorName: String,
        authorAvatarURL: String?,
        isPrivate: Bool = false,
        isArchived: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.description = description
        self.subtitle = subtitle
        self.price = price
        self.createdAt = createdAt
        self.authorId = authorId
        self.authorName = authorName
        self.authorAvatarURL = authorAvatarURL
        self.isPrivate = isPrivate
        self.isArchived = isArchived
    }

    var relativeTimeText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }

    var priceDisplayText: String? {
        guard let price else { return nil }
        switch kind {
        case .secondhand:
            return Formatters.formatUSDCompact(price)
        case .forum:
            return nil
        }
    }

    var sharePayload: PostSharePayload {
        PostSharePayload(
            kind: kind,
            postId: id,
            title: title,
            subtitle: subtitle,
            summary: description
        )
    }
}
