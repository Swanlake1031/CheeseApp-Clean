import Combine
import Foundation

@MainActor
final class ChatFollowSearchViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [SearchProfileResult] = []
    @Published private(set) var isLoading = false
    @Published private(set) var togglingUserIDs: Set<UUID> = []
    @Published var errorMessage: String?

    private let searchService = SearchService.shared
    private var searchTask: Task<Void, Never>?

    func updateQuery(_ newValue: String) {
        query = newValue
        searchTask?.cancel()

        let normalized = normalizedQuery
        guard !normalized.isEmpty else {
            isLoading = false
            errorMessage = nil
            results = []
            return
        }

        isLoading = true
        errorMessage = nil
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 260_000_000)
            } catch {
                return
            }
            guard let self else { return }
            await self.reloadResults(query: normalized)
        }
    }

    func toggleFollow(for profile: SearchProfileResult) async {
        guard !togglingUserIDs.contains(profile.id) else { return }
        togglingUserIDs.insert(profile.id)
        defer { togglingUserIDs.remove(profile.id) }

        do {
            if profile.isFollowing {
                try await searchService.unfollowUser(targetUserId: profile.id)
            } else {
                try await searchService.followUser(targetUserId: profile.id)
            }

            await reloadResults(query: normalizedQuery)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isToggling(_ userID: UUID) -> Bool {
        togglingUserIDs.contains(userID)
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reloadResults(query: String) async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            isLoading = false
            errorMessage = nil
            results = []
            return
        }

        do {
            let rows = try await searchService.searchProfiles(query: normalized, limit: 20)
            guard !Task.isCancelled else { return }

            let currentUserID = AuthService.shared.currentUser?.id
            results = rows.filter { $0.id != currentUserID }
            errorMessage = nil
            isLoading = false
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}
