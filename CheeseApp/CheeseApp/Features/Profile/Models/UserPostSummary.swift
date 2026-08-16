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

    func applying(_ payload: EditableUserPostPayload) -> UserPostSummary {
        guard payload.id == id, payload.kind == kind else { return self }

        let nextSubtitle: String
        switch kind {
        case .secondhand:
            if let details = payload.secondhandDetails {
                nextSubtitle = SecondhandPost.Condition.displayName(for: details.condition)
            } else {
                nextSubtitle = subtitle
            }
        case .forum:
            // The board name is resolved authoritatively by the event-driven
            // refresh. Keep the current label during the instant local commit.
            nextSubtitle = subtitle
        }

        return UserPostSummary(
            id: id,
            kind: kind,
            title: payload.title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: payload.description,
            subtitle: nextSubtitle,
            price: payload.price,
            createdAt: createdAt,
            authorId: authorId,
            authorName: authorName,
            authorAvatarURL: authorAvatarURL,
            isPrivate: payload.isPrivate,
            isArchived: isArchived
        )
    }
}
