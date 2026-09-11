import XCTest
@testable import CheeseApp

@MainActor
final class SearchPaginationViewModelTests: XCTestCase {
    func testSearchPreloadsEveryTabOnceAndSwitchingDoesNotRefetch() async {
        var calls: [SearchCategory: Int] = [:]
        var profileCalls = 0
        let forum = makeResult(title: "forum", rankScore: 1)
        let market = makeResult(title: "market", category: .secondhand, rankScore: 2)
        let model = SearchViewModel(
            loadPostPage: { _, category, _, _ in
                calls[category, default: 0] += 1
                return SearchPostPage(results: category == .forum ? [forum] : category == .secondhand ? [market] : [forum, market], nextCursor: nil)
            }, loadPostCounts: { [:] }, loadProfiles: { _, _ in profileCalls += 1; return [] },
            searchDebounceNanoseconds: 0
        )
        model.updateSearch(text: "query", category: .all)
        await waitUntil { !model.isSearching && calls.count == 3 }
        XCTAssertEqual(model.cachedSearchResults(for: .forum).map(\.id), [forum.id])
        XCTAssertEqual(model.cachedSearchResults(for: .secondhand).map(\.id), [market.id])
        for category in [SearchCategory.forum, .secondhand, .all, .forum] {
            model.updateSearch(text: " query ", category: category)
            XCTAssertFalse(model.isSearching)
            XCTAssertFalse(model.filteredResults.isEmpty)
        }
        await Task.yield()
        XCTAssertEqual(calls, [.all: 1, .forum: 1, .secondhand: 1])
        XCTAssertEqual(profileCalls, 1)
        // A real post mutation must still invalidate all tabs for this query.
        model.updateSearch(text: "query", category: .forum, forceRefresh: true)
        await waitUntil { !model.isSearching && profileCalls == 2 }
        XCTAssertEqual(calls, [.all: 2, .forum: 2, .secondhand: 2])
    }

    func testTabSwitchDuringBatchKeepsOneRequestAndPublishesTogether() async {
        var started = Set<SearchCategory>()
        var releaseProfiles = false
        let result = makeResult(title: "result", rankScore: 1)
        let model = SearchViewModel(
            loadPostPage: { _, category, _, _ in
                started.insert(category)
                return SearchPostPage(results: [result], nextCursor: nil)
            }, loadPostCounts: { [:] }, loadProfiles: { _, _ in
                while !releaseProfiles { await Task.yield() }
                return []
            }, searchDebounceNanoseconds: 0
        )
        model.updateSearch(text: "query", category: .all)
        await waitUntil { started.count == 3 }
        model.updateSearch(text: "query", category: .forum)
        XCTAssertTrue(model.isSearching)
        XCTAssertTrue(model.cachedSearchResults(for: .all).isEmpty)
        releaseProfiles = true
        await waitUntil { !model.isSearching }
        XCTAssertEqual(model.filteredResults.map(\.id), [result.id])
        XCTAssertEqual(model.cachedSearchResults(for: .secondhand).map(\.id), [result.id])
    }

    func testOneFailedCategoryDoesNotDiscardOtherPreloadedTabs() async {
        let result = makeResult(title: "forum", rankScore: 1)
        let model = SearchViewModel(
            loadPostPage: { _, category, _, _ in
                if category == .secondhand { throw SearchPaginationTestError.failed }
                return SearchPostPage(results: [result], nextCursor: nil)
            }, loadPostCounts: { [:] }, loadProfiles: { _, _ in [] }, searchDebounceNanoseconds: 0
        )
        model.updateSearch(text: "query", category: .all)
        await waitUntil { !model.isSearching }
        model.updateSearch(text: "query", category: .secondhand)
        XCTAssertEqual(model.searchPageErrorMessage, "暂时无法完成操作，请重试；若问题持续，请联络客服。")
        model.updateSearch(text: "query", category: .forum)
        XCTAssertEqual(model.filteredResults.map(\.id), [result.id])
        XCTAssertNil(model.searchPageErrorMessage)
    }

    func testStaleEarlierSearchCannotReplaceNewerQuery() async {
        let oldResult = makeResult(title: "old", rankScore: 1)
        let newResult = makeResult(title: "new", rankScore: 2)
        let viewModel = SearchViewModel(
            loadPostPage: { query, _, _, _ in
                if query == "old" {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    return SearchPostPage(results: [oldResult], nextCursor: nil)
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
                return SearchPostPage(results: [newResult], nextCursor: nil)
            },
            loadPostCounts: { [:] },
            loadProfiles: { _, _ in [] },
            searchDebounceNanoseconds: 0
        )

        viewModel.updateSearch(text: "old", category: .all)
        await Task.yield()
        viewModel.updateSearch(text: "new", category: .all)

        await waitUntil {
            !viewModel.isSearching && viewModel.filteredResults.first?.title == "new"
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(viewModel.filteredResults.map(\.id), [newResult.id])
    }

    func testNextPageFailurePreservesLoadedResultsAndRetryCursor() async {
        let first = makeResult(title: "first", rankScore: 10)
        let cursor = SearchPostCursor(
            rankScore: first.rankScore,
            createdAt: try! XCTUnwrap(first.createdAt),
            id: first.id
        )
        let viewModel = SearchViewModel(
            loadPostPage: { _, _, suppliedCursor, _ in
                if suppliedCursor == nil {
                    return SearchPostPage(results: [first], nextCursor: cursor)
                }
                throw SearchPaginationTestError.failed
            },
            loadPostCounts: { [:] },
            loadProfiles: { _, _ in [] },
            searchDebounceNanoseconds: 0
        )

        viewModel.updateSearch(text: "first", category: .forum)
        await waitUntil { !viewModel.isSearching && viewModel.hasMoreSearchResults }
        await viewModel.loadMoreSearchResults()

        XCTAssertEqual(viewModel.filteredResults.map(\.id), [first.id])
        XCTAssertTrue(viewModel.hasMoreSearchResults)
        XCTAssertEqual(viewModel.searchPageErrorMessage, "暂时无法完成操作，请重试；若问题持续，请联络客服。")
        XCTAssertFalse(viewModel.isLoadingMoreSearchResults)
    }

    func testAccountSwitchRejectsEarlierSearchCompletion() async {
        let accountA = UUID(uuidString: "a5100000-0000-4000-8000-000000000001")!
        let accountB = UUID(uuidString: "b5100000-0000-4000-8000-000000000001")!
        let oldResult = makeResult(title: "account-a", rankScore: 1)
        let newResult = makeResult(title: "account-b", rankScore: 2)
        let viewModel = SearchViewModel(
            loadPostPage: { query, _, _, _ in
                if query == "account-a" {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    return SearchPostPage(results: [oldResult], nextCursor: nil)
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
                return SearchPostPage(results: [newResult], nextCursor: nil)
            },
            loadPostCounts: { [:] },
            loadProfiles: { _, _ in [] },
            searchDebounceNanoseconds: 0
        )

        viewModel.activateAccount(accountA)
        viewModel.updateSearch(text: "account-a", category: .all)
        await Task.yield()
        viewModel.activateAccount(accountB)
        viewModel.updateSearch(text: "account-b", category: .all)

        await waitUntil {
            !viewModel.isSearching && viewModel.filteredResults.first?.title == "account-b"
        }
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(viewModel.filteredResults.map(\.id), [newResult.id])
    }

    func testRecentSearchesAreScopedByAccount() {
        let suiteName = "SearchPaginationViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accountA = UUID(uuidString: "a5200000-0000-4000-8000-000000000001")!
        let accountB = UUID(uuidString: "b5200000-0000-4000-8000-000000000001")!
        let viewModel = SearchViewModel(
            loadPostPage: { _, _, _, _ in
                SearchPostPage(results: [], nextCursor: nil)
            },
            loadPostCounts: { [:] },
            loadProfiles: { _, _ in [] },
            searchDebounceNanoseconds: 0,
            defaults: defaults
        )

        viewModel.activateAccount(accountA)
        viewModel.addRecentSearch("ECON 1B03")
        XCTAssertEqual(viewModel.recentSearches, ["ECON 1B03"])

        viewModel.activateAccount(accountB)
        XCTAssertTrue(viewModel.recentSearches.isEmpty)
        viewModel.addRecentSearch("MATH 1A03")

        viewModel.activateAccount(accountA)
        XCTAssertEqual(viewModel.recentSearches, ["ECON 1B03"])
    }

    func testAccountDeletionClearsOnlyDeletedAccountRecentSearches() {
        let suiteName = "SearchPaginationViewModelTests.deletion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let deletedAccount = UUID()
        let retainedAccount = UUID()
        let deletedKey = SearchViewModel.recentSearchesStorageKey(for: deletedAccount)
        let retainedKey = SearchViewModel.recentSearchesStorageKey(for: retainedAccount)
        defaults.set(["private deleted-account search"], forKey: deletedKey)
        defaults.set(["retained account search"], forKey: retainedKey)

        SearchViewModel.clearStoredRecentSearches(for: deletedAccount, defaults: defaults)

        XCTAssertNil(defaults.stringArray(forKey: deletedKey))
        XCTAssertEqual(defaults.stringArray(forKey: retainedKey), ["retained account search"])
    }

    func testPopularFeedMergesCategoriesByHotScore() async {
        let secondhand = makeResult(
            title: "secondhand",
            category: .secondhand,
            hotScore: 10,
            rankScore: 1
        )
        let forum = makeResult(
            title: "forum",
            category: .forum,
            hotScore: 20,
            rankScore: 2
        )
        let viewModel = SearchViewModel(
            loadPostPage: { _, category, _, _ in
                switch category {
                case .secondhand:
                    return SearchPostPage(results: [secondhand], nextCursor: nil)
                case .forum:
                    return SearchPostPage(results: [forum], nextCursor: nil)
                case .all:
                    return SearchPostPage(results: [], nextCursor: nil)
                }
            },
            loadPostCounts: { [:] },
            loadProfiles: { _, _ in [] },
            searchDebounceNanoseconds: 0
        )

        await viewModel.loadInitialData()

        XCTAssertEqual(viewModel.feedPosts(for: .hot).map(\.id), [forum.id, secondhand.id])
        XCTAssertEqual(viewModel.feedPosts(for: .secondhand).map(\.id), [secondhand.id])
        XCTAssertEqual(viewModel.feedPosts(for: .forum).map(\.id), [forum.id])
    }

    func testLatestFeedMergesCategoriesByCreationDate() async {
        let older = makeResult(
            title: "older",
            category: .secondhand,
            hotScore: 100,
            rankScore: 1
        )
        let newer = makeResult(
            title: "newer",
            category: .forum,
            hotScore: 1,
            rankScore: 2
        )
        let viewModel = SearchViewModel(
            loadPostPage: { _, category, _, _ in
                switch category {
                case .secondhand:
                    return SearchPostPage(results: [older], nextCursor: nil)
                case .forum:
                    return SearchPostPage(results: [newer], nextCursor: nil)
                case .all:
                    return SearchPostPage(results: [], nextCursor: nil)
                }
            },
            loadPostCounts: { [:] },
            loadProfiles: { _, _ in [] },
            searchDebounceNanoseconds: 0
        )

        await viewModel.loadInitialData()

        XCTAssertEqual(viewModel.feedPosts(for: .latest).map(\.id), [newer.id, older.id])
    }

    func testPublicUIDSearchPublishesExactProfileResult() async {
        let profileID = UUID(uuidString: "08fcfe03-47d3-471e-a684-03bf064cf3b2")!
        let publicID = "58310427"
        let expectedProfile = SearchProfileResult(
            id: profileID,
            publicID: publicID,
            fullName: "UID Match",
            avatarURL: nil,
            university: nil,
            bio: nil,
            isFollowing: false,
            isMutualFollow: false
        )
        var receivedProfileQuery: String?
        let viewModel = SearchViewModel(
            loadPostPage: { _, _, _, _ in
                SearchPostPage(results: [], nextCursor: nil)
            },
            loadPostCounts: { [:] },
            loadProfiles: { query, _ in
                receivedProfileQuery = query
                return [expectedProfile]
            },
            searchDebounceNanoseconds: 0
        )

        viewModel.updateSearch(text: "  \(publicID)  ", category: .all)
        await waitUntil { viewModel.profileResults == [expectedProfile] }

        XCTAssertEqual(receivedProfileQuery, publicID)
        XCTAssertEqual(viewModel.profileResults.first?.id, profileID)
    }

    func testFollowEventUpdatesVisibleProfileResultWithoutRefetch() async {
        let profileID = UUID()
        let profile = SearchProfileResult(
            id: profileID,
            publicID: "58310428",
            fullName: "Follow target",
            avatarURL: nil,
            university: nil,
            bio: nil,
            isFollowing: false,
            isMutualFollow: false
        )
        let viewModel = SearchViewModel(
            loadPostPage: { _, _, _, _ in
                SearchPostPage(results: [], nextCursor: nil)
            },
            loadPostCounts: { [:] },
            loadProfiles: { _, _ in [profile] },
            searchDebounceNanoseconds: 0
        )
        viewModel.activateAccount(UUID())
        viewModel.updateSearch(text: "target", category: .all)
        await waitUntil { viewModel.profileResults == [profile] }

        viewModel.applyFollowChange(targetUserID: profileID, isFollowing: true)

        XCTAssertTrue(viewModel.profileResults.first?.isFollowing == true)
    }

    private func makeResult(
        title: String,
        category: SearchCategory = .forum,
        hotScore: Double = 0,
        rankScore: Double
    ) -> UnifiedSearchResult {
        UnifiedSearchResult(
            id: UUID(),
            title: title,
            subtitle: "fixture",
            category: category,
            createdAt: Date(timeIntervalSince1970: rankScore),
            previewImageURL: nil,
            hotScore: hotScore,
            rankScore: rankScore
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition was not met before timeout", file: file, line: line)
    }
}

private enum SearchPaginationTestError: LocalizedError {
    case failed

    var errorDescription: String? { "failed" }
}
