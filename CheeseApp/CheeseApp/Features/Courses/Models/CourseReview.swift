import Foundation

struct CourseProfessorOption: Identifiable, Hashable {
    let id: UUID
    let name: String
}

struct CourseAcademicTermOption: Identifiable, Hashable {
    let id: UUID
    let academicYear: Int
    let term: CourseAcademicTerm

    var title: String {
        "\(academicYear) \(term.title)"
    }
}

struct CourseRatingAggregate: Hashable {
    let reviewCount: Int
    let overallRating: Double?
    let funRating: Double?
    let usefulRating: Double?
    let easyARating: Double?
    let professorRating: Double?

    static let empty = CourseRatingAggregate(
        reviewCount: 0,
        overallRating: nil,
        funRating: nil,
        usefulRating: nil,
        easyARating: nil,
        professorRating: nil
    )
}

struct CourseProfessorRatingAggregate: Hashable {
    let professorID: UUID
    let aggregate: CourseRatingAggregate
}

struct CourseReview: Identifiable, Hashable {
    let id: UUID
    let professorID: UUID
    let professorName: String
    let academicTermID: UUID
    let overallRating: Int
    let funRating: Int
    let usefulRating: Int
    let easyARating: Int
    let professorRating: Int
    let reviewText: String?
    let academicYear: Int
    let term: CourseAcademicTerm
    let createdAt: Date
    let updatedAt: Date
    let isMine: Bool

    var termTitle: String {
        "\(academicYear) \(term.title)"
    }
}

struct CourseReviewSnapshot: Hashable {
    let professors: [CourseProfessorOption]
    let academicTerms: [CourseAcademicTermOption]
    let reviews: [CourseReview]
    let aggregate: CourseRatingAggregate
    let professorAggregates: [CourseProfessorRatingAggregate]

    static let empty = CourseReviewSnapshot(
        professors: [],
        academicTerms: [],
        reviews: [],
        aggregate: .empty,
        professorAggregates: []
    )

    var ownReview: CourseReview? {
        reviews.first(where: \.isMine)
    }
}

struct CourseReviewDraft: Equatable {
    static let maximumTextLength = 500

    var professorID: UUID?
    var academicTermID: UUID?
    var overallRating = 0
    var funRating = 0
    var usefulRating = 0
    var easyARating = 0
    var professorRating = 0
    var reviewText = ""

    init(review: CourseReview? = nil) {
        professorID = review?.professorID
        academicTermID = review?.academicTermID
        overallRating = review?.overallRating ?? 0
        funRating = review?.funRating ?? 0
        usefulRating = review?.usefulRating ?? 0
        easyARating = review?.easyARating ?? 0
        professorRating = review?.professorRating ?? 0
        reviewText = review?.reviewText ?? ""
    }

    var remainingTextCount: Int {
        Self.maximumTextLength - reviewText.count
    }

    var canSubmit: Bool {
        professorID != nil
            && academicTermID != nil
            && (1...5).contains(overallRating)
            && (1...5).contains(funRating)
            && (1...5).contains(usefulRating)
            && (1...5).contains(easyARating)
            && (1...5).contains(professorRating)
            && reviewText.count <= Self.maximumTextLength
    }

    func validatedInput() throws -> CourseReviewInput {
        guard let professorID, let academicTermID, canSubmit else {
            throw CourseReviewValidationError.incomplete
        }

        let trimmedText = reviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        return CourseReviewInput(
            professorID: professorID,
            academicTermID: academicTermID,
            overallRating: overallRating,
            funRating: funRating,
            usefulRating: usefulRating,
            easyARating: easyARating,
            professorRating: professorRating,
            reviewText: trimmedText.isEmpty ? nil : trimmedText
        )
    }
}

struct CourseReviewInput: Equatable {
    let professorID: UUID
    let academicTermID: UUID
    let overallRating: Int
    let funRating: Int
    let usefulRating: Int
    let easyARating: Int
    let professorRating: Int
    let reviewText: String?
}

enum CourseReviewValidationError: LocalizedError {
    case incomplete

    var errorDescription: String? {
        L10n.tr(
            "Choose a term and professor, then complete all five ratings.",
            "请选择年份学期和教授，并完成五项评分。"
        )
    }
}
