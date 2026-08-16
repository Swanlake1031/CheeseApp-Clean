import CoreGraphics
import XCTest
@testable import CheeseApp

final class FeedMediaLayoutEngineTests: XCTestCase {
    private let engine = FeedMediaLayoutEngine()

    func testSingleLandscapePreservesNaturalRatioWithinBounds() {
        let layout = engine.singleImageLayout(
            sourceAspectRatio: 1.6,
            availableWidth: 360
        )

        XCTAssertEqual(layout.width, 360, accuracy: 0.01)
        XCTAssertEqual(layout.height, 225, accuracy: 0.01)
        XCTAssertFalse(layout.requiresCrop)
    }

    func testSinglePortraitDoesNotBecomeGiantFullWidthPanel() {
        let layout = engine.singleImageLayout(
            sourceAspectRatio: 0.75,
            availableWidth: 360
        )

        XCTAssertEqual(layout.width, 270, accuracy: 0.01)
        XCTAssertEqual(layout.height, 360, accuracy: 0.01)
        XCTAssertFalse(layout.requiresCrop)
    }

    func testSingleSquareUsesAvailableWidth() {
        let layout = engine.singleImageLayout(
            sourceAspectRatio: 1,
            availableWidth: 360
        )

        XCTAssertEqual(layout.width, 360, accuracy: 0.01)
        XCTAssertEqual(layout.height, 360, accuracy: 0.01)
        XCTAssertFalse(layout.requiresCrop)
    }

    func testExtremeRatiosAreClampedAndCroppedAsFeedThumbnails() {
        let tall = engine.singleImageLayout(
            sourceAspectRatio: 0.2,
            availableWidth: 360
        )
        let wide = engine.singleImageLayout(
            sourceAspectRatio: 4,
            availableWidth: 360
        )

        XCTAssertEqual(tall.displayAspectRatio, 0.65, accuracy: 0.001)
        XCTAssertEqual(tall.height, 360, accuracy: 0.01)
        XCTAssertTrue(tall.requiresCrop)
        XCTAssertEqual(wide.displayAspectRatio, 1.70, accuracy: 0.001)
        XCTAssertEqual(wide.width, 360, accuracy: 0.01)
        XCTAssertTrue(wide.requiresCrop)
    }

    func testMixedMultiImageRowSharesHeightAndKeepsProportionalWidths() {
        let portrait = engine.multiImageItemLayout(sourceAspectRatio: 0.62)
        let square = engine.multiImageItemLayout(sourceAspectRatio: 1)
        let landscape = engine.multiImageItemLayout(sourceAspectRatio: 1.6)

        XCTAssertEqual(portrait.height, 190, accuracy: 0.01)
        XCTAssertEqual(square.height, portrait.height, accuracy: 0.01)
        XCTAssertEqual(landscape.height, portrait.height, accuracy: 0.01)
        XCTAssertEqual(portrait.width, 123.5, accuracy: 0.01)
        XCTAssertEqual(square.width, 190, accuracy: 0.01)
        XCTAssertEqual(landscape.width, 304, accuracy: 0.01)
    }

    func testInvalidRatioUsesStableSquareFallback() {
        let layout = engine.singleImageLayout(
            sourceAspectRatio: .nan,
            availableWidth: 360
        )

        XCTAssertEqual(layout.displayAspectRatio, 1, accuracy: 0.001)
        XCTAssertEqual(layout.width, 360, accuracy: 0.01)
        XCTAssertEqual(layout.height, 360, accuracy: 0.01)
    }
}
