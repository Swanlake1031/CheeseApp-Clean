import Foundation

@MainActor
final class CourseCatalogService {
    static let shared = CourseCatalogService()

    private let supabase = SupabaseManager.shared

    private init() {}

    func loadCourses() async throws -> [CourseSummary] {
        do {
            _ = try await AuthService.shared.requireAuthUserId()
            let rows: [CourseCatalogRow] = try await supabase.client
                .rpc("get_course_catalog")
                .execute()
                .value
            return rows.map(\.model)
        } catch {
            throw CourseCatalogServiceError.loadFailed
        }
    }
}

enum CourseCatalogServiceError: LocalizedError {
    case loadFailed

    var errorDescription: String? {
        L10n.tr(
            "Unable to load the course catalog. Please try again.",
            "暂时无法加载课程目录，请重试。"
        )
    }
}

private struct CourseCatalogRow: Decodable {
    let id: UUID
    let code: String
    let title: String
    let subject: CourseSubject
    let yearLevel: CourseYearLevel
    let isPopular: Bool
    let professors: [CourseCatalogProfessorRow]
    let reviewCount: Int
    let overallRating: Double?
    let funRating: Double?
    let usefulRating: Double?
    let easyARating: Double?
    let professorRating: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case code
        case title
        case subject
        case yearLevel = "year_level"
        case isPopular = "is_popular"
        case professors
        case reviewCount = "review_count"
        case overallRating = "overall_rating"
        case funRating = "fun_rating"
        case usefulRating = "useful_rating"
        case easyARating = "easy_a_rating"
        case professorRating = "professor_rating"
    }

    var model: CourseSummary {
        CourseSummary(
            id: id,
            code: code,
            title: title,
            subject: subject,
            yearLevel: yearLevel,
            professors: professors.map(\.model),
            aggregate: CourseRatingAggregate(
                reviewCount: reviewCount,
                overallRating: overallRating,
                funRating: funRating,
                usefulRating: usefulRating,
                easyARating: easyARating,
                professorRating: professorRating
            ),
            isPopular: isPopular
        )
    }
}

private struct CourseCatalogProfessorRow: Decodable {
    let id: UUID
    let name: String

    var model: CourseProfessorOption {
        CourseProfessorOption(id: id, name: name)
    }
}
