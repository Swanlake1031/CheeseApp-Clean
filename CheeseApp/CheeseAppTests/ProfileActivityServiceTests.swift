import XCTest
@testable import CheeseApp

@MainActor
final class ProfileActivityServiceTests: XCTestCase {
    func testCompletedSecondhandTransactionDecodesRelistState() throws {
        let transactionID = UUID()
        let listingID = UUID()
        let counterpartyID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "transaction_id": transactionID.uuidString,
            "listing_id": listingID.uuidString,
            "role": "seller",
            "listing_title": "Desk lamp",
            "price": 18.5,
            "counterparty_id": counterpartyID.uuidString,
            "counterparty_name": "Buyer",
            "completed_at": "2026-08-12T03:00:00Z",
            "listing_status": "completed",
            "can_relist": true
        ])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(CompletedSecondhandTransaction.self, from: data)

        XCTAssertEqual(item.transactionID, transactionID)
        XCTAssertEqual(item.listingID, listingID)
        XCTAssertEqual(item.role, .seller)
        XCTAssertEqual(item.listingStatus, "completed")
        XCTAssertTrue(item.canRelist)
    }

    func testProfileTabsPlacePrivateContentAfterPublished() {
        XCTAssertEqual(
            ProfileActivityKind.allCases,
            [.published, .privateContent, .liked, .favorited]
        )
    }

    func testSelectingTabLoadsOnlySelectedActivityKind() async {
        let account = UUID(uuidString: "a9400000-0000-4000-8000-000000000001")!
        var requestedKinds: [ProfileActivityKind] = []
        let service = ProfileActivityService(
            loadPage: { kind, _, _, _, _ in
                requestedKinds.append(kind)
                return ProfileActivityPage(
                    items: [.fixture(index: 1, kind: kind)],
                    nextCursor: nil
                )
            }
        )

        service.activateAccount(account)
        await service.select(.liked)

        XCTAssertEqual(requestedKinds, [.liked])
        XCTAssertEqual(service.selectedKind, .liked)
        XCTAssertEqual(service.items.count, 1)
    }

    func testAccountSwitchDiscardsLateActivityPage() async {
        let accountA = UUID(uuidString: "a9500000-0000-4000-8000-000000000001")!
        let accountB = UUID(uuidString: "b9500000-0000-4000-8000-000000000001")!
        let loader = ControlledProfileActivityLoader()
        let service = ProfileActivityService(
            loadPage: { kind, _, _, cursor, limit in
                try await loader.load(
                    kind: kind,
                    cursor: cursor,
                    limit: limit
                )
            }
        )

        service.activateAccount(accountA)
        let task = Task { @MainActor in
            await service.loadInitial()
        }
        await waitForProfileActivityCondition { loader.hasRequest }

        service.activateAccount(accountB)
        loader.succeed(
            page: ProfileActivityPage(
                items: [.fixture(index: 1, kind: .published)],
                nextCursor: nil
            )
        )
        await task.value

        XCTAssertTrue(service.items.isEmpty)
        XCTAssertFalse(service.hasResolvedInitialLoad)
        XCTAssertFalse(service.isLoading)
    }

    func testReloadWaitsForCancelledInitialLoadInsteadOfGettingDropped() async {
        let account = UUID(uuidString: "a9550000-0000-4000-8000-000000000001")!
        let loader = CancellableProfileActivityLoader()
        let service = ProfileActivityService(
            loadPage: { kind, _, _, cursor, limit in
                try await loader.load(
                    kind: kind,
                    cursor: cursor,
                    limit: limit
                )
            }
        )

        service.activateAccount(account)
        let initialTask = Task { @MainActor in
            await service.loadInitial()
        }
        await waitForProfileActivityCondition {
            loader.requestCount == 1
        }

        let replacementTask = Task { @MainActor in
            await service.loadInitial(force: true)
        }
        await Task.yield()
        initialTask.cancel()
        await initialTask.value
        await replacementTask.value

        XCTAssertEqual(loader.requestCount, 2)
        XCTAssertTrue(service.hasResolvedInitialLoad)
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.items.count, 1)
    }

    func testPaginationDeduplicatesBoundaryActivity() async {
        let account = UUID(uuidString: "a9600000-0000-4000-8000-000000000001")!
        let first = ProfileActivityItem.fixture(index: 1, kind: .liked)
        let second = ProfileActivityItem.fixture(index: 2, kind: .liked)
        let cursor = ProfileActivityCursor(
            createdAt: first.activityCreatedAt,
            id: first.activityID
        )
        var pages = [
            ProfileActivityPage(items: [first], nextCursor: cursor),
            ProfileActivityPage(items: [first, second], nextCursor: nil)
        ]
        let service = ProfileActivityService(
            initialKind: .liked,
            pageSize: 2,
            loadPage: { _, _, _, _, _ in pages.removeFirst() }
        )

        service.activateAccount(account)
        await service.loadInitial()
        await service.loadNextPageIfNeeded(currentItem: first)

        XCTAssertEqual(service.items.map(\.id), [first.id, second.id])
        XCTAssertFalse(service.hasMore)
    }

    func testReturningToLoadedTabUsesItsCachedPage() async {
        let account = UUID(uuidString: "a9700000-0000-4000-8000-000000000001")!
        var requestedKinds: [ProfileActivityKind] = []
        let service = ProfileActivityService(
            loadPage: { kind, _, _, _, _ in
                requestedKinds.append(kind)
                return ProfileActivityPage(
                    items: [.fixture(index: requestedKinds.count, kind: kind)],
                    nextCursor: nil
                )
            }
        )

        service.activateAccount(account)
        await service.select(.published)
        let publishedItemIDs = service.items.map(\.id)
        await service.select(.liked)
        await service.select(.published)

        XCTAssertEqual(
            requestedKinds,
            [.published, .liked]
        )
        XCTAssertEqual(service.items.map(\.id), publishedItemIDs)
        XCTAssertEqual(service.selectedKind, .published)
    }

    func testPublishedPageLoadsPrivatePostState() async {
        let account = UUID(uuidString: "a9800000-0000-4000-8000-000000000001")!
        let privateItem = ProfileActivityItem.fixture(index: 8, kind: .published)
        let publicItem = ProfileActivityItem.fixture(index: 9, kind: .published)
        let service = ProfileActivityService(
            loadPage: { _, _, _, _, _ in
                ProfileActivityPage(
                    items: [privateItem, publicItem],
                    nextCursor: nil
                )
            },
            privacyLoader: { kind, postIDs in
                XCTAssertEqual(kind, .published)
                XCTAssertEqual(
                    Set(postIDs),
                    Set([privateItem.postID, publicItem.postID])
                )
                return [privateItem.postID]
            }
        )

        service.activateAccount(account)
        await service.loadInitial()

        XCTAssertTrue(service.isPostPrivate(privateItem.postID))
        XCTAssertFalse(service.isPostPrivate(publicItem.postID))
    }

    func testPublishedPostTypeFiltersUseIndependentCachedPages() async {
        let account = UUID(uuidString: "a9900000-0000-4000-8000-000000000001")!
        var requests: [PostKind?] = []
        let service = ProfileActivityService(
            loadPage: { kind, postKind, _, _, _ in
                XCTAssertEqual(kind, .published)
                requests.append(postKind)
                return ProfileActivityPage(
                    items: [
                        .fixture(
                            index: requests.count,
                            kind: .published,
                            postKind: postKind ?? .forum
                        )
                    ],
                    nextCursor: nil
                )
            }
        )

        service.activateAccount(account)
        await service.select(.published, publishedPostKind: .forum)
        let forumIDs = service.items.map(\.id)
        await service.select(.published, publishedPostKind: .secondhand)
        await service.select(.published, publishedPostKind: .forum)

        XCTAssertEqual(requests, [.forum, .secondhand])
        XCTAssertEqual(service.items.map(\.id), forumIDs)
        XCTAssertEqual(service.selectedPublishedPostKind, .forum)
    }

    func testVisibleAndHiddenPublishedPagesUseIndependentCaches() async {
        let account = UUID(uuidString: "a9950000-0000-4000-8000-000000000001")!
        var requests: [PublishedPostVisibility] = []
        let service = ProfileActivityService(
            loadPage: { kind, _, visibility, _, _ in
                XCTAssertEqual(kind, .published)
                requests.append(visibility)
                return ProfileActivityPage(
                    items: [
                        .fixture(
                            index: visibility == .visible ? 31 : 32,
                            kind: .published
                        )
                    ],
                    nextCursor: nil
                )
            }
        )

        service.activateAccount(account)
        await service.select(
            .published,
            publishedVisibility: .visible
        )
        let visibleIDs = service.items.map(\.id)
        await service.select(
            .published,
            publishedVisibility: .hidden
        )
        let hiddenIDs = service.items.map(\.id)
        await service.select(
            .published,
            publishedVisibility: .visible
        )

        XCTAssertEqual(requests, [.visible, .hidden])
        XCTAssertNotEqual(visibleIDs, hiddenIDs)
        XCTAssertEqual(service.items.map(\.id), visibleIDs)
        XCTAssertEqual(service.selectedPublishedVisibility, .visible)
    }

    func testUnlikeKeepsCurrentLikedSnapshotUntilNextReload() async {
        let account = UUID(uuidString: "a9960000-0000-4000-8000-000000000001")!
        let likedItem = ProfileActivityItem.fixture(index: 41, kind: .liked)
        var toggleInputs: [(UUID, Bool)] = []
        let service = ProfileActivityService(
            initialKind: .liked,
            loadPage: { _, _, _, _, _ in
                ProfileActivityPage(items: [likedItem], nextCursor: nil)
            },
            likeToggler: { postID, currentlyLiked in
                toggleInputs.append((postID, currentlyLiked))
                return false
            }
        )

        service.activateAccount(account)
        await service.loadInitial()
        await service.toggleReaction(likedItem, currentlyActive: true)

        XCTAssertEqual(service.items, [likedItem])
        XCTAssertEqual(toggleInputs.count, 1)
        XCTAssertEqual(toggleInputs.first?.0, likedItem.postID)
        XCTAssertEqual(toggleInputs.first?.1, true)
    }

}

@MainActor
private final class ControlledProfileActivityLoader {
    private var continuation:
        CheckedContinuation<ProfileActivityPage, Error>?

    var hasRequest: Bool { continuation != nil }

    func load(
        kind: ProfileActivityKind,
        cursor: ProfileActivityCursor?,
        limit: Int
    ) async throws -> ProfileActivityPage {
        _ = kind
        _ = cursor
        _ = limit
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func succeed(page: ProfileActivityPage) {
        continuation?.resume(returning: page)
        continuation = nil
    }
}

@MainActor
private final class CancellableProfileActivityLoader {
    private(set) var requestCount = 0

    func load(
        kind: ProfileActivityKind,
        cursor: ProfileActivityCursor?,
        limit: Int
    ) async throws -> ProfileActivityPage {
        _ = cursor
        _ = limit
        requestCount += 1
        if requestCount == 1 {
            try await Task.sleep(for: .seconds(30))
        }
        return ProfileActivityPage(
            items: [.fixture(index: requestCount + 20, kind: kind)],
            nextCursor: nil
        )
    }
}

private extension ProfileActivityItem {
    static func fixture(
        index: Int,
        kind: ProfileActivityKind,
        postKind: PostKind = .forum
    ) -> ProfileActivityItem {
        let id = UUID(
            uuidString: String(
                format: "96000000-0000-4000-8000-%012d",
                index
            )
        )!
        return ProfileActivityItem(
            activityID: id,
            postID: id,
            postType: postKind.rawValue,
            postTitle: "测试帖子 \(index)",
            postSummary: "摘要",
            activitySummary: kind.title,
            commentID: nil,
            activityCreatedAt: Date(
                timeIntervalSince1970: 1_800_000_000 - Double(index)
            ),
            price: nil,
            coverImage: nil
        )
    }
}

@MainActor
private func waitForProfileActivityCondition(
    timeout: TimeInterval = 2,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        await Task.yield()
    }
}
