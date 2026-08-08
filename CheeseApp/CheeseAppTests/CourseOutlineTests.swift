import XCTest
@testable import CheeseApp

final class CourseOutlineTests: XCTestCase {
    func testTermTitleIncludesYearAndLocalizedTerm() {
        let outline = makeOutline(
            academicYear: 2025,
            term: .fall,
            fileSizeBytes: 1_024
        )

        XCTAssertTrue(outline.termTitle.contains("2025"))
        XCTAssertFalse(outline.termTitle.isEmpty)
    }

    func testFormattedFileSizeIsNotEmpty() {
        let outline = makeOutline(
            academicYear: 2025,
            term: .fall,
            fileSizeBytes: 2_048
        )

        XCTAssertFalse(outline.formattedFileSize.isEmpty)
    }

    private func makeOutline(
        academicYear: Int,
        term: CourseAcademicTerm,
        fileSizeBytes: Int64
    ) -> CourseOutline {
        CourseOutline(
            id: UUID(),
            courseID: UUID(),
            academicYear: academicYear,
            term: term,
            professorName: "Professor Example",
            title: "Course Outline",
            storagePath: "course-id/file.pdf",
            originalFilename: "outline.pdf",
            mimeType: "application/pdf",
            fileSizeBytes: fileSizeBytes,
            sha256: String(repeating: "a", count: 64),
            createdAt: Date()
        )
    }
}
