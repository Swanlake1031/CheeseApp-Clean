import XCTest
@testable import CheeseApp

@MainActor
final class SystemMessageViewModelTests: XCTestCase {
    func testCommentNotificationKindsDecode() {
        XCTAssertEqual(SystemMessageKind(rawValue: "post_comment"), .postComment)
        XCTAssertEqual(SystemMessageKind(rawValue: "comment_reply"), .commentReply)
    }

    func testNotificationKindsMapToSeparatedInboxCategories() {
        XCTAssertEqual(SystemMessageKind.automatic.category, .system)
        XCTAssertEqual(SystemMessageKind.secondhandAvailability.category, .system)
        XCTAssertEqual(SystemMessageKind.postComment.category, .interaction)
        XCTAssertEqual(SystemMessageKind.commentReply.category, .interaction)
        XCTAssertEqual(SystemMessageKind.postLike.category, .interaction)
        XCTAssertEqual(SystemMessageKind.follow.category, .interaction)
    }

    func testAccountSwitchClearsItemsAndDiscardsLatePage() async {
        let accountA = UUID(uuidString: "a9100000-0000-4000-8000-000000000001")!
        let accountB = UUID(uuidString: "b9100000-0000-4000-8000-000000000001")!
        let loader = ControlledSystemMessageLoader()
        let viewModel = SystemMessageViewModel(
            loadPage: { cursor, limit in
                try await loader.load(cursor: cursor, limit: limit)
            }
        )

        viewModel.activateAccount(accountA)
        let task = Task { @MainActor in
            await viewModel.loadInitial()
        }
        await waitForSystemMessageCondition { loader.hasRequest }

        viewModel.activateAccount(accountB)
        loader.succeed(
            page: SystemMessagePage(
                items: [.fixture(index: 1)],
                nextCursor: nil
            )
        )
        await task.value

        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertFalse(viewModel.hasResolvedInitialLoad)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testPaginationDeduplicatesBoundaryMessage() async {
        let account = UUID(uuidString: "a9200000-0000-4000-8000-000000000001")!
        let first = SystemMessageItem.fixture(index: 1)
        let second = SystemMessageItem.fixture(index: 2)
        let cursor = SystemMessageCursor(
            createdAt: first.createdAt,
            id: first.id
        )
        var pages = [
            SystemMessagePage(items: [first], nextCursor: cursor),
            SystemMessagePage(items: [first, second], nextCursor: nil)
        ]
        let viewModel = SystemMessageViewModel(
            pageSize: 2,
            loadPage: { _, _ in pages.removeFirst() }
        )

        viewModel.activateAccount(account)
        await viewModel.loadInitial()
        await viewModel.loadNextPageIfNeeded(currentItem: first)

        XCTAssertEqual(viewModel.items.map(\.id), [first.id, second.id])
        XCTAssertFalse(viewModel.hasMore)
    }

    func testForcedReloadWhileLoadingRunsTrailingPage() async {
        let account = UUID(uuidString: "a9250000-0000-4000-8000-000000000001")!
        let loader = ControlledSystemMessageLoader()
        let first = SystemMessageItem.fixture(index: 1)
        let pushed = SystemMessageItem.fixture(index: 2)
        let viewModel = SystemMessageViewModel(
            loadPage: { cursor, limit in
                try await loader.load(cursor: cursor, limit: limit)
            }
        )

        viewModel.activateAccount(account)
        let initialLoad = Task { @MainActor in
            await viewModel.loadInitial()
        }
        await waitForSystemMessageCondition { loader.requestCount == 1 }

        // An open timeline receives the Push refresh while its first request is pending.
        await viewModel.loadInitial(force: true)
        loader.succeed(page: SystemMessagePage(items: [first], nextCursor: nil))

        await waitForSystemMessageCondition { loader.requestCount == 2 }
        loader.succeed(page: SystemMessagePage(items: [pushed], nextCursor: nil))
        await waitForSystemMessageCondition {
            viewModel.items.map(\.id) == [pushed.id] && !viewModel.isLoading
        }
        await initialLoad.value

        XCTAssertEqual(viewModel.items.map(\.id), [pushed.id])
        XCTAssertEqual(loader.requestCount, 2)
    }

    func testMarkReadUpdatesOnlyTheTargetMessage() async {
        let account = UUID(uuidString: "a9300000-0000-4000-8000-000000000001")!
        let first = SystemMessageItem.fixture(index: 1)
        let second = SystemMessageItem.fixture(index: 2)
        var markedIDs: [UUID] = []
        let viewModel = SystemMessageViewModel(
            loadPage: { _, _ in
                SystemMessagePage(items: [first, second], nextCursor: nil)
            },
            markRead: { markedIDs.append($0) }
        )

        viewModel.activateAccount(account)
        await viewModel.loadInitial()
        await viewModel.markRead(first)

        XCTAssertEqual(markedIDs, [first.id])
        XCTAssertNotNil(viewModel.items[0].readAt)
        XCTAssertNil(viewModel.items[1].readAt)
    }
}

@MainActor
private final class ControlledSystemMessageLoader {
    private var continuation:
        CheckedContinuation<SystemMessagePage, Error>?
    private(set) var requestCount = 0

    var hasRequest: Bool { continuation != nil }

    func load(
        cursor: SystemMessageCursor?,
        limit: Int
    ) async throws -> SystemMessagePage {
        _ = cursor
        _ = limit
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func succeed(page: SystemMessagePage) {
        continuation?.resume(returning: page)
        continuation = nil
    }
}

private extension SystemMessageItem {
    static func fixture(index: Int) -> SystemMessageItem {
        let id = UUID(
            uuidString: String(
                format: "90000000-0000-4000-8000-%012d",
                index
            )
        )!
        return SystemMessageItem(
            id: id,
            eventID: "test:\(index)",
            kind: .automatic,
            title: "系统消息 \(index)",
            body: "测试",
            actorUserID: nil,
            actorName: nil,
            actorAvatarURL: nil,
            postID: nil,
            commentID: nil,
            contentKind: nil,
            ctaKind: .none,
            readAt: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 - Double(index))
        )
    }
}

@MainActor
private func waitForSystemMessageCondition(
    timeout: TimeInterval = 2,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        await Task.yield()
    }
}
