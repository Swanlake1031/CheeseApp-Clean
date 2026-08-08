import XCTest
@testable import CheeseApp

@MainActor
final class SearchPaginationViewModelTests: XCTestCase {
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
        XCTAssertEqual(viewModel.searchPageErrorMessage, "failed")
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

    func testOverallHotRankingMergesCategoriesByHotScore() async {
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

        XCTAssertEqual(viewModel.hotPosts(for: .all).map(\.id), [forum.id, secondhand.id])
        XCTAssertEqual(viewModel.hotPosts(for: .secondhand).map(\.id), [secondhand.id])
        XCTAssertEqual(viewModel.hotPosts(for: .forum).map(\.id), [forum.id])
    }

    func testFullUIDSearchPublishesExactProfileResult() async {
        let profileID = UUID(uuidString: "08fcfe03-47d3-471e-a684-03bf064cf3b2")!
        let expectedProfile = SearchProfileResult(
            id: profileID,
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

        viewModel.updateSearch(text: "  \(profileID.uuidString.lowercased())  ", category: .all)
        await waitUntil { viewModel.profileResults == [expectedProfile] }

        XCTAssertEqual(receivedProfileQuery, profileID.uuidString.lowercased())
        XCTAssertEqual(viewModel.profileResults.first?.id, profileID)
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
