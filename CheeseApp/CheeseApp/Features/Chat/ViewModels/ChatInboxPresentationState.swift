import Foundation

enum ChatInboxRoute: Hashable, Identifiable {
    case systemMessages(SystemMessageCategory)
    case group(ChatGroupPreview)
    case conversation(ChatConversationPreview)
    case profile(UUID)

    var id: String {
        switch self {
        case .systemMessages(let category):
            return "system-messages:\(category.rawValue)"
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
    case pinned
    case conversations

    var id: String { rawValue }

    var title: String? {
        nil
    }
}

enum ChatInboxSectionItem: Hashable, Identifiable {
    case group(ChatGroupPreview)
    case direct(ChatConversationPreview)

    var id: UUID {
        switch self {
        case .group(let group):
            return group.id
        case .direct(let conversation):
            return conversation.id
        }
    }

    var isPinned: Bool {
        switch self {
        case .group(let group): return group.isPinned
        case .direct(let conversation): return conversation.isPinned
        }
    }

    var lastMessageAt: Date {
        switch self {
        case .group(let group): return group.lastMessageAt
        case .direct(let conversation): return conversation.lastMessageAt
        }
    }
}

struct ChatInboxSection: Hashable, Identifiable {
    let kind: ChatInboxSectionKind
    let items: [ChatInboxSectionItem]

    var id: ChatInboxSectionKind { kind }
    var title: String? { kind.title }
}

struct ChatInboxPresentationState {
    let searchText: String
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

    var visibleSections: [ChatInboxSection] {
        let items = sortedItems(matchingSearch: isSearching)
        guard !items.isEmpty else { return [] }

        if isSearching {
            return [ChatInboxSection(kind: .conversations, items: items)]
        }

        let pinned = items.filter(\.isPinned)
        let regular = items.filter { !$0.isPinned }
        return [
            pinned.isEmpty ? nil : ChatInboxSection(kind: .pinned, items: pinned),
            regular.isEmpty ? nil : ChatInboxSection(kind: .conversations, items: regular)
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

    private func sortedItems(matchingSearch: Bool) -> [ChatInboxSectionItem] {
        let directItems = directConversations
            .filter { !matchingSearch || matchesConversation($0) }
            .map(ChatInboxSectionItem.direct)
        let groupItems = groupConversations
            .filter { !matchingSearch || matchesGroup($0) }
            .map(ChatInboxSectionItem.group)

        return (directItems + groupItems).sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            if lhs.lastMessageAt != rhs.lastMessageAt {
                return lhs.lastMessageAt > rhs.lastMessageAt
            }
            return lhs.id.uuidString > rhs.id.uuidString
        }
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
