import XCTest
@testable import CheeseApp

@MainActor
final class ChatAccountIsolationTests: XCTestCase {
    func testLateAccountARefreshCannotOverwriteAccountB() async throws {
        let accountA = UUID(uuidString: "a1000000-0000-4000-8000-000000000001")!
        let accountB = UUID(uuidString: "b1000000-0000-4000-8000-000000000001")!
        let identity = TestChatIdentity(accountA)
        let loader = ControlledChatSnapshotLoader()
        let service = ChatService(
            currentUserIDProvider: { identity.userID },
            conversationStateLoader: { userID in
                try await loader.load(userID: userID)
            }
        )

        service.activateAccount(accountA)
        let accountATask = Task { @MainActor in
            await service.refreshConversations()
        }
        await waitUntil { loader.hasRequest(for: accountA) }

        service.beginAccountTransition()
        identity.userID = accountB
        service.activateAccount(accountB)
        let accountBTask = Task { @MainActor in
            await service.refreshConversations()
        }
        await waitUntil { loader.hasRequest(for: accountB) }

        loader.succeed(
            userID: accountB,
            snapshot: .fixture(ownerName: "Account B")
        )
        await accountBTask.value
        loader.fail(userID: accountA, error: URLError(.timedOut))
        await accountATask.value

        XCTAssertEqual(service.conversations.map(\.otherUserName), ["Account B"])
        XCTAssertNil(service.conversationErrorMessage)
        XCTAssertTrue(service.hasResolvedInitialConversationLoad)
        XCTAssertFalse(service.isLoadingConversations)
    }

    func testAccountTransitionClearsConversationGroupAndUnreadState() async {
        let accountA = UUID(uuidString: "a2000000-0000-4000-8000-000000000001")!
        let accountB = UUID(uuidString: "b2000000-0000-4000-8000-000000000001")!
        let identity = TestChatIdentity(accountA)
        let service = ChatService(
            currentUserIDProvider: { identity.userID },
            conversationStateLoader: { _ in
                ChatConversationRepositorySnapshot(
                    directConversations: [.fixture(name: "Direct", unreadCount: 4)],
                    groupConversations: [.fixture(name: "Group", unreadCount: 7)]
                )
            }
        )

        service.activateAccount(accountA)
        await service.refreshConversations()
        XCTAssertEqual(service.conversations.first?.unreadCount, 4)
        XCTAssertEqual(service.groupConversations.first?.unreadCount, 7)

        let previousGeneration = service.accountGeneration
        service.beginAccountTransition()

        XCTAssertTrue(service.conversations.isEmpty)
        XCTAssertTrue(service.groupConversations.isEmpty)
        XCTAssertFalse(service.hasResolvedInitialConversationLoad)
        XCTAssertFalse(service.isLoadingConversations)
        XCTAssertTrue(service.isAccountTransitionInProgress)
        XCTAssertGreaterThan(service.accountGeneration, previousGeneration)

        identity.userID = accountB
        service.activateAccount(accountB)
        XCTAssertTrue(service.isAccountScopeReady)
    }

    func testFailedSwitchCanReactivateAndReloadOriginalAccount() async {
        let accountA = UUID(uuidString: "a3000000-0000-4000-8000-000000000001")!
        let identity = TestChatIdentity(accountA)
        var loadCount = 0
        let service = ChatService(
            currentUserIDProvider: { identity.userID },
            conversationStateLoader: { _ in
                loadCount += 1
                return .fixture(ownerName: "Restored A \(loadCount)")
            }
        )

        service.activateAccount(accountA)
        await service.refreshConversations()
        XCTAssertEqual(service.conversations.first?.otherUserName, "Restored A 1")

        service.beginAccountTransition()
        service.activateAccount(accountA)
        await service.refreshConversations()

        XCTAssertEqual(service.conversations.first?.otherUserName, "Restored A 2")
        XCTAssertTrue(service.isAccountScopeReady)
        XCTAssertEqual(loadCount, 2)
    }

    func testCancelledViewTaskDoesNotBecomeAnInboxError() async {
        let account = UUID(uuidString: "a4000000-0000-4000-8000-000000000001")!
        let service = ChatService(
            currentUserIDProvider: { account },
            conversationStateLoader: { _ in
                try await Task.sleep(for: .seconds(30))
                return .fixture(ownerName: "Too late")
            }
        )

        service.activateAccount(account)
        let task = Task { @MainActor in
            await service.refreshConversations()
        }
        await waitUntil { service.isLoadingConversations }
        task.cancel()
        await task.value

        XCTAssertNil(service.conversationErrorMessage)
        XCTAssertFalse(service.hasResolvedInitialConversationLoad)
        XCTAssertFalse(service.isLoadingConversations)
        XCTAssertEqual(service.conversationListState, .unresolved)
    }

    func testRefreshRequestedWhileLoadingRunsTrailingSnapshot() async {
        let account = UUID(uuidString: "a4100000-0000-4000-8000-000000000001")!
        let loader = ControlledChatSnapshotLoader()
        let service = ChatService(
            currentUserIDProvider: { account },
            conversationStateLoader: { userID in
                try await loader.load(userID: userID)
            }
        )

        service.activateAccount(account)
        let firstRefresh = Task { @MainActor in
            await service.refreshConversations()
        }
        await waitUntil { loader.requestCount(for: account) == 1 }

        // This models a Push arriving while the initial/manual refresh is in flight.
        await service.refreshConversations()
        loader.succeed(userID: account, snapshot: .fixture(ownerName: "Old snapshot"))

        await waitUntil { loader.requestCount(for: account) == 2 }
        loader.succeed(userID: account, snapshot: .fixture(ownerName: "Push snapshot"))
        await waitUntil {
            service.conversations.first?.otherUserName == "Push snapshot"
                && !service.isLoadingConversations
        }
        await firstRefresh.value

        XCTAssertEqual(service.conversations.map(\.otherUserName), ["Push snapshot"])
        XCTAssertEqual(loader.requestCount(for: account), 2)
        XCTAssertNil(service.conversationErrorMessage)
    }

    func testWrappedNetworkCancellationUsesActionableInboxError() async {
        let account = UUID(uuidString: "a5000000-0000-4000-8000-000000000001")!
        let service = ChatService(
            currentUserIDProvider: { account },
            conversationStateLoader: { _ in
                throw NSError(
                    domain: "PostgREST",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "cancelled"]
                )
            }
        )

        service.activateAccount(account)
        await service.refreshConversations()

        XCTAssertEqual(service.conversationErrorMessage, "连接中断，请重试。")
        XCTAssertTrue(service.hasResolvedInitialConversationLoad)
        XCTAssertFalse(service.isLoadingConversations)
        XCTAssertEqual(
            service.conversationListState,
            .error(message: "连接中断，请重试。")
        )
    }

    func testRemoteImageCacheEvictsDiskAndAdvancesGeneration() throws {
        let responseCache = URLCache(
            memoryCapacity: 1_024_000,
            diskCapacity: 1_024_000,
            diskPath: "chat-account-isolation-tests-\(UUID().uuidString)"
        )
        let configuration = URLSessionConfiguration.ephemeral
        let cache = RemoteImageCache(
            responseCache: responseCache,
            configuration: configuration
        )
        let url = URL(string: "https://example.com/private-avatar.jpg")!
        let request = URLRequest(url: url)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        responseCache.storeCachedResponse(
            CachedURLResponse(response: response, data: Data([1, 2, 3])),
            for: request
        )
        let generation = cache.generation

        cache.removeAll()

        XCTAssertNil(responseCache.cachedResponse(for: request))
        XCTAssertEqual(cache.generation, generation + 1)
    }

    func testRemoteImageRequestKeysSeparateCardAndDetailDecodeSizes() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://cdn.example.com/photo.jpg"))

        XCTAssertNotEqual(
            RemoteImageRequestKey(url: sourceURL, maxPixelSize: 640),
            RemoteImageRequestKey(url: sourceURL, maxPixelSize: 2_048)
        )
    }

    func testAccountTransitionDiscardsOnlyChatNotificationRoute() {
        let router = AppNotificationRouter()
        router.enqueue(.conversation(UUID()))
        router.discardAccountScopedChatAction()
        XCTAssertNil(router.pendingAction)

        let postRoute = PostDeepLinkRoute(kind: .forum, postId: UUID())
        router.enqueue(.post(postRoute))
        router.discardAccountScopedChatAction()
        XCTAssertEqual(router.pendingAction?.target, .post(postRoute))
    }

    func testFeatureServicesClearViewerRelativeStateAndInvalidateRequests() {
        let accountA = UUID(uuidString: "a5500000-0000-4000-8000-000000000001")!
        let accountB = UUID(uuidString: "b5500000-0000-4000-8000-000000000001")!

        let forum = ForumService.shared
        forum.activateAccount(accountA)
        forum.posts = [.accountIsolationFixture()]
        forum.isLoading = true
        forum.errorMessage = "Account A"
        let forumGeneration = forum.accountGeneration

        let secondhand = SecondhandService.shared
        secondhand.activateAccount(accountA)
        secondhand.items = [.accountIsolationFixture()]
        secondhand.isLoading = true
        secondhand.errorMessage = "Account A"
        let secondhandGeneration = secondhand.accountGeneration

        forum.beginAccountTransition()
        secondhand.beginAccountTransition()

        XCTAssertTrue(forum.posts.isEmpty)
        XCTAssertFalse(forum.isLoading)
        XCTAssertNil(forum.errorMessage)
        XCTAssertFalse(forum.isCurrentAccountRequest(generation: forumGeneration))

        XCTAssertTrue(secondhand.items.isEmpty)
        XCTAssertFalse(secondhand.isLoading)
        XCTAssertNil(secondhand.errorMessage)
        XCTAssertFalse(secondhand.isCurrentAccountRequest(generation: secondhandGeneration))

        forum.activateAccount(accountB)
        secondhand.activateAccount(accountB)
        XCTAssertTrue(forum.isAccountScopeReady)
        XCTAssertTrue(secondhand.isAccountScopeReady)

        forum.beginAccountTransition()
        secondhand.beginAccountTransition()
        forum.activateAccount(nil)
        secondhand.activateAccount(nil)
    }
}

@MainActor
private final class TestChatIdentity {
    var userID: UUID

    init(_ userID: UUID) {
        self.userID = userID
    }
}

@MainActor
private final class ControlledChatSnapshotLoader {
    private var continuations: [
        UUID: CheckedContinuation<ChatConversationRepositorySnapshot, Error>
    ] = [:]
    private var requestCounts: [UUID: Int] = [:]

    func load(userID: UUID) async throws -> ChatConversationRepositorySnapshot {
        requestCounts[userID, default: 0] += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[userID] = continuation
        }
    }

    func hasRequest(for userID: UUID) -> Bool {
        continuations[userID] != nil
    }

    func requestCount(for userID: UUID) -> Int {
        requestCounts[userID, default: 0]
    }

    func succeed(userID: UUID, snapshot: ChatConversationRepositorySnapshot) {
        continuations.removeValue(forKey: userID)?.resume(returning: snapshot)
    }

    func fail(userID: UUID, error: Error) {
        continuations.removeValue(forKey: userID)?.resume(throwing: error)
    }
}

private extension ChatConversationRepositorySnapshot {
    static func fixture(ownerName: String) -> ChatConversationRepositorySnapshot {
        ChatConversationRepositorySnapshot(
            directConversations: [.fixture(name: ownerName, unreadCount: 0)],
            groupConversations: []
        )
    }
}

private extension ChatConversationPreview {
    static func fixture(name: String, unreadCount: Int) -> ChatConversationPreview {
        ChatConversationPreview(
            id: UUID(),
            otherUserId: UUID(),
            otherUserName: name,
            otherUserAvatar: nil,
            relatedPostId: nil,
            lastMessageAt: Date(),
            lastMessagePreview: "Test message",
            unreadCount: unreadCount,
            isMuted: false
        )
    }
}

private extension ChatGroupPreview {
    static func fixture(name: String, unreadCount: Int) -> ChatGroupPreview {
        ChatGroupPreview(
            id: UUID(),
            name: name,
            avatarURL: nil,
            lastMessageAt: Date(),
            lastMessagePreview: "Group message",
            memberCount: 3,
            unreadCount: unreadCount,
            isMuted: false
        )
    }
}

private extension ForumPostItem {
    static func accountIsolationFixture() -> ForumPostItem {
        ForumPostItem(
            id: UUID(),
            authorId: UUID(),
            authorAvatar: nil,
            title: "Account A",
            content: "Viewer-relative state",
            boardID: UUID(),
            boardName: "Forum",
            boardIcon: "bubble.left",
            boardAllowsAnonymous: true,
            authorName: "Account A",
            isAnonymous: false,
            isAuthorOfficial: false,
            timeAgo: "now",
            createdAt: Date(),
            likes: 1,
            comments: 0,
            views: 1,
            isLiked: true,
            isPinned: false,
            imageUrls: [],
            hasImage: false
        )
    }
}

private extension SecondhandItem {
    static func accountIsolationFixture() -> SecondhandItem {
        SecondhandItem(
            id: UUID(),
            sellerId: UUID(),
            title: "Account A",
            price: 10,
            isNegotiable: true,
            category: .homeAppliances,
            condition: "good",
            seller: "Account A",
            sellerAvatar: nil,
            isAnonymous: false,
            hasSellerProfile: true,
            description: "Viewer-relative state",
            timeAgo: "now",
            imageUrl: nil,
            imageUrls: [],
            likeCount: 1,
            isLiked: true,
            isFavorited: true
        )
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
