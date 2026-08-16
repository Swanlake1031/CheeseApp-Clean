import Foundation
import Combine
import Supabase

extension Error {
    var isCancellationLike: Bool {
        if self is CancellationError { return true }
        let nsError = self as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        // Some networking libraries wrap URLSession cancellation and only retain its
        // localized message. Keep this deliberately narrow so real transport failures
        // still surface to the user.
        let message = localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return message == "cancelled"
            || message == "canceled"
            || message == "the operation was cancelled."
            || message == "the operation was canceled."
    }
}

struct PostReactionState {
    let isLiked: Bool
}

struct PostInteractionState: Equatable {
    var likeCount: Int
    var isLiked: Bool
    var isFavorited: Bool
}

@MainActor
final class PostInteractionStore: ObservableObject {
    static let shared = PostInteractionStore()

    struct Update {
        let postID: UUID
        let likeCount: Int?
        let isLiked: Bool?
        let isFavorited: Bool?

        init(
            postID: UUID,
            likeCount: Int? = nil,
            isLiked: Bool? = nil,
            isFavorited: Bool? = nil
        ) {
            self.postID = postID
            self.likeCount = likeCount
            self.isLiked = isLiked
            self.isFavorited = isFavorited
        }
    }

    private struct StoredState: Equatable {
        var likeCount: Int?
        var isLiked: Bool?
        var isFavorited: Bool?
    }

    @Published private(set) var revision: UInt64 = 0

    private var states: [UUID: StoredState] = [:]
    private var ownerID: UUID?
    private var pendingLikePostIDs: Set<UUID> = []
    private var protectedLikeStates: [UUID: Bool] = [:]

    private init() {}

    func activateAccount(_ userID: UUID?) {
        guard ownerID != userID else { return }
        ownerID = userID
        states.removeAll()
        pendingLikePostIDs.removeAll()
        protectedLikeStates.removeAll()
        revision &+= 1
    }

    /// Reserves a post-wide like mutation and protects its optimistic value from
    /// older list/detail requests that may complete while the mutation is running.
    func beginLikeMutation(postID: UUID, desiredIsLiked: Bool) -> Bool {
        guard pendingLikePostIDs.insert(postID).inserted else { return false }
        protectedLikeStates[postID] = desiredIsLiked
        return true
    }

    /// A successful value remains protected until an authoritative snapshot
    /// observes the same value. This prevents a request that started before the
    /// mutation from reverting the heart after the request has completed.
    func finishLikeMutation(postID: UUID, committedIsLiked: Bool?) {
        pendingLikePostIDs.remove(postID)
        if let committedIsLiked {
            protectedLikeStates[postID] = committedIsLiked
        } else {
            protectedLikeStates.removeValue(forKey: postID)
        }
    }

    func state(
        for postID: UUID,
        fallbackLikeCount: Int = 0,
        fallbackIsLiked: Bool = false,
        fallbackIsFavorited: Bool = false
    ) -> PostInteractionState {
        let stored = states[postID]
        return PostInteractionState(
            likeCount: stored?.likeCount ?? fallbackLikeCount,
            isLiked: stored?.isLiked ?? fallbackIsLiked,
            isFavorited: stored?.isFavorited ?? fallbackIsFavorited
        )
    }

    func merge(
        postID: UUID,
        likeCount: Int? = nil,
        isLiked: Bool? = nil,
        isFavorited: Bool? = nil
    ) {
        let previous = states[postID] ?? StoredState()
        let updated = StoredState(
            likeCount: likeCount ?? previous.likeCount,
            isLiked: isLiked ?? previous.isLiked,
            isFavorited: isFavorited ?? previous.isFavorited
        )
        guard updated != previous else { return }
        states[postID] = updated
        revision &+= 1
    }

    func merge(_ updates: [Update]) {
        var didChange = false
        for update in updates {
            let previous = states[update.postID] ?? StoredState()
            let updated = StoredState(
                likeCount: update.likeCount ?? previous.likeCount,
                isLiked: update.isLiked ?? previous.isLiked,
                isFavorited: update.isFavorited ?? previous.isFavorited
            )
            guard updated != previous else { continue }
            states[update.postID] = updated
            didChange = true
        }
        if didChange {
            revision &+= 1
        }
    }

    /// Merges server-owned snapshots without allowing an older response to
    /// overwrite an optimistic or newly committed like mutation.
    func mergeServerSnapshots(_ updates: [Update]) {
        var didChange = false
        for update in updates {
            let previous = states[update.postID] ?? StoredState()
            var nextLikeCount = update.likeCount ?? previous.likeCount
            var nextIsLiked = update.isLiked ?? previous.isLiked

            if let protectedIsLiked = protectedLikeStates[update.postID] {
                if let snapshotIsLiked = update.isLiked,
                   snapshotIsLiked == protectedIsLiked {
                    // A matching snapshot is authoritative only after the write
                    // itself has completed. While it is still pending, keep the
                    // guard in place for any older request that may arrive next.
                    if !pendingLikePostIDs.contains(update.postID) {
                        protectedLikeStates.removeValue(forKey: update.postID)
                    }
                } else {
                    nextLikeCount = previous.likeCount
                    nextIsLiked = previous.isLiked
                }
            }

            let updated = StoredState(
                likeCount: nextLikeCount,
                isLiked: nextIsLiked,
                isFavorited: update.isFavorited ?? previous.isFavorited
            )
            guard updated != previous else { continue }
            states[update.postID] = updated
            didChange = true
        }
        if didChange {
            revision &+= 1
        }
    }

    func replace(postID: UUID, with state: PostInteractionState) {
        let updated = StoredState(
            likeCount: state.likeCount,
            isLiked: state.isLiked,
            isFavorited: state.isFavorited
        )
        guard states[postID] != updated else { return }
        states[postID] = updated
        revision &+= 1
    }

    func setLike(postID: UUID, isLiked: Bool, fallbackLikeCount: Int = 0) {
        let current = state(
            for: postID,
            fallbackLikeCount: fallbackLikeCount
        )
        guard current.isLiked != isLiked else {
            merge(postID: postID, likeCount: current.likeCount, isLiked: isLiked)
            return
        }
        merge(
            postID: postID,
            likeCount: max(current.likeCount + (isLiked ? 1 : -1), 0),
            isLiked: isLiked
        )
    }

    func setFavorite(postID: UUID, isFavorited: Bool) {
        merge(postID: postID, isFavorited: isFavorited)
    }
}

@MainActor
final class PostActivityMutationCenter: ObservableObject {
    static let shared = PostActivityMutationCenter()

    @Published private(set) var likedRevision: UInt64 = 0
    @Published private(set) var favoritedRevision: UInt64 = 0

    private init() {}

    func markLikedChanged() {
        likedRevision &+= 1
    }

    func markFavoritedChanged() {
        favoritedRevision &+= 1
    }
}

@MainActor
final class PostReactionService {
    static let shared = PostReactionService()

    private let supabase = SupabaseManager.shared

    private init() {}

    func fetchStates(postIds: [UUID]) async -> [UUID: PostReactionState] {
        guard !postIds.isEmpty else { return [:] }

        let ids = postIds.map { $0 as any PostgrestFilterValue }

        var likedSet: Set<UUID> = []
        guard let userId = try? await AuthService.shared.requireAuthUserId() else {
            return Dictionary(
                uniqueKeysWithValues: postIds.map {
                    ($0, PostReactionState(isLiked: false))
                }
            )
        }

        do {
            let likedRows: [ReactionLikeTargetRow] = try await supabase
                .database("likes")
                .select("target_id")
                .eq("target_type", value: "post")
                .eq("user_id", value: userId.uuidString)
                .`in`("target_id", values: ids)
                .execute()
                .value
            likedSet = Set(likedRows.map(\.targetId))
        } catch {
            return [:]
        }

        return Dictionary(
            uniqueKeysWithValues: postIds.map {
                ($0, PostReactionState(isLiked: likedSet.contains($0)))
            }
        )
    }

    func toggle(postId: UUID, currentlyLiked: Bool) async throws -> Bool {
        let userId: UUID
        do {
            userId = try await AuthService.shared.requireAuthUserId()
        } catch {
            await AuthService.shared.checkSession()
            throw NSError(
                domain: "",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Please sign in before liking posts"]
            )
        }

        if currentlyLiked {
            try await supabase
                .database("likes")
                .delete()
                .eq("user_id", value: userId.uuidString)
                .eq("target_type", value: "post")
                .eq("target_id", value: postId.uuidString)
                .execute()
            PostActivityMutationCenter.shared.markLikedChanged()
            PostInteractionStore.shared.setLike(postID: postId, isLiked: false)
            return false
        }

        do {
            try await supabase
                .database("likes")
                .insert(ReactionLikeInsert(userId: userId, targetType: "post", targetId: postId))
                .execute()
            PostActivityMutationCenter.shared.markLikedChanged()
            PostInteractionStore.shared.setLike(postID: postId, isLiked: true)
            return true
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("duplicate key") || message.contains("unique") {
                PostActivityMutationCenter.shared.markLikedChanged()
                PostInteractionStore.shared.setLike(postID: postId, isLiked: true)
                return true
            }
            throw error
        }
    }

}

@MainActor
final class PostFavoriteService {
    static let shared = PostFavoriteService()

    private let supabase = SupabaseManager.shared

    private init() {}

    func fetchFavoritePostIds(postIds: [UUID]) async -> Set<UUID> {
        guard !postIds.isEmpty else { return [] }

        let userId: UUID
        do {
            userId = try await AuthService.shared.requireAuthUserId()
        } catch {
            return []
        }

        do {
            let rows: [PostFavoriteRow] = try await supabase
                .database(Tables.favorites)
                .select("post_id")
                .eq("user_id", value: userId.uuidString)
                .`in`("post_id", values: postIds.map { $0 as any PostgrestFilterValue })
                .execute()
                .value
            return Set(rows.map(\.postId))
        } catch {
            return []
        }
    }

    func toggleFavorite(
        postId: UUID,
        currentlyFavorited: Bool,
        unauthorizedMessage: String = L10n.tr("Please sign in before saving posts", "收藏前请先登录")
    ) async throws -> Bool {
        let userId: UUID
        do {
            userId = try await AuthService.shared.requireAuthUserId()
        } catch {
            await AuthService.shared.checkSession()
            throw NSError(
                domain: "",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: unauthorizedMessage]
            )
        }

        if currentlyFavorited {
            try await supabase
                .database(Tables.favorites)
                .delete()
                .eq("user_id", value: userId.uuidString)
                .eq("post_id", value: postId.uuidString)
                .execute()
            PostActivityMutationCenter.shared.markFavoritedChanged()
            PostInteractionStore.shared.setFavorite(postID: postId, isFavorited: false)
            return false
        }

        do {
            try await supabase
                .database(Tables.favorites)
                .insert(PostFavoriteInsert(userId: userId, postId: postId))
                .execute()
            PostActivityMutationCenter.shared.markFavoritedChanged()
            PostInteractionStore.shared.setFavorite(postID: postId, isFavorited: true)
            return true
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("duplicate key") || message.contains("unique") {
                PostActivityMutationCenter.shared.markFavoritedChanged()
                PostInteractionStore.shared.setFavorite(postID: postId, isFavorited: true)
                return true
            }
            throw error
        }
    }
}

private struct ReactionLikeTargetRow: Codable {
    let targetId: UUID

    enum CodingKeys: String, CodingKey {
        case targetId = "target_id"
    }
}

private struct ReactionLikeInsert: Encodable {
    let userId: UUID
    let targetType: String
    let targetId: UUID

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case targetType = "target_type"
        case targetId = "target_id"
    }
}

private struct PostFavoriteRow: Decodable {
    let postId: UUID

    enum CodingKeys: String, CodingKey {
        case postId = "post_id"
    }
}

private struct PostFavoriteInsert: Encodable {
    let userId: UUID
    let postId: UUID

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case postId = "post_id"
    }
}
