import Foundation

@MainActor
final class CourseReviewService {
    static let shared = CourseReviewService()

    private let supabase = SupabaseManager.shared

    private init() {}

    func loadSnapshot(courseID: UUID) async throws -> CourseReviewSnapshot {
        do {
            _ = try await AuthService.shared.requireAuthUserId()
            let row: CourseReviewSnapshotRow = try await supabase.client
                .rpc(
                    "get_course_review_snapshot",
                    params: CourseReviewSnapshotParams(courseID: courseID)
                )
                .execute()
                .value
            return row.model
        } catch {
            throw CourseReviewServiceError.loadFailed
        }
    }

    func saveReview(courseID: UUID, input: CourseReviewInput) async throws {
        do {
            _ = try await AuthService.shared.requireAuthUserId()
            try await supabase.client
                .rpc(
                    "upsert_course_review",
                    params: CourseReviewMutationParams(
                        courseID: courseID,
                        professorID: input.professorID,
                        overallRating: input.overallRating,
                        funRating: input.funRating,
                        usefulRating: input.usefulRating,
                        easyARating: input.easyARating,
                        professorRating: input.professorRating,
                        reviewText: input.reviewText,
                        academicTermID: input.academicTermID
                    )
                )
                .execute()
        } catch {
            throw CourseReviewServiceError.saveFailed
        }
    }

    func deleteReview(courseID: UUID) async throws {
        do {
            _ = try await AuthService.shared.requireAuthUserId()
            try await supabase.client
                .rpc(
                    "delete_course_review",
                    params: CourseReviewSnapshotParams(courseID: courseID)
                )
                .execute()
        } catch {
            throw CourseReviewServiceError.deleteFailed
        }
    }
}

enum CourseReviewServiceError: LocalizedError {
    case loadFailed
    case saveFailed
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed:
            return L10n.tr(
                "Unable to load course reviews. Please try again.",
                "暂时无法加载课程评价，请重试。"
            )
        case .saveFailed:
            return L10n.tr(
                "Unable to save your review. Please try again.",
                "评价保存失败，请重试。"
            )
        case .deleteFailed:
            return L10n.tr(
                "Unable to delete your review. Please try again.",
                "评价删除失败，请重试。"
            )
        }
    }
}

private struct CourseReviewSnapshotParams: Encodable {
    let courseID: UUID

    enum CodingKeys: String, CodingKey {
        case courseID = "p_course_id"
    }
}

private struct CourseReviewMutationParams: Encodable {
    let courseID: UUID
    let professorID: UUID
    let overallRating: Int
    let funRating: Int
    let usefulRating: Int
    let easyARating: Int
    let professorRating: Int
    let reviewText: String?
    let academicTermID: UUID

    enum CodingKeys: String, CodingKey {
        case courseID = "p_course_id"
        case professorID = "p_professor_id"
        case overallRating = "p_overall_rating"
        case funRating = "p_fun_rating"
        case usefulRating = "p_useful_rating"
        case easyARating = "p_easy_a_rating"
        case professorRating = "p_professor_rating"
        case reviewText = "p_review_text"
        case academicTermID = "p_academic_term_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(courseID, forKey: .courseID)
        try container.encode(professorID, forKey: .professorID)
        try container.encode(overallRating, forKey: .overallRating)
        try container.encode(funRating, forKey: .funRating)
        try container.encode(usefulRating, forKey: .usefulRating)
        try container.encode(easyARating, forKey: .easyARating)
        try container.encode(professorRating, forKey: .professorRating)
        try container.encode(reviewText, forKey: .reviewText)
        try container.encode(academicTermID, forKey: .academicTermID)
    }
}

private struct CourseReviewSnapshotRow: Decodable {
    let professors: [ProfessorRow]
    let academicTerms: [AcademicTermRow]
    let reviews: [ReviewRow]
    let aggregate: AggregateRow
    let professorAggregates: [ProfessorAggregateRow]

    enum CodingKeys: String, CodingKey {
        case professors
        case academicTerms = "academic_terms"
        case reviews
        case aggregate
        case professorAggregates = "professor_aggregates"
    }

    var model: CourseReviewSnapshot {
        CourseReviewSnapshot(
            professors: professors.map(\.model),
            academicTerms: academicTerms.map(\.model),
            reviews: reviews.map(\.model),
            aggregate: aggregate.model,
            professorAggregates: professorAggregates.map(\.model)
        )
    }
}

private struct AcademicTermRow: Decodable {
    let id: UUID
    let academicYear: Int
    let term: CourseAcademicTerm

    enum CodingKeys: String, CodingKey {
        case id
        case academicYear = "academic_year"
        case term
    }

    var model: CourseAcademicTermOption {
        CourseAcademicTermOption(
            id: id,
            academicYear: academicYear,
            term: term
        )
    }
}

private struct ProfessorAggregateRow: Decodable {
    let professorID: UUID
    let aggregate: AggregateRow

    enum CodingKeys: String, CodingKey {
        case professorID = "professor_id"
        case aggregate
    }

    var model: CourseProfessorRatingAggregate {
        CourseProfessorRatingAggregate(
            professorID: professorID,
            aggregate: aggregate.model
        )
    }
}

private struct ProfessorRow: Decodable {
    let id: UUID
    let name: String

    var model: CourseProfessorOption {
        CourseProfessorOption(id: id, name: name)
    }
}

private struct AggregateRow: Decodable {
    let reviewCount: Int
    let overallRating: Double?
    let funRating: Double?
    let usefulRating: Double?
    let easyARating: Double?
    let professorRating: Double?

    enum CodingKeys: String, CodingKey {
        case reviewCount = "review_count"
        case overallRating = "overall_rating"
        case funRating = "fun_rating"
        case usefulRating = "useful_rating"
        case easyARating = "easy_a_rating"
        case professorRating = "professor_rating"
    }

    var model: CourseRatingAggregate {
        CourseRatingAggregate(
            reviewCount: reviewCount,
            overallRating: overallRating,
            funRating: funRating,
            usefulRating: usefulRating,
            easyARating: easyARating,
            professorRating: professorRating
        )
    }
}

private struct ReviewRow: Decodable {
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

    enum CodingKeys: String, CodingKey {
        case id
        case professorID = "professor_id"
        case professorName = "professor_name"
        case academicTermID = "academic_term_id"
        case overallRating = "overall_rating"
        case funRating = "fun_rating"
        case usefulRating = "useful_rating"
        case easyARating = "easy_a_rating"
        case professorRating = "professor_rating"
        case reviewText = "review_text"
        case academicYear = "academic_year"
        case term
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isMine = "is_mine"
    }

    var model: CourseReview {
        CourseReview(
            id: id,
            professorID: professorID,
            professorName: professorName,
            academicTermID: academicTermID,
            overallRating: overallRating,
            funRating: funRating,
            usefulRating: usefulRating,
            easyARating: easyARating,
            professorRating: professorRating,
            reviewText: reviewText,
            academicYear: academicYear,
            term: term,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isMine: isMine
        )
    }
}
