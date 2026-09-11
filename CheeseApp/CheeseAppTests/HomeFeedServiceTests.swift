import XCTest
import SwiftUI
import Supabase
@testable import CheeseApp

final class HomeFeedServiceTests: XCTestCase {
    func testFailedRefreshOrPaginationStopsAutomaticFooterRetries() {
        XCTAssertTrue(HomeForumContinuationPosition.allowsAutomaticLoad(refreshError: nil, paginationError: nil))
        XCTAssertFalse(HomeForumContinuationPosition.allowsAutomaticLoad(refreshError: "expired session refresh failed", paginationError: nil))
        XCTAssertFalse(HomeForumContinuationPosition.allowsAutomaticLoad(refreshError: nil, paginationError: "page failed"))
        XCTAssertFalse(HomeForumContinuationPosition.allowsAutomaticLoad(refreshError: "refresh failed", paginationError: "page failed"))
        let ids = (0..<4).map { _ in UUID() }
        XCTAssertEqual(HomeForumContinuationPosition.unseen([], after: ids), [])
        XCTAssertEqual(HomeForumContinuationPosition.unseen(ids + ids, after: ids), [])
        XCTAssertEqual(HomeForumContinuationPosition.unseen([ids[3], ids[2], ids[3], ids[0]], after: [ids[0], ids[1]]), [ids[3], ids[2]])
    }

    @MainActor
    func testFailedRefreshCanRetryWithoutLeakingPullIntent() async {
        let coordinator = HomeRefreshCoordinator()
        let failed = await coordinator.run(intent: .explicitPull) { false }
        XCTAssertFalse(failed)
        XCTAssertFalse(coordinator.explicitPullRequested)
        let retried = await coordinator.run(intent: .normal) {
            XCTAssertFalse(coordinator.explicitPullRequested)
            return true
        }
        XCTAssertTrue(retried)
    }

    func testSameSessionRotationPreservesContinuationCursorAndNewSessionResetsIt() {
        let session = UUID(), ids = (0..<5).map { _ in UUID() }
        let cursor = ForumContinuationReference(post_id: UUID(), created_at: "2026-09-10T00:00:00.123456Z")
        var position = HomeForumContinuationPosition()
        XCTAssertTrue(position.resolve(session: session))
        position.cursor = cursor
        position.exclusions = ids
        for _ in 0..<3 {
            XCTAssertFalse(position.resolve(session: session))
            XCTAssertEqual(position.cursor, cursor)
            XCTAssertEqual(position.exclusions, ids)
        }
        XCTAssertTrue(position.resolve(session: UUID()))
        XCTAssertNil(position.cursor)
        XCTAssertNil(position.exclusions)
        XCTAssertEqual(HomeForumContinuationPosition.unseen([ids[0],ids[2],ids[2],ids[3]], after: [ids[0],ids[1]]), [ids[2],ids[3]])
    }

    func testRefreshThreeStableTiers() {
        let ids = (0..<6).map { _ in UUID() }
        XCTAssertEqual(HomeForumPresentation.tiers(ids, previous: Array(ids[0..<2]), older: Array(ids[2..<4])),
                       [Array(ids[4..<6]), Array(ids[2..<4]), Array(ids[0..<2])])
    }

    func testExplicitPullRotatesWithinSameSessionAndBoundsHistory() {
        let account = UUID(), session = UUID(), ids = (0..<60).map { _ in UUID() }
        var state = HomeForumPresentation()
        state.resolve(account: account, session: session, candidates: ids, featured: [], intent: .normal)
        XCTAssertEqual(state.orderedIDs, ids)
        XCTAssertEqual(state.generation, 0)
        state.resolve(account: account, session: session, candidates: ids, featured: [], intent: .explicitPull)
        XCTAssertEqual(Array(state.orderedIDs.prefix(20)), Array(ids[20..<40]))
        state.resolve(account: account, session: session, candidates: ids, featured: [], intent: .explicitPull)
        XCTAssertEqual(Array(state.orderedIDs.prefix(20)), Array(ids[40..<60]))
        XCTAssertEqual(state.sessionID, session)
        XCTAssertEqual(state.generation, 2)
        for _ in 0..<10 { state.resolve(account: account, session: session, candidates: ids, featured: [], intent: .explicitPull) }
        XCTAssertEqual(state.recentTops.count, 2)
        XCTAssertTrue(state.recentTops.allSatisfy { $0.count == 20 })
        XCTAssertEqual(Set(state.orderedIDs), Set(ids))
    }

    func testNormalLifecycleRequestsDoNotRotate() {
        let account = UUID(), session = UUID(), ids = (0..<45).map { _ in UUID() }
        var state = HomeForumPresentation()
        state.resolve(account: account, session: session, candidates: ids, featured: [], intent: .normal)
        state.resolve(account: account, session: session, candidates: ids, featured: [], intent: .explicitPull)
        let order = state.orderedIDs, history = state.recentTops
        for event in ["view appearance", "foreground", "tab switch", "home reselect"] {
            state.resolve(account: account, session: session, candidates: ids, featured: [], intent: .normal)
            XCTAssertEqual(state.orderedIDs, order, event)
            XCTAssertEqual(state.recentTops, history, event)
            XCTAssertEqual(state.generation, 1, event)
        }
    }

    func testNewSessionAndAccountResetRotationIncludingExpiredPull() {
        let a = UUID(), b = UUID(), s1 = UUID(), s2 = UUID(), ids = (0..<45).map { _ in UUID() }
        var state = HomeForumPresentation()
        state.resolve(account: a, session: s1, candidates: ids, featured: [], intent: .normal)
        state.resolve(account: a, session: s1, candidates: ids, featured: [], intent: .explicitPull)
        state.resolve(account: a, session: s2, candidates: ids, featured: [], intent: .explicitPull)
        XCTAssertEqual(state.orderedIDs, ids)
        XCTAssertEqual(state.generation, 0)
        XCTAssertEqual(state.recentTops.count, 1)
        state.resolve(account: b, session: s2, candidates: Array(ids.reversed()), featured: [], intent: .normal)
        XCTAssertEqual(state.accountID, b)
        XCTAssertEqual(state.orderedIDs, Array(ids.reversed()))
        XCTAssertEqual(state.generation, 0)
    }

    func testProcessRestartForgetsOnlyPresentationNotServerSessionIdentity() {
        let account = UUID(), session = UUID(), ids = (0..<25).map { _ in UUID() }
        var restarted = HomeForumPresentation()
        restarted.resolve(account: account, session: session, candidates: ids, featured: [], intent: .normal)
        XCTAssertEqual(restarted.sessionID, session)
        XCTAssertEqual(restarted.orderedIDs, ids)
        XCTAssertEqual(restarted.generation, 0)
    }

    func testSmallInventoryDefersRatherThanDeletesAndFeaturedNeverUsesHistorySlots() {
        let account = UUID(), session = UUID(), ids = (0..<26).map { _ in UUID() }, featured = UUID()
        var state = HomeForumPresentation()
        state.resolve(account: account, session: session, candidates: [featured] + ids, featured: [featured], intent: .normal)
        state.resolve(account: account, session: session, candidates: [featured] + ids, featured: [featured], intent: .explicitPull)
        XCTAssertEqual(state.orderedIDs, Array(ids[20..<26]) + Array(ids[0..<20]))
        XCTAssertFalse(state.recentTops.flatMap { $0 }.contains(featured))
        XCTAssertEqual(state.tierCounts, [6, 0, 20])
        for count in [0, 1, 5, 20] {
            var small = HomeForumPresentation()
            let subset = Array(ids.prefix(count))
            small.resolve(account: account, session: session, candidates: subset, featured: [], intent: .normal)
            small.resolve(account: account, session: session, candidates: subset, featured: [], intent: .explicitPull)
            XCTAssertEqual(small.orderedIDs, subset)
        }
    }

    @MainActor
    func testOverlappingPullsCoalesceAndRotateOnce() async {
        let coordinator = HomeRefreshCoordinator()
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let first = Task { await coordinator.run(intent: .explicitPull) {
            calls += 1
            await withCheckedContinuation { release = $0 }
            XCTAssertTrue(coordinator.explicitPullRequested)
            return true
        } }
        while release == nil { await Task.yield() }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return await coordinator.run(intent: .explicitPull) { calls += 1; return true }
        }
        while !secondStarted { await Task.yield() }
        release?.resume()
        let a = await first.value, b = await second.value
        XCTAssertTrue(a && b)
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(coordinator.explicitPullRequested)
    }

    @MainActor
    func testPullDuringNormalRequestUpgradesIntentWithoutSecondRequest() async {
        let coordinator = HomeRefreshCoordinator()
        var release: CheckedContinuation<Void, Never>?
        let normal = Task { await coordinator.run(intent: .normal) {
            await withCheckedContinuation { release = $0 }
            return coordinator.explicitPullRequested
        } }
        while release == nil { await Task.yield() }
        let pull = Task { await coordinator.run(intent: .explicitPull) { XCTFail("duplicate request"); return false } }
        while !coordinator.explicitPullRequested { await Task.yield() }
        release?.resume()
        let a = await normal.value, b = await pull.value
        XCTAssertTrue(a && b)
    }

    @MainActor
    func testCancelledAccountOperationCannotClearNewRequestIntent() async {
        let coordinator = HomeRefreshCoordinator()
        var oldRelease: CheckedContinuation<Void, Never>?
        var newRelease: CheckedContinuation<Void, Never>?
        let old = Task { await coordinator.run(intent: .explicitPull) {
            await withCheckedContinuation { oldRelease = $0 }; return !Task.isCancelled
        } }
        while oldRelease == nil { await Task.yield() }
        coordinator.cancel()
        let new = Task { await coordinator.run(intent: .explicitPull) {
            await withCheckedContinuation { newRelease = $0 }; return !Task.isCancelled
        } }
        while newRelease == nil { await Task.yield() }
        oldRelease?.resume()
        let oldResult = await old.value
        XCTAssertFalse(oldResult)
        XCTAssertTrue(coordinator.explicitPullRequested)
        newRelease?.resume()
        let newResult = await new.value
        XCTAssertTrue(newResult)
    }

    @MainActor
    func testForumTabDoesNotTruncateAfterTwelveOrSixtyPosts() {
        let board = UUID()
        let cards = (0..<125).map {
            HomeCardItem(postId: UUID(), title: "Post \($0)", subtitle: "", boardID: board)
        }
        XCTAssertEqual(HomeViewModel.composeForumTabCards(
            featured: [], ranked: cards, selectedBoardID: board).map(\.id), cards.map(\.id))
    }

    func testForumContinuationPreservesMicrosecondCursor() throws {
        let id = UUID()
        let json = "{\"post_id\":\"\(id)\",\"created_at\":\"2026-09-01T00:00:00.123456+00:00\"}"
        let cursor = try JSONDecoder().decode(ForumContinuationReference.self, from: Data(json.utf8))
        XCTAssertEqual(cursor.post_id, id)
        XCTAssertEqual(cursor.created_at, "2026-09-01T00:00:00.123456+00:00")
    }

    @MainActor
    func testForumTabUsesServerOrderWithFeaturedDeduplication() {
        let board = UUID()
        let pinned = HomeCardItem(postId: UUID(), title: "Pinned", subtitle: "", boardID: board, isSystemPinned: true)
        let ranked = (0..<15).map { HomeCardItem(postId: UUID(), title: "Rank \($0)", subtitle: "", boardID: board) }
        let cards = HomeViewModel.composeForumTabCards(featured: [pinned], ranked: ranked + [pinned], selectedBoardID: nil)
        XCTAssertEqual(cards.map(\.id), ([pinned] + ranked).map(\.id))
    }

    @MainActor
    func testForumBoardFilterPreservesV2RelativeOrder() {
        let selected = UUID()
        let other = UUID()
        let cards = [selected, other, selected].map { HomeCardItem(postId: UUID(), title: "Post", subtitle: "", boardID: $0) }
        XCTAssertEqual(HomeViewModel.composeForumTabCards(featured: [], ranked: cards, selectedBoardID: selected).map(\.id),
                       [cards[0].id, cards[2].id])
    }

    @MainActor
    func testCachedForumSessionOrderDoesNotChangeWithRefreshSeed() {
        let cards = (0..<15).map { HomeCardItem(postId: UUID(), title: "Rank \($0)", subtitle: "") }
        let session = UUID()
        for seed in [UInt64(0), 1, 100, UInt64.max] {
            XCTAssertEqual(HomeViewModel.orderForumCards(cards, sessionID: session, seed: seed).map(\.id), cards.map(\.id))
        }
    }

    func testV2FeaturedEligibilityPreservesExistingOrderAndBadges() {
        let first = HomeFeaturedPost(postID: UUID(), badge: "First", displayOrder: 1)
        let excluded = HomeFeaturedPost(postID: UUID(), badge: nil, displayOrder: 2)
        let last = HomeFeaturedPost(postID: UUID(), badge: "Last", displayOrder: 3)
        XCTAssertEqual(HomeFeedService.eligibleFeaturedPosts(
            [first, excluded, last], allowedIDs: [last.postID, first.postID]), [first, last])
        XCTAssertTrue(HomeFeedService.eligibleFeaturedPosts([first], allowedIDs: []).isEmpty)
    }

    func testRecommendationVisibilityThresholdsIgnoreFastScrolling() {
        let fast = ForumRecommendationVisibilityPolicy.qualifies(
            visibleFraction: 0.8,
            dwellMilliseconds: 500
        )
        XCTAssertFalse(fast.qualifiedImpression)
        XCTAssertFalse(fast.meaningfulRead)

        let qualified = ForumRecommendationVisibilityPolicy.qualifies(
            visibleFraction: 0.5,
            dwellMilliseconds: 1_000
        )
        XCTAssertTrue(qualified.qualifiedImpression)
        XCTAssertFalse(qualified.meaningfulRead)

        let meaningful = ForumRecommendationVisibilityPolicy.qualifies(
            visibleFraction: 0.5,
            dwellMilliseconds: 3_000
        )
        XCTAssertTrue(meaningful.qualifiedImpression)
        XCTAssertTrue(meaningful.meaningfulRead)
    }

    @MainActor
    func testFreshResolvedHomeFeedDoesNotReload() {
        let loadedAt = Date(timeIntervalSince1970: 10_000)

        XCTAssertFalse(
            HomeViewModel.shouldReload(
                hasResolvedData: true,
                lastSuccessfulRefreshAt: loadedAt,
                now: loadedAt.addingTimeInterval(299),
                cacheLifetime: 300
            )
        )
    }

    @MainActor
    func testExpiredHomeFeedReloads() {
        let loadedAt = Date(timeIntervalSince1970: 10_000)

        XCTAssertTrue(
            HomeViewModel.shouldReload(
                hasResolvedData: true,
                lastSuccessfulRefreshAt: loadedAt,
                now: loadedAt.addingTimeInterval(300),
                cacheLifetime: 300
            )
        )
    }

    @MainActor
    func testUnresolvedHomeFeedAlwaysLoads() {
        XCTAssertTrue(
            HomeViewModel.shouldReload(
                hasResolvedData: false,
                lastSuccessfulRefreshAt: Date(),
                now: Date(),
                cacheLifetime: 300
            )
        )
    }

    @MainActor
    func testBackgroundHomeRefreshDoesNotRepublishInitialLoadingState() {
        XCTAssertTrue(
            HomeViewModel.shouldPublishInitialLoading(hasResolvedData: false)
        )
        XCTAssertFalse(
            HomeViewModel.shouldPublishInitialLoading(hasResolvedData: true)
        )
    }

    func testFreshLifecycleCacheSkipsForegroundRefresh() {
        let refreshedAt = Date(timeIntervalSince1970: 20_000)

        XCTAssertFalse(
            AppLifecycleRefreshPolicy.shouldRefresh(
                hasCachedData: true,
                lastSuccessfulRefreshAt: refreshedAt,
                now: refreshedAt.addingTimeInterval(299),
                cacheLifetime: 300
            )
        )
    }

    func testExpiredLifecycleCacheRefreshes() {
        let refreshedAt = Date(timeIntervalSince1970: 20_000)

        XCTAssertTrue(
            AppLifecycleRefreshPolicy.shouldRefresh(
                hasCachedData: true,
                lastSuccessfulRefreshAt: refreshedAt,
                now: refreshedAt.addingTimeInterval(300),
                cacheLifetime: 300
            )
        )
    }

    func testMissingLifecycleCacheRefreshesOnce() {
        XCTAssertTrue(
            AppLifecycleRefreshPolicy.shouldRefresh(
                hasCachedData: false,
                lastSuccessfulRefreshAt: nil
            )
        )
    }

    func testTransientSessionFailuresPreserveLocalAuth() {
        XCTAssertFalse(
            AuthSessionFailurePolicy.shouldResetAuth(
                for: URLError(.timedOut)
            )
        )
        XCTAssertFalse(
            AuthSessionFailurePolicy.shouldResetAuth(
                statusCode: 504,
                errorCode: .requestTimeout
            )
        )
    }

    func testDefinitiveSessionFailuresResetAuth() {
        XCTAssertTrue(
            AuthSessionFailurePolicy.shouldResetAuth(
                for: AuthError.sessionMissing
            )
        )
        XCTAssertTrue(
            AuthSessionFailurePolicy.shouldResetAuth(
                statusCode: 401,
                errorCode: .unknown
            )
        )
        XCTAssertTrue(
            AuthSessionFailurePolicy.shouldResetAuth(
                statusCode: 400,
                errorCode: .refreshTokenAlreadyUsed
            )
        )
    }

    func testHomeFeedRetriesTransientMissingSessionFailures() {
        XCTAssertTrue(
            HomeFeedAuthFailurePolicy.shouldRetry(
                NSError(
                    domain: "PostgREST",
                    code: 42_501,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "permission denied for view forum_posts_view"
                    ]
                )
            )
        )
        XCTAssertTrue(
            HomeFeedAuthFailurePolicy.shouldRetry(
                NSError(
                    domain: "HTTP",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "Unauthorized"]
                )
            )
        )
    }

    func testHomeFeedDoesNotRetryOrdinaryQueryFailures() {
        XCTAssertFalse(
            HomeFeedAuthFailurePolicy.shouldRetry(
                NSError(
                    domain: "PostgREST",
                    code: 42_703,
                    userInfo: [
                        NSLocalizedDescriptionKey: "column likes.id does not exist"
                    ]
                )
            )
        )
    }

    func testHomeFeedTabsUseRequestedOrder() {
        XCTAssertEqual(
            HomeFeedTab.allCases,
            [.following, .forum, .secondhand]
        )
    }

    @MainActor
    func testFollowChangeUpdatesHomeFeedMembershipImmediately() {
        let viewModel = HomeViewModel()
        let authorID = UUID()

        viewModel.applyFollowChange(targetUserID: authorID, isFollowing: true)
        XCTAssertTrue(viewModel.isFollowingAnyone)
        XCTAssertTrue(viewModel.followedAuthorIDs.contains(authorID))

        viewModel.applyFollowChange(targetUserID: authorID, isFollowing: false)
        XCTAssertFalse(viewModel.isFollowingAnyone)
        XCTAssertFalse(viewModel.followedAuthorIDs.contains(authorID))
    }

    func testCardsRankAcrossModulesByViewCount() {
        let forum = makeCard(title: "Forum", category: .forum, views: 21)
        let secondhand = makeCard(
            title: "Secondhand",
            category: .secondhand,
            views: 72
        )

        let ranked = HomeViewRanker.rankedByViews(
            [forum, secondhand]
        )

        XCTAssertEqual(
            ranked.map(\.title),
            ["Secondhand", "Forum"]
        )
    }

    func testOfficialForumCardAppearsOnceBeforeViewRankedPosts() {
        let postID = UUID()
        let official = makeCard(
            postID: postID,
            title: "MSAF",
            category: .forum,
            views: 1
        )
        let duplicate = makeCard(
            postID: postID,
            title: "Duplicate MSAF",
            category: .forum,
            views: 100
        )
        let secondhand = makeCard(title: "Secondhand", category: .secondhand, views: 50)
        let forum = makeCard(title: "Forum", category: .forum, views: 20)

        let ranked = HomeViewRanker.featuredFirst(
            [official],
            rankedCards: [forum, duplicate, secondhand],
            limit: 3
        )

        XCTAssertEqual(ranked.map(\.title), ["MSAF", "Secondhand", "Forum"])
        XCTAssertEqual(ranked.filter { $0.postId == postID }.count, 1)
    }

    func testCreatedPostIsInsertedAfterSystemPinnedPosts() {
        let pinned = makeCard(
            title: "System pinned",
            category: .forum,
            views: 0,
            isSystemPinned: true
        )
        let created = makeCard(
            title: "Just published",
            category: .secondhand,
            views: 0
        )
        let organic = makeCard(
            title: "Organic",
            category: .forum,
            views: 100
        )

        let result = HomeRecommendationRanker.insertingCreatedPost(
            created,
            into: [organic, pinned],
            limit: 3
        )

        XCTAssertEqual(
            result.map(\.title),
            ["System pinned", "Just published", "Organic"]
        )
    }

    func testCreatedPostRemainsVisibleWhenPinnedPostsFillNormalLimit() {
        let firstPinned = makeCard(
            title: "Pinned 1",
            category: .forum,
            views: 0,
            isSystemPinned: true
        )
        let secondPinned = makeCard(
            title: "Pinned 2",
            category: .forum,
            views: 0,
            isSystemPinned: true
        )
        let created = makeCard(
            title: "Just published",
            category: .forum,
            views: 0
        )

        let result = HomeRecommendationRanker.insertingCreatedPost(
            created,
            into: [firstPinned, secondPinned],
            limit: 2
        )

        XCTAssertEqual(
            result.map(\.title),
            ["Pinned 1", "Pinned 2", "Just published"]
        )
    }

    func testRecommendationOrderIsStableForSameRefreshSeed() {
        let cards = recommendationFixtures()

        let first = HomeRecommendationRanker.ranked(cards, seed: 42, limit: cards.count)
        let second = HomeRecommendationRanker.ranked(cards, seed: 42, limit: cards.count)

        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    func testRecommendationOrderChangesWithRefreshSeed() {
        let cards = recommendationFixtures()

        let first = HomeRecommendationRanker.ranked(cards, seed: 42, limit: cards.count)
        let refreshed = HomeRecommendationRanker.ranked(cards, seed: 9_999, limit: cards.count)

        XCTAssertNotEqual(first.map(\.id), refreshed.map(\.id))
    }

    func testHomeFeaturedConfigurationDecodesOnlyForumReferenceAndPresentation() throws {
        let postID = UUID(uuidString: "93000000-0000-0000-0000-000000000001")!
        let data = Data(
            """
            {"post_id":"\(postID.uuidString)","badge":"奶酪官方","display_order":0}
            """.utf8
        )

        let configuration = try JSONDecoder().decode(HomeFeaturedPost.self, from: data)

        XCTAssertEqual(configuration.postID, postID)
        XCTAssertEqual(configuration.badge, "奶酪官方")
        XCTAssertEqual(configuration.displayOrder, 0)
    }

    func testHomeFeaturedCardTitleComesFromResolvedForumPost() {
        let post = makeForumPost(title: "生病、不想做作業？你可能可以使用 MSAF")
        let item = HomeFeaturedForumItem(
            configuration: HomeFeaturedPost(postID: post.id, badge: "奶酪官方", displayOrder: 0),
            post: post
        )

        XCTAssertEqual(item.post.title, post.title)
        XCTAssertEqual(item.cardAccessibilityLabel, "奶酪官方，\(post.title)")
        XCTAssertFalse(item.cardAccessibilityLabel.contains(post.content))
    }

    func testHomeFeaturedResolutionSupportsMultipleOrderedPostsAndSkipsMissingPost() {
        let first = makeForumPost(title: "First")
        let third = makeForumPost(title: "Third")
        let missingID = UUID()
        let configurations = [
            HomeFeaturedPost(postID: third.id, badge: nil, displayOrder: 2),
            HomeFeaturedPost(postID: missingID, badge: nil, displayOrder: 1),
            HomeFeaturedPost(postID: first.id, badge: nil, displayOrder: 0)
        ]

        let resolved = HomeFeaturedForumItem.resolve(
            configurations: configurations,
            postsByID: [first.id: first, third.id: third]
        )

        XCTAssertEqual(resolved.map(\.post.id), [first.id, third.id])
        XCTAssertFalse(resolved.contains { $0.post.id == missingID })
    }

    func testProfileOfficialIdentityDecodesFromTrustedField() throws {
        let id = UUID()
        let officialData = Data(
            """
            {"id":"\(id.uuidString)","email":"cheese_official@cheeseapp.org","is_official":true}
            """.utf8
        )
        let ordinaryData = Data(
            """
            {"id":"\(id.uuidString)","email":"student@mcmaster.ca","is_official":false}
            """.utf8
        )

        XCTAssertTrue(try JSONDecoder().decode(Profile.self, from: officialData).isOfficialAccount)
        XCTAssertFalse(try JSONDecoder().decode(Profile.self, from: ordinaryData).isOfficialAccount)
    }

    private func makeCard(
        postID: UUID = UUID(),
        title: String,
        category: HomeCardCategory,
        views: Int,
        likes: Int = 0,
        comments: Int = 0,
        saves: Int = 0,
        isSystemPinned: Bool = false
    ) -> HomeCardItem {
        HomeCardItem(
            postId: postID,
            title: title,
            subtitle: "",
            category: category,
            viewCount: views,
            likeCount: likes,
            commentCount: comments,
            saveCount: saves,
            isSystemPinned: isSystemPinned
        )
    }

    private func recommendationFixtures() -> [HomeCardItem] {
        (1...10).map { index in
            makeCard(
                postID: UUID(
                    uuidString: String(
                        format: "00000000-0000-0000-0000-%012d",
                        index
                    )
                )!,
                title: "Post \(index)",
                category: index.isMultiple(of: 2) ? .forum : .secondhand,
                views: 10,
                likes: 2,
                comments: 3,
                saves: 4
            )
        }
    }

    private func makeForumPost(title: String) -> ForumPostItem {
        ForumPostItem(
            id: UUID(),
            authorId: UUID(),
            authorAvatar: nil,
            title: title,
            content: "This body belongs only to the Forum post.",
            boardID: UUID(),
            boardName: "学术",
            boardIcon: "graduationcap.fill",
            boardAllowsAnonymous: false,
            authorName: "奶酪官方",
            isAnonymous: false,
            isAuthorOfficial: true,
            timeAgo: "now",
            createdAt: Date(),
            likes: 0,
            comments: 0,
            views: 0,
            isLiked: false,
            isPinned: false,
            imageUrls: [],
            hasImage: false
        )
    }

}
