import Foundation
import Supabase

enum SystemMessageKind: String, Decodable, Hashable {
    case automatic
    case mention
    case postLike = "post_like"
    case commentLike = "comment_like"
    case postComment = "post_comment"
    case commentReply = "comment_reply"
    case follow
    case secondhandAvailability = "secondhand_availability"
}

enum SystemMessageCTA: String, Decodable, Hashable {
    case none
    case viewPost = "view_post"
    case viewProfile = "view_profile"
    case secondhandAvailability = "secondhand_availability"
}

struct SystemMessageItem: Decodable, Identifiable, Hashable {
    let id: UUID
    let eventID: String
    let kind: SystemMessageKind
    let title: String
    let body: String
    let actorUserID: UUID?
    let actorName: String?
    let actorAvatarURL: String?
    let postID: UUID?
    let commentID: UUID?
    let contentKind: String?
    let ctaKind: SystemMessageCTA
    var readAt: Date?
    let createdAt: Date

    var postKind: PostKind? {
        guard let contentKind else { return nil }
        if contentKind == "comment" {
            return .forum
        }
        return PostKind(remoteValue: contentKind)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case eventID = "event_id"
        case kind
        case title
        case body
        case actorUserID = "actor_user_id"
        case actorName = "actor_name"
        case actorAvatarURL = "actor_avatar_url"
        case postID = "post_id"
        case commentID = "comment_id"
        case contentKind = "content_kind"
        case ctaKind = "cta_kind"
        case readAt = "read_at"
        case createdAt = "created_at"
    }
}

struct SystemMessageCursor: Equatable {
    let createdAt: Date
    let id: UUID
}

struct SystemMessagePage {
    let items: [SystemMessageItem]
    let nextCursor: SystemMessageCursor?
}

@MainActor
final class SystemMessageService: ObservableObject {
    static let shared = SystemMessageService()

    @Published private(set) var unreadCount = 0
    @Published private(set) var accountGeneration: UInt64 = 0

    private let supabase = SupabaseManager.shared
    private var stateOwnerID: UUID?
    private var isAccountTransitionInProgress = true
    private var unreadRefreshTask: Task<Void, Never>?
    private var unreadRefreshID: UUID?

    var isAccountScopeReady: Bool {
        !isAccountTransitionInProgress && stateOwnerID != nil
    }

    private init() {}

    func beginAccountTransition() {
        isAccountTransitionInProgress = true
        resetAccountState(ownerID: nil)
    }

    func activateAccount(_ userID: UUID?) {
        let mustReset = isAccountTransitionInProgress || stateOwnerID != userID
        isAccountTransitionInProgress = false
        guard mustReset else { return }
        resetAccountState(ownerID: userID)
    }

    func loadPage(
        after cursor: SystemMessageCursor? = nil,
        limit: Int = 30
    ) async throws -> SystemMessagePage {
        let requestGeneration = try requestGeneration()
        let rows: [SystemMessageItem] = try await supabase.client
            .rpc(
                "get_system_messages_page",
                params: SystemMessagesPageParams(
                    beforeCreatedAt: cursor?.createdAt,
                    beforeID: cursor?.id,
                    limit: limit
                )
            )
            .execute()
            .value
        try ensureCurrent(generation: requestGeneration)

        return SystemMessagePage(
            items: rows,
            nextCursor: rows.count == limit
                ? rows.last.map {
                    SystemMessageCursor(createdAt: $0.createdAt, id: $0.id)
                }
                : nil
        )
    }

    func refreshUnreadCount() async {
        guard let requestGeneration = try? requestGeneration() else {
            unreadCount = 0
            return
        }

        if let unreadRefreshTask {
            await unreadRefreshTask.value
            return
        }

        let refreshID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performUnreadCountRefresh(generation: requestGeneration)
        }
        unreadRefreshID = refreshID
        unreadRefreshTask = task
        await task.value

        if unreadRefreshID == refreshID {
            unreadRefreshTask = nil
            unreadRefreshID = nil
        }
    }

    private func performUnreadCountRefresh(generation requestGeneration: UInt64) async {
        do {
            let count: Int = try await supabase.client
                .rpc("get_system_message_unread_count")
                .execute()
                .value
            try ensureCurrent(generation: requestGeneration)
            unreadCount = max(count, 0)
        } catch {
            guard isCurrent(generation: requestGeneration) else { return }
            unreadCount = 0
        }
    }

    func markRead(messageID: UUID) async throws {
        let requestGeneration = try requestGeneration()
        let _: Bool = try await supabase.client
            .rpc(
                "mark_system_message_read",
                params: MarkSystemMessageReadParams(messageID: messageID)
            )
            .execute()
            .value
        try ensureCurrent(generation: requestGeneration)
        unreadCount = max(unreadCount - 1, 0)
    }

    func markAllRead() async throws {
        let requestGeneration = try requestGeneration()
        let _: Int = try await supabase.client
            .rpc("mark_all_system_messages_read")
            .execute()
            .value
        try ensureCurrent(generation: requestGeneration)
        unreadCount = 0
    }

    func respondToSecondhand(
        postID: UUID,
        action: SecondhandAvailabilityAction
    ) async throws {
        let requestGeneration = try requestGeneration()
        let _: [SecondhandAvailabilityResult] = try await supabase.client
            .rpc(
                "respond_secondhand_availability",
                params: SecondhandAvailabilityParams(
                    postID: postID,
                    action: action.rawValue
                )
            )
            .execute()
            .value
        try ensureCurrent(generation: requestGeneration)
        PostFeatureEvents.postDidChange(
            kind: .secondhand,
            authorId: stateOwnerID
        )
    }

    private func resetAccountState(ownerID: UUID?) {
        unreadRefreshTask?.cancel()
        unreadRefreshTask = nil
        unreadRefreshID = nil
        accountGeneration &+= 1
        stateOwnerID = ownerID
        unreadCount = 0
    }

    private func requestGeneration() throws -> UInt64 {
        guard isAccountScopeReady else { throw CancellationError() }
        return accountGeneration
    }

    private func isCurrent(generation: UInt64) -> Bool {
        isAccountScopeReady && accountGeneration == generation
    }

    private func ensureCurrent(generation: UInt64) throws {
        guard isCurrent(generation: generation) else {
            throw CancellationError()
        }
    }
}

enum SecondhandAvailabilityAction: String {
    case stillAvailable = "still_available"
    case sold
}

@MainActor
final class SystemMessageViewModel: ObservableObject {
    typealias PageLoader = (
        _ cursor: SystemMessageCursor?,
        _ limit: Int
    ) async throws -> SystemMessagePage
    typealias MessageAction = (UUID) async throws -> Void
    typealias AvailabilityAction = (
        UUID,
        SecondhandAvailabilityAction
    ) async throws -> Void

    @Published private(set) var items: [SystemMessageItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingNextPage = false
    @Published private(set) var hasMore = true
    @Published private(set) var hasResolvedInitialLoad = false
    @Published var errorMessage: String?
    @Published var actionMessage: String?

    private let pageSize: Int
    private let loadPage: PageLoader
    private let markReadAction: MessageAction
    private let markAllReadAction: () async throws -> Void
    private let availabilityAction: AvailabilityAction
    private var cursor: SystemMessageCursor?
    private var ownerID: UUID?

    init(
        pageSize: Int = 30,
        loadPage: @escaping PageLoader = {
            try await SystemMessageService.shared.loadPage(
                after: $0,
                limit: $1
            )
        },
        markRead: @escaping MessageAction = {
            try await SystemMessageService.shared.markRead(messageID: $0)
        },
        markAllRead: @escaping () async throws -> Void = {
            try await SystemMessageService.shared.markAllRead()
        },
        respondToSecondhand: @escaping AvailabilityAction = {
            try await SystemMessageService.shared.respondToSecondhand(
                postID: $0,
                action: $1
            )
        }
    ) {
        self.pageSize = pageSize
        self.loadPage = loadPage
        self.markReadAction = markRead
        self.markAllReadAction = markAllRead
        self.availabilityAction = respondToSecondhand
    }

    var loadState: CollectionLoadState {
        CollectionLoadState.resolve(
            hasResolvedInitialLoad: hasResolvedInitialLoad,
            isLoading: isLoading,
            hasContent: !items.isEmpty,
            errorMessage: errorMessage
        )
    }

    func activateAccount(_ userID: UUID?) {
        guard ownerID != userID else { return }
        ownerID = userID
        items = []
        cursor = nil
        isLoading = false
        isLoadingNextPage = false
        hasMore = true
        hasResolvedInitialLoad = false
        errorMessage = nil
        actionMessage = nil
    }

    func loadInitial(force: Bool = false) async {
        guard ownerID != nil else { return }
        guard !isLoading else { return }
        if hasResolvedInitialLoad && !force { return }

        let requestOwner = ownerID
        isLoading = true
        errorMessage = nil
        defer {
            if ownerID == requestOwner {
                isLoading = false
            }
        }

        do {
            let page = try await loadPage(nil, pageSize)
            guard ownerID == requestOwner else { return }
            items = page.items
            cursor = page.nextCursor
            hasMore = page.nextCursor != nil
            hasResolvedInitialLoad = true
        } catch {
            guard ownerID == requestOwner else { return }
            if error.isCancellationLike { return }
            errorMessage = error.localizedDescription
            hasResolvedInitialLoad = true
        }
    }

    func loadNextPageIfNeeded(currentItem: SystemMessageItem) async {
        guard currentItem.id == items.last?.id,
              hasMore,
              !isLoadingNextPage,
              let cursor
        else { return }

        let requestOwner = ownerID
        isLoadingNextPage = true
        defer {
            if ownerID == requestOwner {
                isLoadingNextPage = false
            }
        }

        do {
            let page = try await loadPage(cursor, pageSize)
            guard ownerID == requestOwner else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            self.cursor = page.nextCursor
            hasMore = page.nextCursor != nil
            errorMessage = nil
        } catch {
            guard ownerID == requestOwner else { return }
            if error.isCancellationLike { return }
            errorMessage = error.localizedDescription
        }
    }

    func markRead(_ item: SystemMessageItem) async {
        guard item.readAt == nil else { return }
        do {
            try await markReadAction(item.id)
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].readAt = Date()
            }
        } catch {
            if error.isCancellationLike { return }
            errorMessage = error.localizedDescription
        }
    }

    func markAllRead() async {
        do {
            try await markAllReadAction()
            let readAt = Date()
            for index in items.indices where items[index].readAt == nil {
                items[index].readAt = readAt
            }
        } catch {
            if error.isCancellationLike { return }
            errorMessage = error.localizedDescription
        }
    }

    func respond(
        to item: SystemMessageItem,
        action: SecondhandAvailabilityAction
    ) async {
        guard let postID = item.postID else {
            actionMessage = "该商品已不可用"
            return
        }
        do {
            try await availabilityAction(postID, action)
            await markRead(item)
            actionMessage = action == .sold
                ? "已标记为售出"
                : "已确认仍可购买"
        } catch {
            if error.isCancellationLike { return }
            actionMessage = error.localizedDescription
        }
    }
}

private struct SystemMessagesPageParams: Encodable {
    let beforeCreatedAt: Date?
    let beforeID: UUID?
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case beforeCreatedAt = "p_before_created_at"
        case beforeID = "p_before_id"
        case limit = "p_limit"
    }
}

private struct MarkSystemMessageReadParams: Encodable {
    let messageID: UUID

    enum CodingKeys: String, CodingKey {
        case messageID = "p_message_id"
    }
}

private struct SecondhandAvailabilityParams: Encodable {
    let postID: UUID
    let action: String

    enum CodingKeys: String, CodingKey {
        case postID = "p_post_id"
        case action = "p_action"
    }
}

private struct SecondhandAvailabilityResult: Decodable {
    let postID: UUID

    enum CodingKeys: String, CodingKey {
        case postID = "post_id"
    }
}
