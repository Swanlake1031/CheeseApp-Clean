import Foundation
import Supabase
import UIKit

struct ProfileViewerTargetCacheKey: Hashable {
    let viewerID: UUID
    let targetUserID: UUID
}

struct EditablePostImage: Identifiable, Hashable, Codable {
    let id: UUID
    let url: String
    let orderIndex: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case orderIndex = "order_index"
    }
}

struct EditableUserPostPayload {
    let id: UUID
    let kind: PostKind
    let title: String
    let description: String
    let price: Double?
    let secondhandDetails: SecondhandEditableFields?
    let forumDetails: ForumEditableFields?
    let isAnonymous: Bool?
    let isPrivate: Bool
    let retainedImageIDs: [UUID]
    let newImages: [UIImage]

    init(
        id: UUID,
        kind: PostKind,
        title: String,
        description: String,
        price: Double?,
        secondhandDetails: SecondhandEditableFields? = nil,
        forumDetails: ForumEditableFields? = nil,
        isAnonymous: Bool? = nil,
        isPrivate: Bool = false,
        retainedImageIDs: [UUID] = [],
        newImages: [UIImage] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.description = description
        self.price = price
        self.secondhandDetails = secondhandDetails
        self.forumDetails = forumDetails
        self.isAnonymous = isAnonymous
        self.isPrivate = isPrivate
        self.retainedImageIDs = retainedImageIDs
        self.newImages = newImages
    }
}

struct ForumEditableFields {
    let boardID: UUID?
    let allowComments: Bool
    let isAnonymous: Bool
    let images: [EditablePostImage]

    init(
        boardID: UUID?,
        allowComments: Bool,
        isAnonymous: Bool,
        images: [EditablePostImage] = []
    ) {
        self.boardID = boardID
        self.allowComments = allowComments
        self.isAnonymous = isAnonymous
        self.images = images
    }
}

struct ProfilePostContractRow: Decodable {
    let id: UUID
    let userId: UUID
    let type: String
    let title: String
    let description: String
    let status: String
    let isAnonymous: Bool
    let isPrivate: Bool
    let createdAt: Date
    let price: Double?
    let originalPrice: Double?
    let category: String?
    let condition: String?
    let isNegotiable: Bool?
    let boardID: UUID?
    let boardName: String?
    let allowComments: Bool?
    let userName: String?
    let userAvatar: String?
    let images: [EditablePostImage]

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case type
        case title
        case description
        case status
        case isAnonymous = "is_anonymous"
        case isPrivate = "is_private"
        case createdAt = "created_at"
        case price
        case originalPrice = "original_price"
        case category
        case condition
        case isNegotiable = "is_negotiable"
        case boardID = "board_id"
        case boardName = "board_name"
        case allowComments = "allow_comments"
        case userName = "user_name"
        case userAvatar = "user_avatar"
        case images
    }
}

@MainActor
final class UserPostsService: ObservableObject {
    private struct CachedSurface {
        let profile: Profile
        let posts: [UserPostSummary]
    }

    private static var surfaceCache: [
        ProfileViewerTargetCacheKey: CachedSurface
    ] = [:]

    @Published private(set) var profile: Profile?
    @Published private(set) var posts: [UserPostSummary] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var hasResolvedInitialSurfaceLoad = false

    private let supabase = SupabaseManager.shared
    private var activeViewerID: UUID?
    private var viewerGeneration: UInt64 = 0
    private var loadedUserId: UUID?

    var surfaceLoadState: CollectionLoadState {
        guard hasResolvedInitialSurfaceLoad else {
            return isLoading ? .initialLoading : .unresolved
        }

        if let errorMessage, !errorMessage.isEmpty, profile == nil {
            return .error(message: errorMessage)
        }

        return .loaded
    }

    @discardableResult
    func activateViewer(_ viewerID: UUID?) -> Bool {
        guard activeViewerID != viewerID else { return false }
        activeViewerID = viewerID
        viewerGeneration &+= 1
        loadedUserId = nil
        profile = nil
        posts = []
        isLoading = false
        errorMessage = nil
        hasResolvedInitialSurfaceLoad = false
        return true
    }

    func restoreCachedSurface(userId: UUID) -> Bool {
        synchronizeViewerWithCurrentAccount()
        guard let key = currentCacheKey(targetUserID: userId),
              let cached = Self.surfaceCache[key]
        else { return false }
        loadedUserId = userId
        profile = cached.profile
        posts = cached.posts
        errorMessage = nil
        hasResolvedInitialSurfaceLoad = true
        return true
    }

    func primeProfile(_ profile: Profile, for userId: UUID) {
        synchronizeViewerWithCurrentAccount()
        guard let key = currentCacheKey(targetUserID: userId),
              loadedUserId == userId || Self.surfaceCache[key] != nil
        else { return }
        loadedUserId = userId
        self.profile = profile
        hasResolvedInitialSurfaceLoad = true
        syncCache(userId: userId)
    }

    func load(userId: UUID, forceRefresh: Bool = false) async {
        synchronizeViewerWithCurrentAccount()
        if !forceRefresh, restoreCachedSurface(userId: userId) {
            return
        }

        guard let requestViewerID = activeViewerID,
              !isLoading
        else { return }
        let requestGeneration = viewerGeneration
        isLoading = true
        errorMessage = nil
        defer {
            if isCurrentViewerRequest(
                viewerID: requestViewerID,
                generation: requestGeneration
            ) {
                isLoading = false
            }
        }

        do {
            async let profileTask = ProfileService.fetchProfile(userId: userId)
            async let postsTask = fetchPosts(userId: userId)
            let loadedProfile = try await profileTask
            let loadedPosts = try await postsTask
            guard isCurrentViewerRequest(
                viewerID: requestViewerID,
                generation: requestGeneration
            ) else { return }
            loadedUserId = userId
            profile = loadedProfile
            posts = loadedPosts
            hasResolvedInitialSurfaceLoad = true
            syncCache(userId: userId)
        } catch {
            guard isCurrentViewerRequest(
                viewerID: requestViewerID,
                generation: requestGeneration
            ) else { return }
            if error.isCancellationLike { return }
            errorMessage = error.localizedDescription
            hasResolvedInitialSurfaceLoad = true
        }
    }

    func refreshPosts(userId: UUID) async {
        synchronizeViewerWithCurrentAccount()
        guard let requestViewerID = activeViewerID else { return }
        let requestGeneration = viewerGeneration
        do {
            let loadedPosts = try await fetchPosts(userId: userId)
            guard isCurrentViewerRequest(
                viewerID: requestViewerID,
                generation: requestGeneration
            ) else { return }
            loadedUserId = userId
            posts = loadedPosts
            syncCache(userId: userId)
        } catch {
            guard isCurrentViewerRequest(
                viewerID: requestViewerID,
                generation: requestGeneration
            ) else { return }
            if error.isCancellationLike { return }
            errorMessage = error.localizedDescription
        }
    }

    func fetchPostCount(userId: UUID) async throws -> Int {
        let response = try await supabase
            .database("posts")
            .select("id", head: true, count: .exact)
            .eq("user_id", value: userId.uuidString)
            .execute()
        return max(response.count ?? 0, 0)
    }

    func fetchPostPrivacy(postId: UUID, userId: UUID) async throws -> Bool {
        let row: PostPrivacyRow = try await supabase
            .database("posts")
            .select("id,is_private")
            .eq("id", value: postId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .single()
            .execute()
            .value
        return row.isPrivate
    }

    private func syncCache(userId: UUID) {
        guard let profile,
              let key = currentCacheKey(targetUserID: userId)
        else { return }
        Self.surfaceCache[key] = CachedSurface(profile: profile, posts: posts)
    }

    private func synchronizeViewerWithCurrentAccount() {
        let currentViewerID = AuthService.shared.currentUser?.id
        if activeViewerID != currentViewerID {
            activateViewer(currentViewerID)
        }
    }

    private func currentCacheKey(
        targetUserID: UUID
    ) -> ProfileViewerTargetCacheKey? {
        guard let activeViewerID,
              AuthService.shared.currentUser?.id == activeViewerID
        else { return nil }
        return ProfileViewerTargetCacheKey(
            viewerID: activeViewerID,
            targetUserID: targetUserID
        )
    }

    private func isCurrentViewerRequest(
        viewerID: UUID,
        generation: UInt64
    ) -> Bool {
        activeViewerID == viewerID
            && viewerGeneration == generation
            && AuthService.shared.currentUser?.id == viewerID
    }

    func update(payload: EditableUserPostPayload) async throws {
        switch payload.kind {
        case .secondhand:
            try await SecondhandService.shared.updatePost(payload: payload)
        case .forum:
            try await ForumService.shared.updatePost(
                payload: payload,
                retainedImageIDs: payload.retainedImageIDs,
                newImages: payload.newImages
            )
        }
    }

    func delete(postId: UUID) async throws {
        let deletionEvent = try? await deletionEventPayload(for: postId)
        if let deletionEvent {
            switch deletionEvent.kind {
            case .secondhand:
                try await SecondhandService.shared.deletePost(
                    postId: postId,
                    authorId: deletionEvent.authorId
                )
            case .forum:
                try await ForumService.shared.deletePost(postID: postId)
            }
        } else {
            try await deleteBasePost(postId: postId)
        }

        posts.removeAll { $0.id == postId }
        if let loadedUserId {
            syncCache(userId: loadedUserId)
        }
    }

    func setPostHidden(postId: UUID, hidden: Bool) async throws {
        let resolvedHidden: Bool = try await supabase.client.rpc(
            "set_my_post_hidden",
            params: SetPostHiddenParams(postID: postId, hidden: hidden)
        ).execute().value

        guard let index = posts.firstIndex(where: { $0.id == postId }) else { return }
        posts[index].isPrivate = resolvedHidden
        if let loadedUserId {
            syncCache(userId: loadedUserId)
        }
        PostFeatureEvents.postDidChange(
            kind: posts[index].kind,
            authorId: posts[index].authorId
        )
    }

    private func deleteBasePost(postId: UUID) async throws {
        try await supabase
            .database("posts")
            .delete()
            .eq("id", value: postId.uuidString)
            .execute()
    }

    func fetchForumEditFields(postId: UUID) async throws -> ForumEditableFields {
        let userID = try await AuthService.shared.requireAuthUserId()
        let row: ProfilePostContractRow = try await supabase.client
            .rpc("get_profile_posts", params: ProfilePostsParams(userID: userID))
            .eq("id", value: postId.uuidString)
            .single()
            .execute()
            .value

        return ForumEditableFields(
            boardID: row.boardID,
            allowComments: row.allowComments ?? true,
            isAnonymous: row.isAnonymous,
            images: row.images.sorted {
                ($0.orderIndex ?? Int.max) < ($1.orderIndex ?? Int.max)
            }
        )
    }

    private func fetchPosts(userId: UUID) async throws -> [UserPostSummary] {
        let rows: [ProfilePostContractRow] = try await supabase.client.rpc(
            "get_profile_posts",
            params: ProfilePostsParams(userID: userId)
        ).execute().value

        return rows.compactMap { row in
            guard let kind = PostKind(remoteValue: row.type) else { return nil }
            let subtitle: String
            switch kind {
            case .secondhand:
                subtitle = SecondhandPost.Condition.displayName(
                    for: row.condition ?? SecondhandPost.Condition.good.rawValue
                )
            case .forum:
                subtitle = row.boardName ?? "论坛"
            }

            return UserPostSummary(
                id: row.id,
                kind: kind,
                title: row.title,
                description: row.description,
                subtitle: subtitle,
                price: row.price,
                createdAt: row.createdAt,
                authorId: row.userId,
                authorName: row.userName ?? "未知用户",
                authorAvatarURL: row.userAvatar,
                isPrivate: row.isPrivate,
                isArchived: row.status != "active"
            )
        }
    }

    private func deletionEventPayload(for postId: UUID) async throws -> DeletionEventPayload? {
        if let existingPost = posts.first(where: { $0.id == postId }) {
            return DeletionEventPayload(kind: existingPost.kind, authorId: existingPost.authorId)
        }

        let row: PostDeletionEventRow = try await supabase
            .database("posts")
            .select("type,user_id")
            .eq("id", value: postId.uuidString)
            .single()
            .execute()
            .value

        guard let kind = PostKind(remoteValue: row.type) else {
            return nil
        }

        return DeletionEventPayload(kind: kind, authorId: row.userId)
    }

    private func fetchSecondhandPosts(userId: UUID) async throws -> [UserPostSummary] {
        let rows: [UserSecondhandRow] = try await supabase
            .database("secondhand_posts_view")
            .select("id,user_id,title,description,price,condition,created_at,user_name,user_avatar")
            .eq("user_id", value: userId.uuidString)
            .order("created_at", ascending: false)
            .limit(100)
            .execute()
            .value

        return rows.map {
            UserPostSummary(
                id: $0.id,
                kind: .secondhand,
                title: $0.title,
                description: $0.description ?? "",
                subtitle: SecondhandPost.Condition.displayName(for: $0.condition),
                price: $0.price,
                createdAt: $0.createdAt,
                authorId: $0.userId,
                authorName: $0.userName ?? "未知用户",
                authorAvatarURL: $0.userAvatar
            )
        }
    }

    private func fetchForumPosts(userId: UUID) async throws -> [UserPostSummary] {
        let currentUserId = AuthService.shared.currentUser?.id
        let rows: [UserForumRow] = try await supabase
            .database("forum_posts_view")
            .select("id,user_id,title,description,board_name,is_anonymous,created_at,user_name,user_avatar")
            .eq("user_id", value: userId.uuidString)
            .order("created_at", ascending: false)
            .limit(100)
            .execute()
            .value

        return rows
            .filter { row in
                // Anonymous forum posts are only visible to their own author.
                !row.isAnonymous || row.userId == currentUserId
            }
            .map {
            UserPostSummary(
                id: $0.id,
                kind: .forum,
                title: $0.title,
                description: $0.description ?? "",
                subtitle: $0.boardName,
                price: nil,
                createdAt: $0.createdAt,
                authorId: $0.userId,
                authorName: $0.userName ?? "未知用户",
                authorAvatarURL: $0.userAvatar
            )
        }
    }

    private func fetchPostPrivacyMap(userId: UUID) async throws -> [UUID: Bool] {
        let rows: [PostPrivacyRow] = try await supabase
            .database("posts")
            .select("id,is_private")
            .eq("user_id", value: userId.uuidString)
            .limit(500)
            .execute()
            .value

        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.isPrivate) })
    }

}

private struct ProfilePostsParams: Encodable {
    let userID: UUID

    enum CodingKeys: String, CodingKey {
        case userID = "p_user_id"
    }
}

private struct SetPostHiddenParams: Encodable {
    let postID: UUID
    let hidden: Bool

    enum CodingKeys: String, CodingKey {
        case postID = "p_post_id"
        case hidden = "p_hidden"
    }
}

private struct DeletionEventPayload {
    let kind: PostKind
    let authorId: UUID
}

private struct PostDeletionEventRow: Decodable {
    let type: String
    let userId: UUID

    enum CodingKeys: String, CodingKey {
        case type
        case userId = "user_id"
    }
}

private struct UserSecondhandRow: Codable {
    let id: UUID
    let userId: UUID
    let title: String
    let description: String?
    let price: Double
    let condition: String
    let createdAt: Date
    let userName: String?
    let userAvatar: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case description
        case price
        case condition
        case createdAt = "created_at"
        case userName = "user_name"
        case userAvatar = "user_avatar"
    }
}

private struct UserForumRow: Codable {
    let id: UUID
    let userId: UUID
    let title: String
    let description: String?
    let boardName: String
    let isAnonymous: Bool
    let createdAt: Date
    let userName: String?
    let userAvatar: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case description
        case boardName = "board_name"
        case isAnonymous = "is_anonymous"
        case createdAt = "created_at"
        case userName = "user_name"
        case userAvatar = "user_avatar"
    }
}

private struct PostPrivacyRow: Codable {
    let id: UUID
    let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case isPrivate = "is_private"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
