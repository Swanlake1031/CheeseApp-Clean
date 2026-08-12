import XCTest
import SwiftUI
@testable import CheeseApp

final class HomeFeedServiceTests: XCTestCase {
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

    func testHomeFeedTabsUseRequestedOrder() {
        XCTAssertEqual(
            HomeFeedTab.allCases,
            [.recommended, .following, .forum, .secondhand]
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
        let course = makeCard(title: "Course", category: .course, views: 45)

        let ranked = HomeViewRanker.rankedByViews(
            [forum, secondhand, course]
        )

        XCTAssertEqual(
            ranked.map(\.title),
            ["Secondhand", "Course", "Forum"]
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
        let course = makeCard(title: "Course", category: .course, views: 50)
        let forum = makeCard(title: "Forum", category: .forum, views: 20)

        let ranked = HomeViewRanker.featuredFirst(
            [official],
            rankedCards: [forum, duplicate, course],
            limit: 3
        )

        XCTAssertEqual(ranked.map(\.title), ["MSAF", "Course", "Forum"])
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
