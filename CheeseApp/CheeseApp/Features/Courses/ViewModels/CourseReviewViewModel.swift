import Combine
import Foundation

enum CourseReviewLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
final class CourseReviewViewModel: ObservableObject {
    @Published private(set) var snapshot = CourseReviewSnapshot.empty
    @Published var draft = CourseReviewDraft()
    @Published var selectedProfessorID: UUID?
    @Published private(set) var loadState = CourseReviewLoadState.idle
    @Published private(set) var isSubmitting = false
    @Published private(set) var errorMessage: String?

    let courseID: UUID

    private let service: CourseReviewService
    private let snapshotLoader: (UUID) async throws -> CourseReviewSnapshot

    init(
        courseID: UUID,
        service: CourseReviewService? = nil,
        snapshotLoader: ((UUID) async throws -> CourseReviewSnapshot)? = nil
    ) {
        let resolvedService = service ?? .shared
        self.courseID = courseID
        self.service = resolvedService
        self.snapshotLoader = snapshotLoader ?? resolvedService.loadSnapshot
    }

    var isLoading: Bool {
        loadState == .loading
    }

    var loadErrorMessage: String? {
        guard case let .failed(message) = loadState else { return nil }
        return message
    }

    var visibleReviews: [CourseReview] {
        guard let selectedProfessorID else { return snapshot.reviews }
        return snapshot.reviews.filter { $0.professorID == selectedProfessorID }
    }

    var displayedAggregate: CourseRatingAggregate {
        let professorRating = selectedProfessorID.flatMap { professorID in
            snapshot.professorAggregates.first {
                $0.professorID == professorID
            }?.aggregate.professorRating
        }

        return CourseRatingAggregate(
            reviewCount: snapshot.aggregate.reviewCount,
            overallRating: snapshot.aggregate.overallRating,
            funRating: snapshot.aggregate.funRating,
            usefulRating: snapshot.aggregate.usefulRating,
            easyARating: snapshot.aggregate.easyARating,
            professorRating: professorRating
        )
    }

    var canSubmit: Bool {
        draft.canSubmit && !isSubmitting
    }

    func load() async {
        loadState = .loading

        do {
            try await reload(courseID: courseID, resetDraft: true)
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func submit() async -> Bool {
        guard !isSubmitting else { return false }

        do {
            let input = try draft.validatedInput()
            isSubmitting = true
            errorMessage = nil
            defer { isSubmitting = false }

            try await service.saveReview(courseID: courseID, input: input)
            try await reload(courseID: courseID, resetDraft: true)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func prepareOwnReviewForEditing() {
        draft = CourseReviewDraft(review: snapshot.ownReview)
        errorMessage = nil
    }

    func deleteOwnReview() async {
        guard snapshot.ownReview != nil, !isSubmitting else { return }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await service.deleteReview(courseID: courseID)
            try await reload(courseID: courseID, resetDraft: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func reload(courseID: UUID, resetDraft: Bool) async throws {
        let updatedSnapshot = try await snapshotLoader(courseID)
        snapshot = updatedSnapshot

        if let selectedProfessorID,
           !updatedSnapshot.professors.contains(where: { $0.id == selectedProfessorID }) {
            self.selectedProfessorID = nil
        }

        if resetDraft {
            draft = CourseReviewDraft(review: updatedSnapshot.ownReview)
            if updatedSnapshot.ownReview == nil,
               updatedSnapshot.professors.count == 1 {
                draft.professorID = updatedSnapshot.professors[0].id
            }
        }
    }
}
