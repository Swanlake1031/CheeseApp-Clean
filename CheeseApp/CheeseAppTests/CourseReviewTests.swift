import XCTest
@testable import CheeseApp

final class CourseReviewTests: XCTestCase {
    func testValidatedInputTrimsReviewText() throws {
        let professorID = UUID()
        let academicTermID = UUID()
        var draft = completeDraft(professorID: professorID)
        draft.academicTermID = academicTermID
        draft.reviewText = "  Clear explanations.  \n"

        let input = try draft.validatedInput()

        XCTAssertEqual(input.professorID, professorID)
        XCTAssertEqual(input.academicTermID, academicTermID)
        XCTAssertEqual(input.reviewText, "Clear explanations.")
    }

    func testValidatedInputStoresWhitespaceOnlyTextAsNil() throws {
        var draft = completeDraft(professorID: UUID())
        draft.reviewText = " \n "

        XCTAssertNil(try draft.validatedInput().reviewText)
    }

    func testDraftRequiresTermProfessorAndAllRatings() {
        var draft = CourseReviewDraft()
        draft.overallRating = 5
        draft.funRating = 3
        draft.usefulRating = 4
        draft.easyARating = 2
        draft.professorRating = 4

        XCTAssertFalse(draft.canSubmit)
        XCTAssertThrowsError(try draft.validatedInput())
    }

    func testDraftRejectsMissingAcademicTerm() {
        var draft = completeDraft(professorID: UUID())
        draft.academicTermID = nil

        XCTAssertFalse(draft.canSubmit)
        XCTAssertThrowsError(try draft.validatedInput())
    }

    func testDraftRejectsAnyMissingRatingDimension() {
        var draft = completeDraft(professorID: UUID())
        draft.easyARating = 0

        XCTAssertFalse(draft.canSubmit)
        XCTAssertThrowsError(try draft.validatedInput())
    }

    func testDraftRejectsTextOverFiveHundredCharacters() {
        var draft = completeDraft(professorID: UUID())
        draft.reviewText = String(repeating: "a", count: 501)

        XCTAssertFalse(draft.canSubmit)
        XCTAssertEqual(draft.remainingTextCount, -1)
    }

    private func completeDraft(professorID: UUID) -> CourseReviewDraft {
        var draft = CourseReviewDraft()
        draft.professorID = professorID
        draft.academicTermID = UUID()
        draft.overallRating = 4
        draft.funRating = 4
        draft.usefulRating = 3
        draft.easyARating = 4
        draft.professorRating = 5
        return draft
    }

    private func academicTerm() -> CourseAcademicTermOption {
        CourseAcademicTermOption(
            id: UUID(),
            academicYear: 2026,
            term: .winter
        )
    }
}
