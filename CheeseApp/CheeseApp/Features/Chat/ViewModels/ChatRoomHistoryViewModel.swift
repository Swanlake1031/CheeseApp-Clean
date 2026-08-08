import Combine
import Foundation

@MainActor
final class ChatRoomHistoryViewModel: ObservableObject {
    typealias MessageLoader = (
        UUID,
        ChatMessagePageCursor?
    ) async throws -> ChatMessagePage<Message>

    @Published var queryText = ""
    @Published private(set) var messages: [Message] = []
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var pageErrorMessage: String?

    private let conversationID: UUID
    private let loadMessages: MessageLoader
    private var hasLoaded = false
    private var cursor: ChatMessagePageCursor?
    private var pageRequestID: UUID?

    init(
        conversationID: UUID,
        loadMessages: @escaping MessageLoader = { conversationID, cursor in
            try await ChatService.shared.fetchMessagesPage(
                conversationId: conversationID,
                before: cursor
            )
        }
    ) {
        self.conversationID = conversationID
        self.loadMessages = loadMessages
    }

    var filteredMessages: [Message] {
        let query = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return messages }

        return messages.filter { message in
            if message.messageType == "image" {
                return "图片消息".localizedCaseInsensitiveContains(query)
            }
            return message.content.localizedCaseInsensitiveContains(query)
        }
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoading = true
        errorMessage = nil

        do {
            let page = try await loadMessages(conversationID, nil)
            messages = sortedUnique(page.messages)
            cursor = page.nextCursor
            hasMore = page.nextCursor != nil
        } catch {
            messages = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadMore() async {
        guard !isLoadingMore, let cursor else { return }
        let requestID = UUID()
        pageRequestID = requestID
        isLoadingMore = true
        pageErrorMessage = nil

        do {
            let page = try await loadMessages(conversationID, cursor)
            guard pageRequestID == requestID else { return }
            messages = sortedUnique(messages + page.messages)
            self.cursor = page.nextCursor
            hasMore = page.nextCursor != nil
        } catch {
            guard pageRequestID == requestID else { return }
            pageErrorMessage = error.localizedDescription
        }

        guard pageRequestID == requestID else { return }
        pageRequestID = nil
        isLoadingMore = false
    }

    private func sortedUnique(_ values: [Message]) -> [Message] {
        var seen = Set<UUID>()
        return values
            .filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString > $1.id.uuidString
            }
    }
}
