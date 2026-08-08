import XCTest
import UIKit
@testable import CheeseApp

@MainActor
final class PostCorrectnessTests: XCTestCase {
    func testPostInteractionStoreIsSharedAcrossListAndDetailFallbacks() {
        let accountID = UUID()
        let postID = UUID()
        let store = PostInteractionStore.shared
        store.activateAccount(accountID)
        defer { store.activateAccount(nil) }

        store.replace(
            postID: postID,
            with: PostInteractionState(
                likeCount: 12,
                isLiked: true,
                isFavorited: false
            )
        )

        XCTAssertEqual(
            store.state(
                for: postID,
                fallbackLikeCount: 2,
                fallbackIsLiked: false,
                fallbackIsFavorited: true
            ),
            PostInteractionState(
                likeCount: 12,
                isLiked: true,
                isFavorited: false
            )
        )

        store.setFavorite(postID: postID, isFavorited: true)
        XCTAssertTrue(store.state(for: postID).isFavorited)
        XCTAssertEqual(store.state(for: postID).likeCount, 12)
        XCTAssertTrue(store.state(for: postID).isLiked)
    }

    func testPostInteractionStoreClearsWhenAccountChanges() {
        let store = PostInteractionStore.shared
        let firstAccountID = UUID()
        let secondAccountID = UUID()
        let postID = UUID()
        defer { store.activateAccount(nil) }

        store.activateAccount(firstAccountID)
        store.replace(
            postID: postID,
            with: PostInteractionState(
                likeCount: 8,
                isLiked: true,
                isFavorited: true
            )
        )
        store.activateAccount(secondAccountID)

        XCTAssertEqual(
            store.state(
                for: postID,
                fallbackLikeCount: 3,
                fallbackIsLiked: false,
                fallbackIsFavorited: false
            ),
            PostInteractionState(
                likeCount: 3,
                isLiked: false,
                isFavorited: false
            )
        )
    }

    func testPostInteractionBatchPublishesSingleRevision() {
        let store = PostInteractionStore.shared
        let accountID = UUID()
        let firstPostID = UUID()
        let secondPostID = UUID()
        store.activateAccount(accountID)
        defer { store.activateAccount(nil) }
        let revisionBeforeMerge = store.revision

        store.merge([
            PostInteractionStore.Update(
                postID: firstPostID,
                likeCount: 3,
                isLiked: true,
                isFavorited: false
            ),
            PostInteractionStore.Update(
                postID: secondPostID,
                likeCount: 0,
                isLiked: false,
                isFavorited: true
            )
        ])

        XCTAssertEqual(store.revision, revisionBeforeMerge + 1)
        XCTAssertEqual(store.state(for: firstPostID).likeCount, 3)
        XCTAssertTrue(store.state(for: firstPostID).isLiked)
        XCTAssertTrue(store.state(for: secondPostID).isFavorited)
    }

    func testProfileOnboardingRequiresExplicitCompletionEvenWithDefaultSchool() {
        XCTAssertTrue(
            ProfileCompletionPolicy.needsCompletion(
                profileCompleted: false,
                school: "McMaster University"
            )
        )
    }

    func testProfileOnboardingAcceptsCompletedSupportedSchool() {
        XCTAssertFalse(
            ProfileCompletionPolicy.needsCompletion(
                profileCompleted: true,
                school: "McMaster University"
            )
        )
    }

    func testProfileOnboardingRejectsCompletedUnknownSchool() {
        XCTAssertTrue(
            ProfileCompletionPolicy.needsCompletion(
                profileCompleted: true,
                school: "Unknown"
            )
        )
    }

    func testSystemShareMetadataAlwaysUsesTheOfficialCheeseLogo() throws {
        XCTAssertEqual(PostShareMetadataFactory.iconAssetName, "CheeseAppLogo")

        let logo = try XCTUnwrap(PostShareMetadataFactory.appIcon())
        XCTAssertEqual(logo.renderingMode, .alwaysOriginal)

        for kind in PostKind.allCases {
            let payload = PostSharePayload(
                kind: kind,
                postId: UUID(),
                title: "Cheese share metadata test"
            )
            let metadata = PostShareMetadataFactory.make(for: payload)

            XCTAssertEqual(metadata.title, payload.previewTitle)
            XCTAssertEqual(metadata.url, payload.canonicalURL)
            XCTAssertNotNil(metadata.iconProvider)
        }
    }

    func testSharedEditableTextViewExposesNativeSelectionActions() {
        let textView = CheeseEditableTextView()
        textView.text = "Cheese App"
        textView.isEditable = true
        textView.isSelectable = true
        textView.selectedRange = NSRange(location: 0, length: 6)

        XCTAssertTrue(
            textView.canPerformAction(NSSelectorFromString("copy:"), withSender: nil)
        )
        XCTAssertTrue(
            textView.canPerformAction(NSSelectorFromString("cut:"), withSender: nil)
        )
        XCTAssertTrue(
            textView.canPerformAction(NSSelectorFromString("selectAll:"), withSender: nil)
        )
    }

    func testSharedEditableTextViewExposesPasteForTextClipboard() {
        let pasteboard = UIPasteboard.general
        let previousItems = pasteboard.items
        defer { pasteboard.items = previousItems }
        pasteboard.string = "paste me"

        let textView = CheeseEditableTextView()
        textView.isEditable = true

        XCTAssertTrue(
            textView.canPerformAction(NSSelectorFromString("paste:"), withSender: nil)
        )
    }

    func testSharedSearchTextFieldExposesNativePasteAction() {
        let pasteboard = UIPasteboard.general
        let previousItems = pasteboard.items
        defer { pasteboard.items = previousItems }
        pasteboard.string = "profile uid"

        let textField = CheeseEditableTextField()
        textField.isEnabled = true

        XCTAssertTrue(
            textField.canPerformAction(NSSelectorFromString("paste:"), withSender: nil)
        )
    }

    func testPostKindParsesCanonicalBackendValues() {
        XCTAssertNil(PostKind(remoteValue: "rent"))
        XCTAssertEqual(PostKind(remoteValue: "secondhand"), .secondhand)
        XCTAssertEqual(PostKind(remoteValue: "forum"), .forum)
    }

    func testPostKindRejectsUnknownRetiredAndAliasValues() {
        ["rent", "ride", "team", "market", "community", "merchant"].forEach {
            XCTAssertNil(PostKind(remoteValue: $0))
        }
    }

    func testSearchCategoryUsesCanonicalSecondhandValue() {
        XCTAssertEqual(SearchCategory(rawValue: "secondhand"), .secondhand)
        XCTAssertNil(SearchCategory(rawValue: "market"))
        XCTAssertEqual(SearchCategory.secondhand.searchPostsRPCValue, "market")
        XCTAssertEqual(SearchCategory(searchPostsRPCValue: "market"), .secondhand)
    }

    func testCourseRadarLinkUsesProductionURL() {
        XCTAssertEqual(
            AppExternalLinks.courseRadar.absoluteString,
            "https://radar.cheeseapp.org"
        )
    }

    func testCourseRadarDeepLinkNormalizesAndIncludesCourseCode() throws {
        let url = AppExternalLinks.courseRadar(for: "  econ   1b03 ")
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "radar.cheeseapp.org")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "course" })?.value,
            "ECON 1B03"
        )
        XCTAssertEqual(components.fragment, "courses")
    }

    func testPostKindCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for kind in PostKind.allCases {
            let data = try encoder.encode(kind)
            XCTAssertEqual(try decoder.decode(PostKind.self, from: data), kind)
        }
    }

    func testPostDeepLinkRoutesEveryActivePostKind() throws {
        let postId = UUID(uuidString: "92000000-0000-0000-0000-000000000001")!

        for kind in PostKind.allCases {
            let url = try XCTUnwrap(
                URL(string: "cheeseapp://post/\(kind.rawValue)/\(postId.uuidString)")
            )
            guard case .success(let route)? = PostDeepLinkRoute.parse(url) else {
                return XCTFail("Expected \(kind.rawValue) to produce a post route")
            }
            XCTAssertEqual(route.kind, kind)
            XCTAssertEqual(route.postId, postId)
        }
    }

    func testPostDeepLinkRejectsRetiredKind() throws {
        let postId = UUID(uuidString: "92000000-0000-0000-0000-000000000001")!
        let url = try XCTUnwrap(URL(string: "cheeseapp://post/ride/\(postId.uuidString)"))

        guard case .failure(.unsupportedKind(let rawValue))? = PostDeepLinkRoute.parse(url) else {
            return XCTFail("Expected retired post kind to be rejected")
        }
        XCTAssertEqual(rawValue, "ride")
    }

    func testSecondhandDetailPayloadPreservesCanonicalSelectedCategory() {
        let input = makeSecondhandInput(category: .booksAcademic)

        let payload = SecondhandService.makeDetailInsert(input: input)

        XCTAssertEqual(payload.category, SecondhandPost.Category.booksAcademic.rawValue)
    }

    func testSecondhandCreateInputDoesNotReplaceSelectedCategoryWithOther() {
        let input = makeSecondhandInput(category: .homeAppliances)

        XCTAssertEqual(input.category, .homeAppliances)
        XCTAssertNotEqual(input.category, .other)
    }

    func testSecondhandUnknownCategoryUsesExplicitOtherFallback() {
        XCTAssertEqual(SecondhandPost.Category(normalizing: "retired-category"), .other)
    }

    func testSecondhandCategoriesMatchMarketplaceOrderAndLegacyAcademicAliases() {
        XCTAssertEqual(
            SecondhandPost.Category.allCases,
            [
                .homeAppliances,
                .dailyEssentials,
                .fashionAccessories,
                .beautyCare,
                .sportsOutdoors,
                .digitalElectronics,
                .booksAcademic,
                .petSupplies,
                .other
            ]
        )
        XCTAssertEqual(SecondhandPost.Category(normalizing: "furniture"), .homeAppliances)
        XCTAssertEqual(SecondhandPost.Category(normalizing: "appliances"), .homeAppliances)
        XCTAssertEqual(SecondhandPost.Category(normalizing: "books"), .booksAcademic)
        XCTAssertEqual(SecondhandPost.Category(normalizing: "textbooks"), .booksAcademic)
    }

    func testSecondhandConditionAndStatusMappingAreStable() {
        XCTAssertEqual(SecondhandPost.Condition(normalizing: "LIKE_NEW"), .likeNew)
        XCTAssertEqual(
            SecondhandService.makeDetailUpdate(
                price: 20,
                details: SecondhandEditableFields(condition: "LIKE_NEW", isNegotiable: false)
            ).condition,
            SecondhandPost.Condition.likeNew.rawValue
        )
        XCTAssertFalse(SecondhandService.isSold(quantity: 2, soldCount: 1))
        XCTAssertTrue(SecondhandService.isSold(quantity: 2, soldCount: 2))
    }

    func testSecondhandCreateFormDefaultsToFixedPrice() {
        XCTAssertFalse(SecondhandCreateFormRules.defaultIsNegotiable)
        XCTAssertEqual(SecondhandCreateFormRules.defaultCondition, SecondhandPost.Condition.good.rawValue)
        XCTAssertEqual(SecondhandCreateFormRules.defaultCategory, .homeAppliances)
    }

    func testSecondhandCreateFormRejectsInvalidPricesAndTrimsRequiredText() {
        XCTAssertEqual(SecondhandCreateFormRules.normalizedRequiredText("  Desk lamp\n"), "Desk lamp")
        XCTAssertEqual(SecondhandCreateFormRules.validPrice(from: " 18.50 "), 18.5)
        XCTAssertNil(SecondhandCreateFormRules.validPrice(from: ""))
        XCTAssertNil(SecondhandCreateFormRules.validPrice(from: "-1"))
        XCTAssertNil(SecondhandCreateFormRules.validPrice(from: "nan"))
        XCTAssertNil(SecondhandCreateFormRules.validPrice(from: "inf"))
    }

    func testSecondhandCreateFormRequiresAtLeastOneImage() {
        XCTAssertFalse(SecondhandCreateFormRules.isValid(title: "Desk", price: "20", imageCount: 0))
        XCTAssertTrue(SecondhandCreateFormRules.isValid(title: "Desk", price: "20", imageCount: 1))
    }

    func testSwipeBackGestureOnlyBeginsForSafeRightwardNavigation() {
        XCTAssertTrue(SwipeBackGesturePolicy.shouldBegin(
            viewControllerCount: 2,
            isTransitioning: false,
            velocity: CGPoint(x: 240, y: 20)
        ))
        XCTAssertFalse(SwipeBackGesturePolicy.shouldBegin(
            viewControllerCount: 1,
            isTransitioning: false,
            velocity: CGPoint(x: 240, y: 20)
        ))
        XCTAssertFalse(SwipeBackGesturePolicy.shouldBegin(
            viewControllerCount: 2,
            isTransitioning: true,
            velocity: CGPoint(x: 240, y: 20)
        ))
        XCTAssertFalse(SwipeBackGesturePolicy.shouldBegin(
            viewControllerCount: 2,
            isTransitioning: false,
            velocity: CGPoint(x: 20, y: 240)
        ))
        XCTAssertFalse(SwipeBackGesturePolicy.shouldBegin(
            viewControllerCount: 2,
            isTransitioning: false,
            velocity: CGPoint(x: -180, y: 20)
        ))
    }

    func testSwipeBackAllowsNaturalDiagonalEdgeMovement() {
        XCTAssertTrue(SwipeBackGesturePolicy.shouldBegin(
            viewControllerCount: 2,
            isTransitioning: false,
            velocity: .zero,
            translation: CGPoint(x: 8, y: 12)
        ))
        XCTAssertTrue(SwipeBackGesturePolicy.shouldBegin(
            viewControllerCount: 2,
            isTransitioning: false,
            velocity: CGPoint(x: 20, y: 400),
            translation: CGPoint(x: 14, y: -18)
        ))
        XCTAssertFalse(SwipeBackGesturePolicy.shouldBegin(
            viewControllerCount: 2,
            isTransitioning: false,
            velocity: .zero,
            translation: CGPoint(x: 6, y: 30)
        ))
    }

    func testSwipeBackInterceptsOnlyWhenThereAreUnsavedChanges() {
        XCTAssertTrue(SwipeBackGesturePolicy.shouldIntercept(
            viewControllerCount: 2,
            isTransitioning: false,
            hasUnsavedChanges: true
        ))
        XCTAssertFalse(SwipeBackGesturePolicy.shouldIntercept(
            viewControllerCount: 2,
            isTransitioning: false,
            hasUnsavedChanges: false
        ))
        XCTAssertFalse(SwipeBackGesturePolicy.shouldIntercept(
            viewControllerCount: 1,
            isTransitioning: false,
            hasUnsavedChanges: true
        ))
        XCTAssertFalse(SwipeBackGesturePolicy.shouldIntercept(
            viewControllerCount: 2,
            isTransitioning: true,
            hasUnsavedChanges: true
        ))
    }

    func testImagePreviewDismissalUsesTheSameOmnidirectionalThreshold() {
        XCTAssertTrue(ImagePreviewDismissalPolicy.shouldDismiss(
            translation: CGSize(width: 136, height: 0),
            predictedEndTranslation: .zero
        ))
        XCTAssertTrue(ImagePreviewDismissalPolicy.shouldDismiss(
            translation: CGSize(width: 0, height: -136),
            predictedEndTranslation: .zero
        ))
        XCTAssertTrue(ImagePreviewDismissalPolicy.shouldDismiss(
            translation: CGSize(width: 70, height: 70),
            predictedEndTranslation: CGSize(width: 180, height: 150)
        ))
        XCTAssertFalse(ImagePreviewDismissalPolicy.shouldDismiss(
            translation: CGSize(width: 80, height: 80),
            predictedEndTranslation: CGSize(width: 150, height: 150)
        ))
    }

    func testSwipeBackDoesNotRunSimultaneouslyWithScrollViewPan() {
        XCTAssertFalse(SwipeBackGesturePolicy.shouldRecognizeSimultaneously(
            isInteractivePopGesture: true,
            isOtherPanGesture: true
        ))
        XCTAssertTrue(SwipeBackGesturePolicy.shouldRecognizeSimultaneously(
            isInteractivePopGesture: true,
            isOtherPanGesture: false
        ))
        XCTAssertFalse(SwipeBackGesturePolicy.shouldRecognizeSimultaneously(
            isInteractivePopGesture: false,
            isOtherPanGesture: false
        ))
    }

    func testInteractivePopTakesPriorityOverPagingScrollViewPan() {
        XCTAssertTrue(SwipeBackGesturePolicy.shouldPrioritizeInteractivePop(
            isInteractivePopGesture: true,
            isOtherPanGesture: true
        ))
        XCTAssertFalse(SwipeBackGesturePolicy.shouldPrioritizeInteractivePop(
            isInteractivePopGesture: false,
            isOtherPanGesture: true
        ))
        XCTAssertFalse(SwipeBackGesturePolicy.shouldPrioritizeInteractivePop(
            isInteractivePopGesture: true,
            isOtherPanGesture: false
        ))
    }

    func testSecondhandEditPayloadDoesNotOverwriteCategoryOrStatus() throws {
        let payload = SecondhandService.makeDetailUpdate(
            price: 20,
            details: SecondhandEditableFields(condition: "good", isNegotiable: true)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )

        XCTAssertNil(object["category"])
        XCTAssertNil(object["status"])
        XCTAssertNil(object["quantity"])
        XCTAssertNil(object["sold_count"])
    }

    func testAnonymousForumMappingKeepsPostContentVisible() {
        let source = makeForumPost(isAnonymous: true)

        let item = ForumService.makePostItem(source, reaction: nil)

        XCTAssertEqual(item.id, source.id)
        XCTAssertEqual(item.title, source.title)
        XCTAssertEqual(item.content, source.description)
    }

    func testAnonymousForumMappingHidesAuthorNameAndAvatar() {
        let source = makeForumPost(isAnonymous: true)

        let item = ForumService.makePostItem(source, reaction: nil)

        XCTAssertEqual(item.authorName, L10n.tr("Anonymous", "匿名"))
        XCTAssertNil(item.authorAvatar)
        XCTAssertFalse(item.isAuthorOfficial)
    }

    func testTrustedOfficialForumFieldDisplaysOfficialIdentity() {
        let source = makeForumPost(isAnonymous: false, isOfficial: true)

        let item = ForumService.makePostItem(source, reaction: nil)

        XCTAssertTrue(item.isAuthorOfficial)
    }

    func testOrdinaryForumAuthorIsNotOfficial() {
        let source = makeForumPost(isAnonymous: false, isOfficial: false)

        let item = ForumService.makePostItem(source, reaction: nil)

        XCTAssertFalse(item.isAuthorOfficial)
    }

    func testAnonymousPostNeverExposesOfficialIdentity() {
        let source = makeForumPost(isAnonymous: true, isOfficial: true)

        let item = ForumService.makePostItem(source, reaction: nil)

        XCTAssertFalse(item.isAuthorOfficial)
    }

    func testForumBoardDecodesBackendOwnedPermissionsAndAnonymousPolicy() throws {
        let data = Data(
            """
            {
              "id":"f0000000-0000-0000-0000-000000000005",
              "slug":"tree-hole",
              "name":"树洞",
              "description":"倾诉与情绪表达",
              "rules":"保护隐私",
              "icon":"moon.stars.fill",
              "cover_image_url":null,
              "school_id":null,
              "is_official":true,
              "allows_anonymous_posts":true,
              "status":"active",
              "created_by":null,
              "created_at":0,
              "updated_at":0,
              "member_count":42,
              "is_joined":true,
              "viewer_role":"moderator",
              "can_manage":true,
              "can_administer":false
            }
            """.utf8
        )

        let board = try JSONDecoder().decode(ForumBoard.self, from: data)

        XCTAssertEqual(board.slug, "tree-hole")
        XCTAssertTrue(board.allowsAnonymousPosts)
        XCTAssertEqual(board.viewerRole, .moderator)
        XCTAssertTrue(board.canManage)
        XCTAssertFalse(board.canAdminister)
    }

    func testCanonicalAnonymousBoardRequiresAnonymousPosts() throws {
        let data = Data(
            """
            {
              "id":"f0000000-0000-0000-0000-000000000005",
              "slug":"anonymous",
              "name":"匿名",
              "description":"匿名交流",
              "rules":"匿名不代表免责",
              "icon":"theatermasks.fill",
              "cover_image_url":null,
              "school_id":null,
              "is_official":true,
              "allows_anonymous_posts":true,
              "status":"active",
              "created_by":null,
              "created_at":0,
              "updated_at":0,
              "member_count":0,
              "is_joined":false,
              "viewer_role":null,
              "can_manage":false,
              "can_administer":false
            }
            """.utf8
        )

        let board = try JSONDecoder().decode(ForumBoard.self, from: data)

        XCTAssertTrue(board.requiresAnonymousPosts)
    }

    func testAggregateForumFeedBreaksUpThreePostsFromTheSameBoardWhenPossible() {
        let academics = UUID(uuidString: "f0000000-0000-0000-0000-000000000002")!
        let sports = UUID(uuidString: "f0000000-0000-0000-0000-000000000003")!
        let input = [academics, academics, academics, sports].map(makeForumItem)

        let spread = ForumService.spreadingBoards(in: input)

        XCTAssertEqual(Set(spread.map(\.id)), Set(input.map(\.id)))
        XCTAssertEqual(spread.map(\.boardID), [academics, academics, sports, academics])
    }

    func testSecondhandCreateErrorHidesBackendDiagnostics() {
        let diagnostic = NSError(
            domain: "PostgREST",
            code: 42501,
            userInfo: [NSLocalizedDescriptionKey: "permission denied for table secondhand_posts"]
        )

        let message = SecondhandCreatePostError.userFacingMessage(for: diagnostic)

        XCTAssertEqual(message, SecondhandCreatePostError.userFacingMessage)
        XCTAssertFalse(message.localizedCaseInsensitiveContains("secondhand_posts"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("permission denied"))
    }

    func testForumRollbackErrorHidesBothBackendDiagnostics() {
        let detailError = NSError(
            domain: "PostgREST",
            code: 23514,
            userInfo: [NSLocalizedDescriptionKey: "forum_posts board constraint failed"]
        )
        let rollbackError = NSError(
            domain: "PostgREST",
            code: 42501,
            userInfo: [NSLocalizedDescriptionKey: "permission denied deleting from posts"]
        )
        let error = ForumCreatePostError.detailInsertFailedRollbackFailed(
            detailError: detailError,
            rollbackError: rollbackError
        )

        let message = ForumCreatePostError.userFacingMessage(for: error)

        XCTAssertEqual(message, ForumCreatePostError.userFacingMessage)
        XCTAssertFalse(message.localizedCaseInsensitiveContains("forum_posts"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("permission denied"))
    }

    func testForumPublishCompensatesEveryPlannedPathAfterFailureAtEachImageIndex() async {
        let fixture = makeForumPublishingFixture(imageCount: 3)

        for failedIndex in fixture.plans.indices {
            var publishedChecks = 0
            var preparedPlans: [PostImageUploadPlan] = []
            var uploadedIndexes: [Int] = []
            var markedIndexes: [Int] = []
            var deletedPaths: [String] = []
            var cleanupResults: [Bool] = []
            var finalizeCount = 0

            let workflow = ForumPublishingWorkflow(
                operations: ForumPublishingOperations(
                    isAlreadyPublished: { _ in
                        publishedChecks += 1
                        return false
                    },
                    prepare: { _, _, plans in
                        preparedPlans = plans
                    },
                    upload: { _, plan in
                        uploadedIndexes.append(plan.orderIndex)
                        if plan.orderIndex == failedIndex {
                            throw TestPublishingError.injected("upload-\(failedIndex)")
                        }
                        return plan.uploadedAsset
                    },
                    markUploaded: { _, orderIndex in
                        markedIndexes.append(orderIndex)
                    },
                    finalize: { input, _ in
                        finalizeCount += 1
                        return input.postId
                    },
                    abandon: { _, _ in
                        fixture.cleanupItems
                    },
                    deleteObject: { asset in
                        deletedPaths.append(asset.path)
                    },
                    markCleanup: { _, succeeded, _ in
                        cleanupResults.append(succeeded)
                    }
                )
            )

            do {
                _ = try await workflow.publish(
                    input: fixture.input,
                    images: fixture.images,
                    plans: fixture.plans
                )
                XCTFail("Expected injected upload failure at image \(failedIndex)")
            } catch {
                XCTAssertEqual(
                    (error as? TestPublishingError),
                    .injected("upload-\(failedIndex)")
                )
            }

            XCTAssertEqual(preparedPlans, fixture.plans)
            XCTAssertEqual(uploadedIndexes, Array(0...failedIndex))
            XCTAssertEqual(markedIndexes, Array(0..<failedIndex))
            XCTAssertEqual(finalizeCount, 0)
            XCTAssertEqual(publishedChecks, 2)
            XCTAssertEqual(Set(deletedPaths), Set(fixture.plans.map(\.objectPath)))
            XCTAssertEqual(cleanupResults, [Bool](repeating: true, count: 3))
        }
    }

    func testForumPublishCompensatesAfterTransactionalFinalizationFailure() async {
        let fixture = makeForumPublishingFixture(imageCount: 3)
        var uploadedIndexes: [Int] = []
        var markedIndexes: [Int] = []
        var deletedPaths: [String] = []

        let workflow = ForumPublishingWorkflow(
            operations: ForumPublishingOperations(
                isAlreadyPublished: { _ in false },
                prepare: { _, _, _ in },
                upload: { _, plan in
                    uploadedIndexes.append(plan.orderIndex)
                    return plan.uploadedAsset
                },
                markUploaded: { _, orderIndex in
                    markedIndexes.append(orderIndex)
                },
                finalize: { _, _ in
                    throw TestPublishingError.injected("finalize")
                },
                abandon: { _, _ in fixture.cleanupItems },
                deleteObject: { asset in
                    deletedPaths.append(asset.path)
                },
                markCleanup: { _, _, _ in }
            )
        )

        do {
            _ = try await workflow.publish(
                input: fixture.input,
                images: fixture.images,
                plans: fixture.plans
            )
            XCTFail("Expected transactional finalization failure")
        } catch {
            XCTAssertEqual(error as? TestPublishingError, .injected("finalize"))
        }

        XCTAssertEqual(uploadedIndexes, [0, 1, 2])
        XCTAssertEqual(markedIndexes, [0, 1, 2])
        XCTAssertEqual(Set(deletedPaths), Set(fixture.plans.map(\.objectPath)))
    }

    func testForumPublishRetryReturnsExistingPostWithoutRepeatingSideEffects() async throws {
        let fixture = makeForumPublishingFixture(imageCount: 2)
        var prepareCount = 0
        var uploadCount = 0
        var finalizeCount = 0
        var cleanupCount = 0

        let workflow = ForumPublishingWorkflow(
            operations: ForumPublishingOperations(
                isAlreadyPublished: { postID in
                    XCTAssertEqual(postID, fixture.input.postId)
                    return true
                },
                prepare: { _, _, _ in prepareCount += 1 },
                upload: { _, plan in
                    uploadCount += 1
                    return plan.uploadedAsset
                },
                markUploaded: { _, _ in },
                finalize: { input, _ in
                    finalizeCount += 1
                    return input.postId
                },
                abandon: { _, _ in
                    cleanupCount += 1
                    return []
                },
                deleteObject: { _ in cleanupCount += 1 },
                markCleanup: { _, _, _ in }
            )
        )

        let publishedID = try await workflow.publish(
            input: fixture.input,
            images: fixture.images,
            plans: fixture.plans
        )

        XCTAssertEqual(publishedID, fixture.input.postId)
        XCTAssertEqual(prepareCount, 0)
        XCTAssertEqual(uploadCount, 0)
        XCTAssertEqual(finalizeCount, 0)
        XCTAssertEqual(cleanupCount, 0)
    }

    func testForumPublishTreatsLostFinalizeResponseAsIdempotentSuccess() async throws {
        let fixture = makeForumPublishingFixture(imageCount: 2)
        var publishedChecks = 0
        var cleanupCount = 0

        let workflow = ForumPublishingWorkflow(
            operations: ForumPublishingOperations(
                isAlreadyPublished: { _ in
                    defer { publishedChecks += 1 }
                    return publishedChecks == 1
                },
                prepare: { _, _, _ in },
                upload: { _, plan in plan.uploadedAsset },
                markUploaded: { _, _ in },
                finalize: { _, _ in
                    throw TestPublishingError.injected("lost-response")
                },
                abandon: { _, _ in
                    cleanupCount += 1
                    return []
                },
                deleteObject: { _ in cleanupCount += 1 },
                markCleanup: { _, _, _ in }
            )
        )

        let publishedID = try await workflow.publish(
            input: fixture.input,
            images: fixture.images,
            plans: fixture.plans
        )

        XCTAssertEqual(publishedID, fixture.input.postId)
        XCTAssertEqual(publishedChecks, 2)
        XCTAssertEqual(cleanupCount, 0)
    }

    func testForumPublishLeavesExactStagingRecordWhenCommitOutcomeCannotBeRead() async {
        let fixture = makeForumPublishingFixture(imageCount: 1)
        var publishedChecks = 0
        var abandonCount = 0
        var deleteCount = 0

        let workflow = ForumPublishingWorkflow(
            operations: ForumPublishingOperations(
                isAlreadyPublished: { _ in
                    defer { publishedChecks += 1 }
                    if publishedChecks == 1 {
                        throw TestPublishingError.injected("status")
                    }
                    return false
                },
                prepare: { _, _, _ in },
                upload: { _, plan in plan.uploadedAsset },
                markUploaded: { _, _ in },
                finalize: { _, _ in
                    throw TestPublishingError.injected("finalize")
                },
                abandon: { _, _ in
                    abandonCount += 1
                    return fixture.cleanupItems
                },
                deleteObject: { _ in deleteCount += 1 },
                markCleanup: { _, _, _ in }
            )
        )

        do {
            _ = try await workflow.publish(
                input: fixture.input,
                images: fixture.images,
                plans: fixture.plans
            )
            XCTFail("Expected unknown publication outcome")
        } catch ForumCreatePostError.publicationOutcomeUnknown(let originalError) {
            XCTAssertEqual(
                originalError as? TestPublishingError,
                .injected("finalize")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(publishedChecks, 2)
        XCTAssertEqual(abandonCount, 0)
        XCTAssertEqual(deleteCount, 0)
    }

    func testForumCleanupFailureRemainsObservableAndRetryable() async {
        let fixture = makeForumPublishingFixture(imageCount: 2)
        var cleanupAttempts: [(UUID, Bool, String?)] = []

        let workflow = ForumPublishingWorkflow(
            operations: ForumPublishingOperations(
                isAlreadyPublished: { _ in false },
                prepare: { _, _, _ in },
                upload: { _, plan in
                    if plan.orderIndex == 1 {
                        throw TestPublishingError.injected("upload")
                    }
                    return plan.uploadedAsset
                },
                markUploaded: { _, _ in },
                finalize: { input, _ in input.postId },
                abandon: { _, _ in fixture.cleanupItems },
                deleteObject: { asset in
                    if asset.path == fixture.plans[0].objectPath {
                        throw NSError(domain: "Storage transient", code: 503)
                    }
                },
                markCleanup: { cleanupID, succeeded, errorCode in
                    cleanupAttempts.append((cleanupID, succeeded, errorCode))
                }
            )
        )

        do {
            _ = try await workflow.publish(
                input: fixture.input,
                images: fixture.images,
                plans: fixture.plans
            )
            XCTFail("Expected upload failure")
        } catch {
            XCTAssertEqual(error as? TestPublishingError, .injected("upload"))
        }

        XCTAssertEqual(cleanupAttempts.count, 2)
        XCTAssertFalse(cleanupAttempts[0].1)
        XCTAssertEqual(cleanupAttempts[0].2, "Storage_transient:503")
        XCTAssertTrue(cleanupAttempts[1].1)
        XCTAssertNil(cleanupAttempts[1].2)
    }

    func testSecondhandPublishCompensatesEveryPlannedPathAfterFailureAtEachImageIndex() async {
        let fixture = makeSecondhandPublishingFixture(imageCount: 3)

        for failedIndex in fixture.plans.indices {
            var uploadedIndexes: [Int] = []
            var markedIndexes: [Int] = []
            var deletedPaths: [String] = []
            var cleanupResults: [Bool] = []
            var finalizeCount = 0

            let workflow = SecondhandPublishingWorkflow(
                operations: SecondhandPublishingOperations(
                    isAlreadyPublished: { _ in false },
                    prepare: { operationID, postID, plans in
                        XCTAssertEqual(operationID, fixture.input.postId)
                        XCTAssertEqual(postID, fixture.input.postId)
                        XCTAssertEqual(plans, fixture.plans)
                    },
                    upload: { _, plan in
                        uploadedIndexes.append(plan.orderIndex)
                        if plan.orderIndex == failedIndex {
                            throw TestPublishingError.injected("secondhand-upload-\(failedIndex)")
                        }
                        return plan.uploadedAsset
                    },
                    markUploaded: { _, index in markedIndexes.append(index) },
                    finalize: { input, _ in
                        finalizeCount += 1
                        return input.postId
                    },
                    abandon: { _, _ in fixture.cleanupItems },
                    deleteObject: { asset in deletedPaths.append(asset.path) },
                    markCleanup: { _, succeeded, _ in cleanupResults.append(succeeded) }
                )
            )

            do {
                _ = try await workflow.publish(
                    input: fixture.input,
                    images: fixture.images,
                    plans: fixture.plans
                )
                XCTFail("Expected injected upload failure at image \(failedIndex)")
            } catch {
                XCTAssertEqual(
                    error as? TestPublishingError,
                    .injected("secondhand-upload-\(failedIndex)")
                )
            }

            XCTAssertEqual(uploadedIndexes, Array(0...failedIndex))
            XCTAssertEqual(markedIndexes, Array(0..<failedIndex))
            XCTAssertEqual(finalizeCount, 0)
            XCTAssertEqual(Set(deletedPaths), Set(fixture.plans.map(\.objectPath)))
            XCTAssertEqual(cleanupResults, [Bool](repeating: true, count: 3))
        }
    }

    func testSecondhandPublishCompensatesAfterTransactionalFinalizationFailure() async {
        let fixture = makeSecondhandPublishingFixture(imageCount: 2)
        var deletedPaths: [String] = []

        let workflow = SecondhandPublishingWorkflow(
            operations: SecondhandPublishingOperations(
                isAlreadyPublished: { _ in false },
                prepare: { _, _, _ in },
                upload: { _, plan in plan.uploadedAsset },
                markUploaded: { _, _ in },
                finalize: { _, _ in
                    throw TestPublishingError.injected("secondhand-finalize")
                },
                abandon: { _, _ in fixture.cleanupItems },
                deleteObject: { asset in deletedPaths.append(asset.path) },
                markCleanup: { _, _, _ in }
            )
        )

        do {
            _ = try await workflow.publish(
                input: fixture.input,
                images: fixture.images,
                plans: fixture.plans
            )
            XCTFail("Expected transactional finalization failure")
        } catch {
            XCTAssertEqual(
                error as? TestPublishingError,
                .injected("secondhand-finalize")
            )
        }
        XCTAssertEqual(Set(deletedPaths), Set(fixture.plans.map(\.objectPath)))
    }

    func testSecondhandPublishRetryReturnsExistingPostWithoutSideEffects() async throws {
        let fixture = makeSecondhandPublishingFixture(imageCount: 2)
        var sideEffectCount = 0
        let workflow = SecondhandPublishingWorkflow(
            operations: SecondhandPublishingOperations(
                isAlreadyPublished: { _ in true },
                prepare: { _, _, _ in sideEffectCount += 1 },
                upload: { _, plan in
                    sideEffectCount += 1
                    return plan.uploadedAsset
                },
                markUploaded: { _, _ in sideEffectCount += 1 },
                finalize: { input, _ in
                    sideEffectCount += 1
                    return input.postId
                },
                abandon: { _, _ in
                    sideEffectCount += 1
                    return []
                },
                deleteObject: { _ in sideEffectCount += 1 },
                markCleanup: { _, _, _ in sideEffectCount += 1 }
            )
        )

        let result = try await workflow.publish(
            input: fixture.input,
            images: fixture.images,
            plans: fixture.plans
        )
        XCTAssertEqual(result, fixture.input.postId)
        XCTAssertEqual(sideEffectCount, 0)
    }

    func testSecondhandPublishTreatsLostFinalizeResponseAsIdempotentSuccess() async throws {
        let fixture = makeSecondhandPublishingFixture(imageCount: 1)
        var statusChecks = 0
        var cleanupCount = 0
        let workflow = SecondhandPublishingWorkflow(
            operations: SecondhandPublishingOperations(
                isAlreadyPublished: { _ in
                    defer { statusChecks += 1 }
                    return statusChecks == 1
                },
                prepare: { _, _, _ in },
                upload: { _, plan in plan.uploadedAsset },
                markUploaded: { _, _ in },
                finalize: { _, _ in
                    throw TestPublishingError.injected("secondhand-lost-response")
                },
                abandon: { _, _ in
                    cleanupCount += 1
                    return []
                },
                deleteObject: { _ in cleanupCount += 1 },
                markCleanup: { _, _, _ in }
            )
        )

        let result = try await workflow.publish(
            input: fixture.input,
            images: fixture.images,
            plans: fixture.plans
        )
        XCTAssertEqual(result, fixture.input.postId)
        XCTAssertEqual(statusChecks, 2)
        XCTAssertEqual(cleanupCount, 0)
    }

    func testSecondhandPublishDoesNotDeleteWhenCommitOutcomeIsUnknown() async {
        let fixture = makeSecondhandPublishingFixture(imageCount: 1)
        var statusChecks = 0
        var cleanupCount = 0
        let workflow = SecondhandPublishingWorkflow(
            operations: SecondhandPublishingOperations(
                isAlreadyPublished: { _ in
                    defer { statusChecks += 1 }
                    if statusChecks == 1 {
                        throw TestPublishingError.injected("secondhand-status")
                    }
                    return false
                },
                prepare: { _, _, _ in },
                upload: { _, plan in plan.uploadedAsset },
                markUploaded: { _, _ in },
                finalize: { _, _ in
                    throw TestPublishingError.injected("secondhand-finalize")
                },
                abandon: { _, _ in
                    cleanupCount += 1
                    return fixture.cleanupItems
                },
                deleteObject: { _ in cleanupCount += 1 },
                markCleanup: { _, _, _ in cleanupCount += 1 }
            )
        )

        do {
            _ = try await workflow.publish(
                input: fixture.input,
                images: fixture.images,
                plans: fixture.plans
            )
            XCTFail("Expected unknown publication outcome")
        } catch SecondhandCreatePostError.publicationOutcomeUnknown(let error) {
            XCTAssertEqual(
                error as? TestPublishingError,
                .injected("secondhand-finalize")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(statusChecks, 2)
        XCTAssertEqual(cleanupCount, 0)
    }

    func testSecondhandCleanupFailureRemainsObservableAndRetryable() async {
        let fixture = makeSecondhandPublishingFixture(imageCount: 2)
        var cleanupAttempts: [(Bool, String?)] = []
        let workflow = SecondhandPublishingWorkflow(
            operations: SecondhandPublishingOperations(
                isAlreadyPublished: { _ in false },
                prepare: { _, _, _ in },
                upload: { _, plan in
                    if plan.orderIndex == 1 {
                        throw TestPublishingError.injected("secondhand-upload")
                    }
                    return plan.uploadedAsset
                },
                markUploaded: { _, _ in },
                finalize: { input, _ in input.postId },
                abandon: { _, _ in fixture.cleanupItems },
                deleteObject: { asset in
                    if asset.path == fixture.plans[0].objectPath {
                        throw NSError(domain: "Storage transient", code: 503)
                    }
                },
                markCleanup: { _, succeeded, errorCode in
                    cleanupAttempts.append((succeeded, errorCode))
                }
            )
        )

        do {
            _ = try await workflow.publish(
                input: fixture.input,
                images: fixture.images,
                plans: fixture.plans
            )
            XCTFail("Expected upload failure")
        } catch {
            XCTAssertEqual(
                error as? TestPublishingError,
                .injected("secondhand-upload")
            )
        }
        XCTAssertEqual(cleanupAttempts.count, 2)
        XCTAssertFalse(cleanupAttempts[0].0)
        XCTAssertEqual(cleanupAttempts[0].1, "Storage_transient:503")
        XCTAssertTrue(cleanupAttempts[1].0)
        XCTAssertNil(cleanupAttempts[1].1)
    }

    private func makeSecondhandInput(category: SecondhandPost.Category) -> SecondhandCreateInput {
        SecondhandCreateInput(
            postId: UUID(uuidString: "90000000-0000-0000-0000-000000000001")!,
            userId: UUID(uuidString: "90000000-0000-0000-0000-000000000002")!,
            schoolId: UUID(uuidString: "90000000-0000-0000-0000-000000000003")!,
            title: "Desk lamp",
            description: "Works well",
            isAnonymous: false,
            price: 18,
            category: category,
            condition: .good,
            isNegotiable: true
        )
    }

    private func makeSecondhandPublishingFixture(
        imageCount: Int
    ) -> (
        input: SecondhandCreateInput,
        images: [UIImage],
        plans: [PostImageUploadPlan],
        cleanupItems: [PostMediaCleanupItem]
    ) {
        let input = makeSecondhandInput(category: .digitalElectronics)
        let plans = (0..<imageCount).map { index in
            PostImageUploadPlan(
                bucket: "post-images",
                objectPath: "\(input.userId.uuidString.lowercased())/posts/\(input.postId.uuidString.lowercased())/\(input.postId.uuidString.lowercased())/\(String(format: "%03d", index)).jpg",
                publicURL: "https://example.test/storage/v1/object/public/post-images/secondhand-\(index).jpg",
                orderIndex: index
            )
        }
        let cleanupItems = plans.map { plan in
            PostMediaCleanupItem(
                id: UUID(),
                postImageID: nil,
                postID: input.postId,
                bucket: plan.bucket,
                objectPath: plan.objectPath,
                storedURL: plan.publicURL,
                status: "pending",
                reason: "publication_failed",
                candidateCount: nil,
                attemptCount: 0,
                lastErrorCode: nil
            )
        }
        return (
            input,
            [UIImage](repeating: UIImage(), count: imageCount),
            plans,
            cleanupItems
        )
    }

    private func makeForumPublishingFixture(
        imageCount: Int
    ) -> (
        input: ForumCreateInput,
        images: [UIImage],
        plans: [PostImageUploadPlan],
        cleanupItems: [PostMediaCleanupItem]
    ) {
        let postID = UUID(uuidString: "93000000-0000-0000-0000-000000000001")!
        let userID = UUID(uuidString: "93000000-0000-0000-0000-000000000002")!
        let input = ForumCreateInput(
            postId: postID,
            userId: userID,
            schoolId: UUID(uuidString: "93000000-0000-0000-0000-000000000003")!,
            title: "Transactional forum post",
            content: "All media must publish atomically.",
            isAnonymous: false,
            boardID: UUID(uuidString: "f0000000-0000-0000-0000-000000000002")!
        )
        let plans = (0..<imageCount).map { index in
            PostImageUploadPlan(
                bucket: "post-images",
                objectPath: "\(userID.uuidString.lowercased())/posts/\(postID.uuidString.lowercased())/\(postID.uuidString.lowercased())/\(String(format: "%03d", index)).jpg",
                publicURL: "https://example.test/storage/v1/object/public/post-images/\(index).jpg",
                orderIndex: index
            )
        }
        let cleanupItems = plans.map { plan in
            PostMediaCleanupItem(
                id: UUID(),
                postImageID: nil,
                postID: postID,
                bucket: plan.bucket,
                objectPath: plan.objectPath,
                storedURL: plan.publicURL,
                status: "pending",
                reason: "publication_failed",
                candidateCount: nil,
                attemptCount: 0,
                lastErrorCode: nil
            )
        }
        return (
            input,
            [UIImage](repeating: UIImage(), count: imageCount),
            plans,
            cleanupItems
        )
    }

    private func makeForumPost(isAnonymous: Bool, isOfficial: Bool = false) -> DBForumPost {
        DBForumPost(
            id: UUID(uuidString: "91000000-0000-0000-0000-000000000001")!,
            userId: UUID(uuidString: "91000000-0000-0000-0000-000000000002")!,
            title: "Anonymous content remains readable",
            description: "The content must not disappear for another viewer.",
            boardID: UUID(uuidString: "f0000000-0000-0000-0000-000000000002")!,
            boardName: "学术",
            boardIcon: "graduationcap.fill",
            boardAllowsAnonymous: false,
            isAnonymous: isAnonymous,
            isPinned: false,
            likeCount: 0,
            commentCount: 0,
            viewCount: 0,
            hotScore: 0,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            userName: "Real Author",
            userAvatar: "https://example.com/real-author.png",
            userOfficial: isOfficial,
            viewerOwnsPost: false,
            images: []
        )
    }

    private func makeForumItem(boardID: UUID) -> ForumPostItem {
        ForumPostItem(
            id: UUID(),
            authorId: UUID(),
            authorAvatar: nil,
            title: "Board post",
            content: "Content",
            boardID: boardID,
            boardName: "Board",
            boardIcon: "bubble.left",
            boardAllowsAnonymous: false,
            authorName: "Student",
            isAnonymous: false,
            isAuthorOfficial: false,
            timeAgo: "now",
            createdAt: Date(),
            likes: 0,
            comments: 0,
            views: 0,
            isLiked: false,
            isPinned: false,
            imageUrls: [],
            hasImage: false
        )
    }
}

private enum TestPublishingError: Error, Equatable {
    case injected(String)
}
