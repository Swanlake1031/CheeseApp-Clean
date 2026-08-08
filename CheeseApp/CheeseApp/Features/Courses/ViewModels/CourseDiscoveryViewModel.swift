import Combine
import Foundation

enum CourseCatalogLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
final class CourseDiscoveryViewModel: ObservableObject {
    @Published private(set) var courses: [CourseSummary] = []
    @Published private(set) var loadState = CourseCatalogLoadState.idle

    private let loader: () async throws -> [CourseSummary]

    init(
        loader: (() async throws -> [CourseSummary])? = nil
    ) {
        self.loader = loader ?? CourseCatalogService.shared.loadCourses
    }

    var isLoading: Bool {
        loadState == .loading
    }

    func load(force: Bool = false) async {
        guard !isLoading, force || loadState != .loaded else { return }

        loadState = .loading
        do {
            courses = try await loader()
            loadState = .loaded
        } catch {
            guard !Task.isCancelled else {
                loadState = courses.isEmpty ? .idle : .loaded
                return
            }
            loadState = .failed(error.localizedDescription)
        }
    }
}
