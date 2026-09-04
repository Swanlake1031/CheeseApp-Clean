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

    func testExternalWebOutlineUsesOfficialPageLabel() {
        let outline = CourseOutline(
            id: UUID(),
            courseID: UUID(),
            academicYear: 2026,
            term: .fall,
            professorName: nil,
            title: "Simple Syllabus Outline",
            sourceKind: .externalWeb,
            sourceURL: URL(string: "https://mcmaster.simplesyllabusca.com/doc/example"),
            sourcePageURL: nil,
            sourceName: "mcmaster_simple_syllabus",
            storagePath: nil,
            originalFilename: nil,
            mimeType: "text/html",
            fileSizeBytes: nil,
            sha256: nil,
            createdAt: Date()
        )

        XCTAssertTrue(outline.isWebDocument)
        XCTAssertFalse(outline.formattedFileSize.isEmpty)
        XCTAssertNotNil(CourseOutlineService.shared.validatedWebURL(for: outline))
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
            sourceKind: .privateStorage,
            sourceURL: nil,
            sourcePageURL: nil,
            sourceName: "supabase_storage",
            storagePath: "course-id/file.pdf",
            originalFilename: "outline.pdf",
            mimeType: "application/pdf",
            fileSizeBytes: fileSizeBytes,
            sha256: String(repeating: "a", count: 64),
            createdAt: Date()
        )
    }
}
