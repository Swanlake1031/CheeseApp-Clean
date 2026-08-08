import XCTest
@testable import CheeseApp

@MainActor
final class ProfileSocialServiceTests: XCTestCase {
    func testProfileSurfaceCacheKeyIncludesViewerIdentity() {
        let accountA = UUID(uuidString: "a5100000-0000-4000-8000-000000000001")!
        let accountB = UUID(uuidString: "b5100000-0000-4000-8000-000000000001")!
        let target = UUID(uuidString: "c5100000-0000-4000-8000-000000000001")!

        XCTAssertNotEqual(
            ProfileViewerTargetCacheKey(
                viewerID: accountA,
                targetUserID: target
            ),
            ProfileViewerTargetCacheKey(
                viewerID: accountB,
                targetUserID: target
            )
        )
    }

    func testBlockRelationCacheDoesNotCrossAccounts() {
        UserPostsViewMemoryCache.removeAll()
        defer { UserPostsViewMemoryCache.removeAll() }

        let accountA = UUID(uuidString: "a5200000-0000-4000-8000-000000000001")!
        let accountB = UUID(uuidString: "b5200000-0000-4000-8000-000000000001")!
        let target = UUID(uuidString: "c5200000-0000-4000-8000-000000000001")!
        let accountARelation = UserBlockRelation(
            isBlockedByMe: false,
            isBlockedByOther: true
        )

        UserPostsViewMemoryCache.storeBlockRelation(
            accountARelation,
            viewerID: accountA,
            targetUserID: target
        )

        XCTAssertEqual(
            UserPostsViewMemoryCache.blockRelation(
                viewerID: accountA,
                targetUserID: target
            ),
            accountARelation
        )
        XCTAssertNil(
            UserPostsViewMemoryCache.blockRelation(
                viewerID: accountB,
                targetUserID: target
            )
        )
    }

    func testFollowerWithoutSeenDateIsNew() {
        let followedAt = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(
            ProfileFollowFreshness.isNew(followedAt: followedAt, seenAt: nil)
        )
    }

    func testFollowerAtToleranceBoundaryIsNotNew() {
        let seenAt = Date(timeIntervalSince1970: 1_800_000_000)
        let followedAt = seenAt.addingTimeInterval(ProfileFollowFreshness.tolerance)

        XCTAssertFalse(
            ProfileFollowFreshness.isNew(followedAt: followedAt, seenAt: seenAt)
        )
    }

    func testFollowerAfterToleranceIsNew() {
        let seenAt = Date(timeIntervalSince1970: 1_800_000_000)
        let followedAt = seenAt.addingTimeInterval(ProfileFollowFreshness.tolerance + 0.01)

        XCTAssertTrue(
            ProfileFollowFreshness.isNew(followedAt: followedAt, seenAt: seenAt)
        )
    }

    func testLateSummaryFromPreviousAccountIsDiscarded() async {
        let accountA = UUID(uuidString: "a5300000-0000-4000-8000-000000000001")!
        let accountB = UUID(uuidString: "b5300000-0000-4000-8000-000000000001")!
        let target = UUID(uuidString: "c5300000-0000-4000-8000-000000000001")!
        let loader = ControlledProfileSummaryLoader()
        let service = ProfileSocialService(
            summaryLoader: { userID in
                try await loader.load(userID: userID)
            }
        )

        service.activateAccount(accountA)
        let accountATask = Task { @MainActor in
            await service.loadSummary(userId: target, forceRefresh: true)
        }
        await waitUntil { loader.hasRequest(for: target) }

        service.beginAccountTransition()
        service.activateAccount(accountB)
        loader.succeed(
            userID: target,
            summary: ProfileSocialSummary(
                followerCount: 99,
                followingCount: 42,
                amFollowing: true,
                followsMe: true,
                isMutualFollow: true
            )
        )
        _ = await accountATask.value

        XCTAssertTrue(service.summaries.isEmpty)
        XCTAssertFalse(service.hasUnreadFollowers)
        XCTAssertTrue(service.isAccountScopeReady)
    }

}

@MainActor
private final class ControlledProfileSummaryLoader {
    private var continuations: [
        UUID: CheckedContinuation<ProfileSocialSummary, Error>
    ] = [:]

    func load(userID: UUID) async throws -> ProfileSocialSummary {
        try await withCheckedThrowingContinuation { continuation in
            continuations[userID] = continuation
        }
    }

    func hasRequest(for userID: UUID) -> Bool {
        continuations[userID] != nil
    }

    func succeed(userID: UUID, summary: ProfileSocialSummary) {
        continuations.removeValue(forKey: userID)?.resume(returning: summary)
    }
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 2,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        await Task.yield()
    }
}
