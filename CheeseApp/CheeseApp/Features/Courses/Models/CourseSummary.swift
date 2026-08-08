import Foundation

enum CourseSubject: String, CaseIterable, Codable, Hashable {
    case math = "MATH"
    case stats = "STATS"
    case econ = "ECON"
    case commerce = "COMMERCE"
}

enum CourseYearLevel: Int, CaseIterable, Codable, Hashable {
    case first = 1
    case second = 2
    case third = 3
    case fourthOrAbove = 4

    var title: String {
        switch self {
        case .first:
            return L10n.tr("First year", "一年级")
        case .second:
            return L10n.tr("Second year", "二年级")
        case .third:
            return L10n.tr("Third year", "三年级")
        case .fourthOrAbove:
            return L10n.tr("Fourth year or above", "四年级及以上")
        }
    }
}

struct CourseSummary: Identifiable, Hashable {
    let id: UUID
    let code: String
    let title: String
    let subject: CourseSubject
    let yearLevel: CourseYearLevel
    let professors: [CourseProfessorOption]
    let aggregate: CourseRatingAggregate
    let isPopular: Bool
}

enum CourseDiscoveryFilter {
    static func results(
        from courses: [CourseSummary],
        query: String,
        yearLevel: CourseYearLevel?,
        subject: CourseSubject?
    ) -> [CourseSummary] {
        let filtered = courses.filter { course in
            (yearLevel == nil || course.yearLevel == yearLevel)
                && (subject == nil || course.subject == subject)
        }

        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else {
            return rankedByReviewCount(filtered)
        }

        let compactQuery = removeWhitespace(from: normalizedQuery)
        let matches = filtered.filter { course in
            let normalizedCode = normalize(course.code)
            if normalizedCode.contains(normalizedQuery)
                || removeWhitespace(from: normalizedCode).contains(compactQuery) {
                return true
            }

            if normalize(course.title).contains(normalizedQuery) {
                return true
            }

            return course.professors.contains {
                normalize($0.name).contains(normalizedQuery)
            }
        }
        return rankedByReviewCount(matches)
    }

    private static func rankedByReviewCount(
        _ courses: [CourseSummary]
    ) -> [CourseSummary] {
        courses.sorted { lhs, rhs in
            if lhs.aggregate.reviewCount != rhs.aggregate.reviewCount {
                return lhs.aggregate.reviewCount > rhs.aggregate.reviewCount
            }
            return lhs.code < rhs.code
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func removeWhitespace(from value: String) -> String {
        value.filter { !$0.isWhitespace }
    }
}
