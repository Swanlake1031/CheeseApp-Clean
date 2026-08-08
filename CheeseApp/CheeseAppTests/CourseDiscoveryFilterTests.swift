import XCTest
@testable import CheeseApp

@MainActor
final class CourseDiscoveryFilterTests: XCTestCase {
    func testCatalogLoadFailureIsExplicit() async {
        let viewModel = CourseDiscoveryViewModel {
            throw CourseCatalogStubError.failed
        }

        await viewModel.load()

        guard case .failed = viewModel.loadState else {
            return XCTFail("Expected catalog load to fail")
        }
        XCTAssertTrue(viewModel.courses.isEmpty)
    }

    func testCatalogRefreshReplacesStaleAggregate() async {
        var reviewCount = 0
        let viewModel = CourseDiscoveryViewModel {
            reviewCount += 1
            return [self.makeCourse(reviewCount: reviewCount)]
        }

        await viewModel.load()
        XCTAssertEqual(viewModel.courses.first?.aggregate.reviewCount, 1)

        await viewModel.load(force: true)
        XCTAssertEqual(viewModel.courses.first?.aggregate.reviewCount, 2)
        XCTAssertEqual(viewModel.courses.count, 1)
    }

    func testCourseCodeSearchIgnoresCaseAndWhitespace() {
        let results = CourseDiscoveryFilter.results(
            from: courses,
            query: "  econ1b03 ",
            yearLevel: nil,
            subject: nil
        )

        XCTAssertEqual(results.map(\.code), ["ECON 1B03"])
    }

    func testSearchMatchesTitleAndProfessor() {
        let titleResults = CourseDiscoveryFilter.results(
            from: courses,
            query: "probability",
            yearLevel: nil,
            subject: nil
        )
        let professorResults = CourseDiscoveryFilter.results(
            from: courses,
            query: "professor beta",
            yearLevel: nil,
            subject: nil
        )

        XCTAssertEqual(titleResults.map(\.code), ["STATS 2D03"])
        XCTAssertEqual(professorResults.map(\.code), ["STATS 2D03"])
    }

    func testEmptyQueryShowsAllCoursesOrderedByReviewCount() {
        let results = CourseDiscoveryFilter.results(
            from: courses,
            query: "",
            yearLevel: nil,
            subject: nil
        )

        XCTAssertEqual(
            results.map(\.code),
            ["ECON 1B03", "STATS 2D03", "MATH 1XX3"]
        )
    }

    func testYearAndSubjectFiltersApplyToSearchAndPopularResults() {
        let searchResults = CourseDiscoveryFilter.results(
            from: courses,
            query: "introduction",
            yearLevel: .second,
            subject: .stats
        )
        let popularResults = CourseDiscoveryFilter.results(
            from: courses,
            query: "",
            yearLevel: .first,
            subject: .math
        )

        XCTAssertEqual(searchResults.map(\.code), ["STATS 2D03"])
        XCTAssertEqual(popularResults.map(\.code), ["MATH 1XX3"])
    }

    func testNonmatchingFiltersReturnEmptyResults() {
        let results = CourseDiscoveryFilter.results(
            from: courses,
            query: "calculus",
            yearLevel: .second,
            subject: .stats
        )

        XCTAssertTrue(results.isEmpty)
    }

    func testCommerceCoursesUseExistingSearchAndFacultyFilters() {
        let commerceCourse = makeCourse(
            code: "COMMERCE 1DA3",
            title: "Business Data Analytics",
            subject: .commerce,
            year: .first,
            professor: "Behrouz Bakhtiari"
        )

        XCTAssertEqual(
            CourseDiscoveryFilter.results(
                from: [commerceCourse],
                query: "commerce1da3",
                yearLevel: .first,
                subject: .commerce
            ).map(\.code),
            ["COMMERCE 1DA3"]
        )
        XCTAssertEqual(
            CourseDiscoveryFilter.results(
                from: [commerceCourse],
                query: "data analytics",
                yearLevel: nil,
                subject: .commerce
            ).map(\.code),
            ["COMMERCE 1DA3"]
        )
        XCTAssertEqual(
            CourseDiscoveryFilter.results(
                from: [commerceCourse],
                query: "bakhtiari",
                yearLevel: nil,
                subject: .commerce
            ).map(\.code),
            ["COMMERCE 1DA3"]
        )
    }

    private var courses: [CourseSummary] {
        [
            makeCourse(
                code: "ECON 1B03",
                title: "Introductory Microeconomics",
                subject: .econ,
                year: .first,
                professor: "Professor Fixture",
                popular: true,
                reviewCount: 4
            ),
            makeCourse(
                code: "MATH 1XX3",
                title: "Calculus for Science I",
                subject: .math,
                year: .first,
                professor: "Professor Alpha",
                popular: true
            ),
            makeCourse(
                code: "STATS 2D03",
                title: "Introduction to Probability",
                subject: .stats,
                year: .second,
                professor: "Professor Beta",
                popular: false,
                reviewCount: 2
            )
        ]
    }

    private func makeCourse(
        code: String = "ECON 1B03",
        title: String = "Introductory Microeconomics",
        subject: CourseSubject = .econ,
        year: CourseYearLevel = .first,
        professor: String = "Professor Fixture",
        popular: Bool = true,
        reviewCount: Int = 0
    ) -> CourseSummary {
        CourseSummary(
            id: UUID(),
            code: code,
            title: title,
            subject: subject,
            yearLevel: year,
            professors: [
                CourseProfessorOption(id: UUID(), name: professor)
            ],
            aggregate: CourseRatingAggregate(
                reviewCount: reviewCount,
                overallRating: reviewCount == 0 ? nil : 4,
                funRating: nil,
                usefulRating: nil,
                easyARating: nil,
                professorRating: nil
            ),
            isPopular: popular
        )
    }
}

private enum CourseCatalogStubError: Error {
    case failed
}
