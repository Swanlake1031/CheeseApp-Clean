import CoreGraphics
import XCTest
@testable import CheeseApp

final class FeedMediaLayoutEngineTests: XCTestCase {
    private let imageA = FeedMediaImageKey.remote(URL(string: "https://example.com/a.jpg")!)
    private let imageB = FeedMediaImageKey.remote(URL(string: "https://example.com/b.jpg")!)
    private let imageC = FeedMediaImageKey.remote(URL(string: "https://example.com/c.jpg")!)
    private let imageD = FeedMediaImageKey.remote(URL(string: "https://example.com/d.jpg")!)

    func testFittingMediaDoesNotCaptureOuterPageDrag() {
        XCTAssertFalse(
            FeedMediaScrollGesturePolicy.shouldCaptureHorizontalDrag(
                contentWidth: 260,
                viewportWidth: 340
            )
        )
    }

    func testOverflowingMediaCapturesDragInsideStrip() {
        XCTAssertTrue(
            FeedMediaScrollGesturePolicy.shouldCaptureHorizontalDrag(
                contentWidth: 520,
                viewportWidth: 340
            )
        )
    }

    private let engine = FeedMediaLayoutEngine()

    func testReplacementImagesDoNotInheritRatiosFromMatchingIndices() {
        let existing = [imageA: CGFloat(0.6), imageB: CGFloat(1.5)]

        let reconciled = FeedMediaAspectRatioState.reconciling(
            existing,
            currentKeys: [imageC, imageD],
            cachedRatio: { _ in nil }
        )

        XCTAssertNil(reconciled[imageC])
        XCTAssertNil(reconciled[imageD])
        XCTAssertEqual(
            engine.itemLayout(sourceAspectRatio: reconciled[imageC], metrics: .forum),
            engine.itemLayout(sourceAspectRatio: nil, metrics: .forum)
        )
    }

    func testSharedImageRetainsRatioWhileNewImageUsesFallback() {
        let existing = [imageA: CGFloat(0.6), imageB: CGFloat(1.5)]

        let reconciled = FeedMediaAspectRatioState.reconciling(
            existing,
            currentKeys: [imageB, imageC],
            cachedRatio: { _ in nil }
        )

        XCTAssertNil(reconciled[imageA])
        XCTAssertEqual(reconciled[imageB], 1.5)
        XCTAssertNil(reconciled[imageC])
    }

    func testReorderedImagesKeepRatiosBoundToImageIdentity() {
        let existing = [imageA: CGFloat(0.6), imageB: CGFloat(1.5)]

        let reconciled = FeedMediaAspectRatioState.reconciling(
            existing,
            currentKeys: [imageB, imageA],
            cachedRatio: { _ in nil }
        )

        XCTAssertEqual(reconciled[imageA], 0.6)
        XCTAssertEqual(reconciled[imageB], 1.5)
    }

    func testFailedReplacementImageDoesNotInheritPriorIndexRatio() {
        let existing = [imageA: CGFloat(0.6)]

        let reconciled = FeedMediaAspectRatioState.reconciling(
            existing,
            currentKeys: [imageC],
            cachedRatio: { _ in nil }
        )

        XCTAssertNil(reconciled[imageC])
        XCTAssertEqual(
            engine.itemLayout(sourceAspectRatio: reconciled[imageC], metrics: .forum),
            engine.itemLayout(sourceAspectRatio: nil, metrics: .forum)
        )
    }

    func testSharedPresentationAndHostMetricsAreExplicit() {
        XCTAssertEqual(FeedMediaStyle.cornerRadius, 12, accuracy: 0.001)
        XCTAssertEqual(FeedMediaStyle.itemSpacing, 7, accuracy: 0.001)
        XCTAssertEqual(FeedMediaStyle.contentInset, 0, accuracy: 0.001)
        XCTAssertEqual(FeedMediaStyle.minimumMediaWidth, 100, accuracy: 0.001)
        XCTAssertEqual(FeedMediaStyle.horizontalPlacement, .leading)
        XCTAssertEqual(FeedMediaStyle.placeholderStyle, .neutralGray)
        XCTAssertEqual(FeedMediaMetrics.forum.mediaHeight, 190, accuracy: 0.001)
        XCTAssertEqual(FeedMediaMetrics.secondhand.mediaHeight, 210, accuracy: 0.001)
    }

    func testThreeByTwoLandscapePreservesCompleteSourceRatio() {
        let layout = forumLayout(width: 1_200, height: 800)

        XCTAssertEqual(layout.width, 285, accuracy: 0.001)
        XCTAssertEqual(layout.height, 190, accuracy: 0.001)
        XCTAssertEqual(layout.renderMode, .fit)
    }

    func testFourByThreeLandscapePreservesCompleteSourceRatio() {
        let layout = forumLayout(width: 1_200, height: 900)

        XCTAssertEqual(layout.width, 253.333, accuracy: 0.001)
        XCTAssertEqual(layout.height, 190, accuracy: 0.001)
        XCTAssertEqual(layout.renderMode, .fit)
    }

    func testSquarePreservesCompleteSourceRatio() {
        let layout = forumLayout(width: 1_000, height: 1_000)

        XCTAssertEqual(layout.width, 190, accuracy: 0.001)
        XCTAssertEqual(layout.height, 190, accuracy: 0.001)
        XCTAssertEqual(layout.renderMode, .fit)
    }

    func testTwoByThreePortraitPreservesCompleteSourceRatio() {
        let layout = forumLayout(width: 800, height: 1_200)

        XCTAssertEqual(layout.width, 126.667, accuracy: 0.001)
        XCTAssertEqual(layout.height, 190, accuracy: 0.001)
        XCTAssertEqual(layout.renderMode, .fit)
    }

    func testNineBySixteenPortraitStaysAboveMinimumAndDoesNotCrop() {
        let layout = forumLayout(width: 900, height: 1_600)

        XCTAssertEqual(layout.width, 106.875, accuracy: 0.001)
        XCTAssertEqual(layout.height, 190, accuracy: 0.001)
        XCTAssertEqual(layout.renderMode, .fit)
    }

    func testExtremelyTallMediaUsesOnlyCenteredVerticalCropException() {
        let layout = forumLayout(width: 500, height: 2_000)

        XCTAssertEqual(layout.width, 100, accuracy: 0.001)
        XCTAssertEqual(layout.height, 190, accuracy: 0.001)
        XCTAssertEqual(
            layout.renderMode,
            .centerVerticalCrop(sourceAspectRatio: 0.25)
        )
    }

    func testUltraWideMediaKeepsFullHorizontalWidth() {
        let layout = forumLayout(width: 3_000, height: 600)

        XCTAssertEqual(layout.width, 950, accuracy: 0.001)
        XCTAssertEqual(layout.height, 190, accuracy: 0.001)
        XCTAssertEqual(layout.renderMode, .fit)
    }

    func testMixedMediaSharesHeightAndUsesIndependentNaturalWidths() {
        let portrait = forumLayout(width: 2, height: 3)
        let square = forumLayout(width: 1, height: 1)
        let landscape = forumLayout(width: 8, height: 5)

        XCTAssertEqual(portrait.height, 190, accuracy: 0.001)
        XCTAssertEqual(square.height, 190, accuracy: 0.001)
        XCTAssertEqual(landscape.height, 190, accuracy: 0.001)
        XCTAssertEqual(portrait.width, 126.667, accuracy: 0.001)
        XCTAssertEqual(square.width, 190, accuracy: 0.001)
        XCTAssertEqual(landscape.width, 304, accuracy: 0.001)
    }

    func testSingleAndMultiRequestsUseTheSameLayoutCalculation() {
        let single = engine.itemLayout(
            sourceAspectRatio: 0.75,
            metrics: .forum
        )
        let multi = engine.itemLayout(
            sourceAspectRatio: 0.75,
            metrics: .forum
        )

        XCTAssertEqual(single, multi)
        XCTAssertEqual(single.width, 142.5, accuracy: 0.001)
        XCTAssertEqual(single.renderMode, .fit)
    }

    func testSecondhandUsesTheSameAlgorithmWithItsOwnHeight() {
        let landscape = engine.itemLayout(
            sourceWidth: 1_200,
            sourceHeight: 800,
            metrics: .secondhand
        )
        let extremelyTall = engine.itemLayout(
            sourceWidth: 500,
            sourceHeight: 2_000,
            metrics: .secondhand
        )

        XCTAssertEqual(landscape.width, 315, accuracy: 0.001)
        XCTAssertEqual(landscape.height, 210, accuracy: 0.001)
        XCTAssertEqual(landscape.renderMode, .fit)
        XCTAssertEqual(extremelyTall.width, 100, accuracy: 0.001)
        XCTAssertEqual(extremelyTall.height, 210, accuracy: 0.001)
        XCTAssertEqual(
            extremelyTall.renderMode,
            .centerVerticalCrop(sourceAspectRatio: 0.25)
        )
    }

    func testMissingOrInvalidDimensionsUseSquareMetadataFallback() {
        let missing = engine.itemLayout(
            sourceAspectRatio: nil,
            metrics: .forum
        )
        let invalid = engine.itemLayout(
            sourceWidth: 0,
            sourceHeight: .nan,
            metrics: .forum
        )

        XCTAssertEqual(missing.width, 190, accuracy: 0.001)
        XCTAssertEqual(missing.height, 190, accuracy: 0.001)
        XCTAssertEqual(missing.renderMode, .fit)
        XCTAssertEqual(invalid, missing)
    }

    private func forumLayout(
        width: CGFloat,
        height: CGFloat
    ) -> FeedMediaItemLayout {
        engine.itemLayout(
            sourceWidth: width,
            sourceHeight: height,
            metrics: .forum
        )
    }
}
