import Foundation

enum ProfileSocialEvents {
    static let followingDidChange = Notification.Name("ProfileFollowingDidChangeNotification")
    private static let targetUserIDKey = "targetUserID"
    private static let isFollowingKey = "isFollowing"

    static func followingDidChange(
        targetUserID: UUID,
        isFollowing: Bool,
        center: NotificationCenter = .default
    ) {
        center.post(
            name: followingDidChange,
            object: nil,
            userInfo: [
                targetUserIDKey: targetUserID,
                isFollowingKey: isFollowing
            ]
        )
    }

    static func change(from notification: Notification) -> (UUID, Bool)? {
        guard let targetUserID = notification.userInfo?[targetUserIDKey] as? UUID,
              let isFollowing = notification.userInfo?[isFollowingKey] as? Bool
        else { return nil }
        return (targetUserID, isFollowing)
    }
}

struct ProfileSocialSummary: Decodable, Equatable {
    let followerCount: Int
    let followingCount: Int
    let amFollowing: Bool
    let followsMe: Bool
    let isMutualFollow: Bool

    static let empty = ProfileSocialSummary(
        followerCount: 0,
        followingCount: 0,
        amFollowing: false,
        followsMe: false,
        isMutualFollow: false
    )

    enum CodingKeys: String, CodingKey {
        case followerCount = "follower_count"
        case followingCount = "following_count"
        case amFollowing = "am_following"
        case followsMe = "follows_me"
        case isMutualFollow = "is_mutual_follow"
    }

    func applyingViewerFollowState(_ isFollowing: Bool) -> ProfileSocialSummary {
        guard amFollowing != isFollowing else { return self }
        return ProfileSocialSummary(
            // Aggregate counts remain server-owned because an idempotent
            // upsert may either insert a row or confirm one already exists.
            followerCount: followerCount,
            followingCount: followingCount,
            amFollowing: isFollowing,
            followsMe: followsMe,
            isMutualFollow: isFollowing && followsMe
        )
    }
}

enum ProfileFollowListMode {
    case followers
    case following
}

struct ProfileFollowListEntry: Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let avatarURL: String?
    let subtitle: String?
    let isNew: Bool
}

enum ProfileFollowFreshness {
    static let tolerance: TimeInterval = 0.5

    static func isNew(followedAt: Date?, seenAt: Date?) -> Bool {
        guard let followedAt else { return false }
        guard let seenAt else { return true }
        return followedAt.timeIntervalSince(seenAt) > tolerance
    }
}

@MainActor
final class ProfileSocialService: ObservableObject {
    typealias SummaryLoader = (UUID) async throws -> ProfileSocialSummary
    typealias LatestFollowerLoader = (UUID) async throws -> Date?

    static let shared = ProfileSocialService()

    @Published private(set) var summaries: [UUID: ProfileSocialSummary] = [:]
    @Published private(set) var hasUnreadFollowers = false
    @Published private(set) var accountGeneration: UInt64 = 0
    @Published private(set) var isAccountTransitionInProgress = false

    private let supabase = SupabaseManager.shared
    private let defaults: UserDefaults
    private let seenPrefix = "profile.followers.seen_at."
    private let injectedSummaryLoader: SummaryLoader?
    private let injectedLatestFollowerLoader: LatestFollowerLoader?
    private var stateOwnerID: UUID?
    private var unreadRefreshTask: Task<Void, Never>?
    private var unreadRefreshID: UUID?

    private init() {
        defaults = .standard
        injectedSummaryLoader = nil
        injectedLatestFollowerLoader = nil
    }

    init(
        summaryLoader: @escaping SummaryLoader,
        latestFollowerLoader: @escaping LatestFollowerLoader = { _ in nil },
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        injectedSummaryLoader = summaryLoader
        injectedLatestFollowerLoader = latestFollowerLoader
    }

    var isAccountScopeReady: Bool {
        !isAccountTransitionInProgress && stateOwnerID != nil
    }

    func beginAccountTransition() {
        isAccountTransitionInProgress = true
        resetAccountScopedState(ownerID: nil)
    }

    func activateAccount(_ userID: UUID?) {
        let mustReset = isAccountTransitionInProgress || stateOwnerID != userID
        isAccountTransitionInProgress = false
        guard mustReset else { return }
        resetAccountScopedState(ownerID: userID)
    }

    private func resetAccountScopedState(ownerID: UUID?) {
        unreadRefreshTask?.cancel()
        unreadRefreshTask = nil
        unreadRefreshID = nil
        accountGeneration &+= 1
        stateOwnerID = ownerID
        summaries = [:]
        hasUnreadFollowers = false
    }

    func isCurrentAccountRequest(generation: UInt64) -> Bool {
        !isAccountTransitionInProgress
            && stateOwnerID != nil
            && accountGeneration == generation
    }

    private func requestGeneration() -> UInt64? {
        guard isAccountScopeReady else { return nil }
        return accountGeneration
    }

    func summary(for userId: UUID?) -> ProfileSocialSummary {
        guard let userId else { return .empty }
        return summaries[userId] ?? .empty
    }

    func hasSummary(for userId: UUID) -> Bool {
        summaries[userId] != nil
    }

    @discardableResult
    func loadSummary(userId: UUID, forceRefresh: Bool = false) async -> ProfileSocialSummary {
        if !forceRefresh, let cached = summaries[userId] {
            return cached
        }
        guard let requestGeneration = requestGeneration() else { return .empty }

        do {
            let summary = try await fetchSummary(userId: userId)
            guard isCurrentAccountRequest(generation: requestGeneration) else {
                return .empty
            }
            summaries[userId] = summary
            return summary
        } catch {
            guard isCurrentAccountRequest(generation: requestGeneration) else {
                return .empty
            }
            // A transient request failure must not become a permanent cached
            // "not following" result for the remainder of the account session.
            return summaries[userId] ?? .empty
        }
    }

    func follow(targetUserId: UUID) async throws {
        let currentUserId = try await AuthService.shared.requireAuthUserId()
        guard currentUserId != targetUserId else { return }

        try await supabase
            .database("user_follows")
            .upsert(
                [
                    "follower_id": currentUserId.uuidString,
                    "following_id": targetUserId.uuidString
                ],
                onConflict: "follower_id,following_id",
                ignoreDuplicates: true
            )
            .execute()

        applyCachedFollowChange(
            targetUserId: targetUserId,
            isFollowing: true
        )

        ProfileSocialEvents.followingDidChange(
            targetUserID: targetUserId,
            isFollowing: true
        )

        await refreshSummariesAfterFollowChange(
            currentUserId: currentUserId,
            targetUserId: targetUserId
        )
    }

    func unfollow(targetUserId: UUID) async throws {
        let currentUserId = try await AuthService.shared.requireAuthUserId()
        guard currentUserId != targetUserId else { return }

        try await supabase
            .database("user_follows")
            .delete()
            .eq("follower_id", value: currentUserId.uuidString)
            .eq("following_id", value: targetUserId.uuidString)
            .execute()

        applyCachedFollowChange(
            targetUserId: targetUserId,
            isFollowing: false
        )

        ProfileSocialEvents.followingDidChange(
            targetUserID: targetUserId,
            isFollowing: false
        )

        await refreshSummariesAfterFollowChange(
            currentUserId: currentUserId,
            targetUserId: targetUserId
        )
    }

    func removeFollower(followerUserId: UUID) async throws {
        let currentUserId = try await AuthService.shared.requireAuthUserId()
        guard currentUserId != followerUserId else { return }

        let _: Bool = try await supabase.client.rpc(
            "remove_my_follower",
            params: RemoveFollowerParams(followerID: followerUserId)
        ).execute().value

        await refreshSummariesAfterFollowChange(
            currentUserId: currentUserId,
            targetUserId: followerUserId
        )
        await refreshUnreadStatus()
    }

    func loadFollowList(
        userId: UUID,
        mode: ProfileFollowListMode
    ) async throws -> (entries: [ProfileFollowListEntry], newFollowerCount: Int) {
        guard let requestGeneration = requestGeneration() else {
            throw CancellationError()
        }
        let sourceRows = try await fetchFollowRows(userId: userId, mode: mode)
        guard isCurrentAccountRequest(generation: requestGeneration) else {
            throw CancellationError()
        }
        let ordered = orderedFollowIds(from: sourceRows, mode: mode)
        let isViewingOwnFollowers = mode == .followers
            && AuthService.shared.currentUser?.id == userId

        guard !ordered.ids.isEmpty else {
            if isViewingOwnFollowers {
                markFollowersRead(userId: userId, latestFollowedAt: nil)
            }
            return ([], 0)
        }

        let profiles = try await ProfileService.fetchProfiles(userIds: ordered.ids)
        guard isCurrentAccountRequest(generation: requestGeneration) else {
            throw CancellationError()
        }
        let followerSeenAt = mode == .followers ? seenDate(for: userId) : nil
        let builtEntries = ordered.ids.compactMap { id -> ProfileFollowListEntry? in
            guard let profile = profiles[id] else { return nil }
            let followedAt = mode == .followers ? ordered.followedAt[id] : nil
            return ProfileFollowListEntry(
                id: id,
                displayName: displayName(for: profile),
                avatarURL: profile.avatarUrl,
                subtitle: profile.school,
                isNew: mode == .followers
                    && ProfileFollowFreshness.isNew(
                        followedAt: followedAt,
                        seenAt: followerSeenAt
                    )
            )
        }

        guard mode == .followers else {
            return (builtEntries, 0)
        }

        let newEntries = builtEntries.filter(\.isNew)
        let entries = newEntries + builtEntries.filter { !$0.isNew }
        if isViewingOwnFollowers {
            markFollowersRead(
                userId: userId,
                latestFollowedAt: sourceRows.compactMap(\.createdAt).max()
            )
        }
        return (entries, newEntries.count)
    }

    func refreshUnreadStatus() async {
        guard let userId = stateOwnerID,
              let requestGeneration = requestGeneration()
        else {
            hasUnreadFollowers = false
            return
        }

        if let unreadRefreshTask {
            await unreadRefreshTask.value
            return
        }

        let refreshID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performUnreadStatusRefresh(
                userId: userId,
                generation: requestGeneration
            )
        }
        unreadRefreshID = refreshID
        unreadRefreshTask = task
        await task.value

        if unreadRefreshID == refreshID {
            unreadRefreshTask = nil
            unreadRefreshID = nil
        }
    }

    private func performUnreadStatusRefresh(
        userId: UUID,
        generation requestGeneration: UInt64
    ) async {

        do {
            let latestFollowedAt = try await fetchLatestFollowerDate(userId: userId)
            guard isCurrentAccountRequest(generation: requestGeneration) else { return }
            hasUnreadFollowers = ProfileFollowFreshness.isNew(
                followedAt: latestFollowedAt,
                seenAt: seenDate(for: userId)
            )
        } catch {
            guard isCurrentAccountRequest(generation: requestGeneration) else { return }
            hasUnreadFollowers = false
        }
    }

    private func fetchSummary(userId: UUID) async throws -> ProfileSocialSummary {
        if let injectedSummaryLoader {
            return try await injectedSummaryLoader(userId)
        }
        let rows: [ProfileSocialSummary] = try await supabase.client
            .rpc(
                "get_profile_social_summary",
                params: ProfileSocialSummaryParams(pTargetUserId: userId)
            )
            .execute()
            .value
        return rows.first ?? .empty
    }

    private func fetchLatestFollowerDate(userId: UUID) async throws -> Date? {
        if let injectedLatestFollowerLoader {
            return try await injectedLatestFollowerLoader(userId)
        }
        let rows: [ProfileFollowRow] = try await supabase
            .database("user_follows")
            .select("created_at")
            .eq("following_id", value: userId.uuidString)
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first?.createdAt
    }

    private func refreshSummariesAfterFollowChange(
        currentUserId: UUID,
        targetUserId: UUID
    ) async {
        async let currentSummary = loadSummary(userId: currentUserId, forceRefresh: true)
        async let targetSummary = loadSummary(userId: targetUserId, forceRefresh: true)
        _ = await (currentSummary, targetSummary)
    }

    private func applyCachedFollowChange(
        targetUserId: UUID,
        isFollowing: Bool
    ) {
        if let targetSummary = summaries[targetUserId] {
            summaries[targetUserId] = targetSummary
                .applyingViewerFollowState(isFollowing)
        }
    }

    private func fetchFollowRows(
        userId: UUID,
        mode: ProfileFollowListMode
    ) async throws -> [ProfileFollowRow] {
        switch mode {
        case .followers:
            return try await supabase
                .database("user_follows")
                .select("follower_id,created_at")
                .eq("following_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
        case .following:
            return try await supabase
                .database("user_follows")
                .select("following_id,created_at")
                .eq("follower_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
        }
    }

    private func orderedFollowIds(
        from rows: [ProfileFollowRow],
        mode: ProfileFollowListMode
    ) -> (ids: [UUID], followedAt: [UUID: Date]) {
        var seen: Set<UUID> = []
        var ids: [UUID] = []
        var followedAt: [UUID: Date] = [:]

        for row in rows {
            let id = mode == .followers ? row.followerId : row.followingId
            guard let id, seen.insert(id).inserted else { continue }
            ids.append(id)
            if mode == .followers {
                followedAt[id] = row.createdAt
            }
        }

        return (ids, followedAt)
    }

    private func displayName(for profile: Profile) -> String {
        if let fullName = profile.fullName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fullName.isEmpty {
            return fullName
        }
        if let email = profile.email,
           let localPart = email.split(separator: "@").first,
           !localPart.isEmpty {
            return String(localPart)
        }
        return "用户"
    }

    private func seenDate(for userId: UUID) -> Date? {
        guard let raw = defaults.object(forKey: seenKey(for: userId)) as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: raw)
    }

    private func markFollowersRead(userId: UUID, latestFollowedAt: Date?) {
        let safeSeenAt = (latestFollowedAt ?? Date()).addingTimeInterval(1)
        defaults.set(safeSeenAt.timeIntervalSince1970, forKey: seenKey(for: userId))
        hasUnreadFollowers = false
    }

    private func seenKey(for userId: UUID) -> String {
        seenPrefix + userId.uuidString
    }
}

private struct RemoveFollowerParams: Encodable {
    let followerID: UUID

    enum CodingKeys: String, CodingKey {
        case followerID = "p_follower_id"
    }
}

private struct ProfileSocialSummaryParams: Encodable {
    let pTargetUserId: UUID

    enum CodingKeys: String, CodingKey {
        case pTargetUserId = "p_target_user_id"
    }
}

private struct ProfileFollowRow: Decodable {
    let followerId: UUID?
    let followingId: UUID?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case followerId = "follower_id"
        case followingId = "following_id"
        case createdAt = "created_at"
    }
}
