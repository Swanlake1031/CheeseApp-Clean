import Foundation

enum ChatInboxRoute: Hashable, Identifiable {
    case systemMessages
    case messageRequests
    case group(ChatGroupPreview)
    case conversation(ChatConversationPreview)
    case profile(UUID)

    var id: String {
        switch self {
        case .systemMessages:
            return "system-messages"
        case .messageRequests:
            return "message-requests"
        case .group(let group):
            return "group:\(group.id.uuidString)"
        case .conversation(let conversation):
            return "conversation:\(conversation.id.uuidString)"
        case .profile(let userID):
            return "profile:\(userID.uuidString)"
        }
    }
}

enum ChatInboxSectionKind: String, Hashable, Identifiable {
    case messageRequests
    case groups
    case directMessages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messageRequests:
            return "陌生人消息"
        case .groups:
            return "群聊"
        case .directMessages:
            return "私信"
        }
    }
}

enum ChatInboxSectionItem: Hashable, Identifiable {
    case messageRequest(ChatConversationPreview)
    case group(ChatGroupPreview)
    case direct(ChatConversationPreview)

    var id: UUID {
        switch self {
        case .messageRequest(let conversation):
            return conversation.id
        case .group(let group):
            return group.id
        case .direct(let conversation):
            return conversation.id
        }
    }
}

struct ChatInboxSection: Hashable, Identifiable {
    let kind: ChatInboxSectionKind
    let items: [ChatInboxSectionItem]

    var id: ChatInboxSectionKind { kind }
    var title: String { kind.title }
}

struct ChatInboxPresentationState {
    let searchText: String
    let messageRequests: [ChatConversationPreview]
    let directConversations: [ChatConversationPreview]
    let groupConversations: [ChatGroupPreview]
    let displayNamesByConversationId: [UUID: String]

    private var searchTokens: [String] {
        Self.normalize(searchText)
            .split(separator: " ")
            .map(String.init)
    }

    var isSearching: Bool {
        !searchTokens.isEmpty
    }

    var showsMessageRequestsShortcut: Bool {
        !isSearching && !messageRequests.isEmpty
    }

    var visibleSections: [ChatInboxSection] {
        if isSearching {
            return [
                makeConversationSection(
                    kind: .messageRequests,
                    conversations: messageRequests,
                    itemBuilder: ChatInboxSectionItem.messageRequest
                ),
                makeGroupSection(),
                makeConversationSection(
                    kind: .directMessages,
                    conversations: directConversations,
                    itemBuilder: ChatInboxSectionItem.direct
                )
            ].compactMap { $0 }
        }

        return [
            makeGroupSection(includeAllWhenBrowsing: true),
            makeConversationSection(
                kind: .directMessages,
                conversations: directConversations,
                itemBuilder: ChatInboxSectionItem.direct,
                includeAllWhenBrowsing: true
            )
        ].compactMap { $0 }
    }

    var visibleItemCount: Int {
        visibleSections.reduce(0) { $0 + $1.items.count }
    }

    var showsSearchEmptyState: Bool {
        isSearching && visibleSections.isEmpty
    }

    var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeConversationSection(
        kind: ChatInboxSectionKind,
        conversations: [ChatConversationPreview],
        itemBuilder: (ChatConversationPreview) -> ChatInboxSectionItem,
        includeAllWhenBrowsing: Bool = false
    ) -> ChatInboxSection? {
        let items: [ChatInboxSectionItem]
        if includeAllWhenBrowsing && !isSearching {
            items = conversations.map(itemBuilder)
        } else {
            items = conversations.filter(matchesConversation).map(itemBuilder)
        }

        guard !items.isEmpty else { return nil }
        return ChatInboxSection(kind: kind, items: items)
    }

    private func makeGroupSection(includeAllWhenBrowsing: Bool = false) -> ChatInboxSection? {
        let items: [ChatInboxSectionItem]
        if includeAllWhenBrowsing && !isSearching {
            items = groupConversations.map(ChatInboxSectionItem.group)
        } else {
            items = groupConversations.filter(matchesGroup).map(ChatInboxSectionItem.group)
        }

        guard !items.isEmpty else { return nil }
        return ChatInboxSection(kind: .groups, items: items)
    }

    private func matchesConversation(_ conversation: ChatConversationPreview) -> Bool {
        matches(
            [
                displayNamesByConversationId[conversation.id],
                conversation.otherUserName,
                conversation.lastMessagePreview
            ]
        )
    }

    private func matchesGroup(_ group: ChatGroupPreview) -> Bool {
        matches(
            [
                group.displayName,
                group.lastMessagePreview
            ]
        )
    }

    private func matches(_ fields: [String?]) -> Bool {
        guard !searchTokens.isEmpty else { return true }
        let haystack = Self.normalize(
            fields
                .compactMap { value -> String? in
                    guard let value else { return nil }
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                .joined(separator: " ")
        )
        return searchTokens.allSatisfy(haystack.contains)
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
