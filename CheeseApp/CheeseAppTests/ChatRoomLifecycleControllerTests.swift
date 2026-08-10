import XCTest
import PhotosUI
import SwiftUI
import UIKit
@testable import CheeseApp

final class ChatRoomLifecycleControllerTests: XCTestCase {
    func testBootstrapRunsOnlyOnceAfterReturningFromDetail() {
        var controller = ChatRoomLifecycleController()

        XCTAssertTrue(controller.beginBootstrapIfNeeded())
        controller.completeBootstrap()

        XCTAssertFalse(controller.beginBootstrapIfNeeded())
    }

    func testNestedDestinationKeepsRealtimeActiveOnDisappear() {
        let controller = ChatRoomLifecycleController()

        XCTAssertFalse(
            controller.shouldStopRealtimeOnDisappear(hasNestedDestinationPresented: true)
        )
        XCTAssertTrue(
            controller.shouldStopRealtimeOnDisappear(hasNestedDestinationPresented: false)
        )
    }

    func testRoomExitRejectsEventsFromPreviousSession() {
        var controller = ChatRoomLifecycleController()

        XCTAssertTrue(controller.beginBootstrapIfNeeded())
        let previousSessionID = try! XCTUnwrap(controller.activeSessionID)
        XCTAssertTrue(controller.acceptsEvents(for: previousSessionID))

        controller.invalidateForRoomExit()

        XCTAssertFalse(controller.acceptsEvents(for: previousSessionID))
        XCTAssertTrue(controller.beginBootstrapIfNeeded())
        XCTAssertNotEqual(controller.activeSessionID, previousSessionID)
    }

    func testRealtimeMergeSortsChronologicallyAndDeduplicates() {
        let baseDate = Date(timeIntervalSince1970: 1_710_000_000)
        let lateMessage = Message.fixture(
            id: UUID(uuidString: "72000000-0000-0000-0000-000000000003")!,
            createdAt: baseDate.addingTimeInterval(30),
            content: "后到的"
        )
        let earlyMessage = Message.fixture(
            id: UUID(uuidString: "72000000-0000-0000-0000-000000000001")!,
            createdAt: baseDate,
            content: "先到的"
        )
        let middleMessage = Message.fixture(
            id: UUID(uuidString: "72000000-0000-0000-0000-000000000002")!,
            createdAt: baseDate.addingTimeInterval(10),
            content: "中间的"
        )

        let merged = ChatRoomMessageTimeline.merge(
            [middleMessage],
            into: [lateMessage, earlyMessage]
        )

        XCTAssertEqual(merged.map(\.id), [earlyMessage.id, middleMessage.id, lateMessage.id])

        let deduped = ChatRoomMessageTimeline.merge(
            [middleMessage],
            into: merged
        )

        XCTAssertEqual(deduped.count, 3)
    }

    func testPageMergeDeduplicatesAndKeepsDeterministicChronologicalOrder() {
        let baseDate = Date(timeIntervalSince1970: 1_710_000_000)
        let first = Message.fixture(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000001")!,
            createdAt: baseDate,
            content: "first"
        )
        let duplicateFirst = Message.fixture(
            id: first.id,
            createdAt: baseDate,
            content: "duplicate"
        )
        let second = Message.fixture(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000002")!,
            createdAt: baseDate.addingTimeInterval(10),
            content: "second"
        )
        let third = Message.fixture(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000003")!,
            createdAt: baseDate.addingTimeInterval(20),
            content: "third"
        )

        let merged = ChatRoomMessageTimeline.merge(
            [duplicateFirst, second],
            into: [third, first]
        )

        XCTAssertEqual(merged.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(merged.first?.content, "first")
    }

    func testTimelineSeparatorsUseFiveMinuteThreshold() {
        let baseDate = Date(timeIntervalSince1970: 1_710_000_000)
        let messages = [
            Message.fixture(id: UUID(), createdAt: baseDate, content: "first"),
            Message.fixture(
                id: UUID(),
                createdAt: baseDate.addingTimeInterval(4 * 60),
                content: "grouped"
            ),
            Message.fixture(
                id: UUID(),
                createdAt: baseDate.addingTimeInterval(9 * 60),
                content: "new group"
            )
        ]

        let entries = ChatRoomMessageTimeline.entries(for: messages)

        XCTAssertEqual(entries.map(\.showsTimeSeparator), [true, false, true])
    }

    func testTimelineDateBoundaryAlwaysCreatesSeparator() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let first = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 23, minute: 59))
        )
        let second = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 0))
        )
        let messages = [
            Message.fixture(id: UUID(), createdAt: first, content: "before midnight"),
            Message.fixture(id: UUID(), createdAt: second, content: "after midnight")
        ]

        let entries = ChatRoomMessageTimeline.entries(for: messages, calendar: calendar)

        XCTAssertEqual(entries.map(\.showsTimeSeparator), [true, true])
    }

    func testPrependingHistoryRecomputesBoundaryWithoutDuplicateSeparator() {
        let baseDate = Date(timeIntervalSince1970: 1_710_000_000)
        let older = Message.fixture(id: UUID(), createdAt: baseDate, content: "older")
        let formerFirst = Message.fixture(
            id: UUID(),
            createdAt: baseDate.addingTimeInterval(3 * 60),
            content: "former first"
        )
        let newest = Message.fixture(
            id: UUID(),
            createdAt: baseDate.addingTimeInterval(4 * 60),
            content: "newest"
        )

        let entries = ChatRoomMessageTimeline.entries(
            for: [newest, older, formerFirst, formerFirst]
        )

        XCTAssertEqual(entries.map(\.message.id), [older.id, formerFirst.id, newest.id])
        XCTAssertEqual(entries.map(\.showsTimeSeparator), [true, false, false])
    }

    func testTimelineTimeLabelsUseLocalCalendarBuckets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let locale = Locale(identifier: "zh_CN")
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 15))
        )
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try XCTUnwrap(
                calendar.date(
                    from: DateComponents(
                        year: year,
                        month: month,
                        day: day,
                        hour: hour,
                        minute: minute
                    )
                )
            )
        }

        XCTAssertEqual(
            ChatTimeFormatter.timelineString(
                from: try date(2026, 8, 12, 11, 32),
                relativeTo: now,
                calendar: calendar,
                locale: locale
            ),
            "今天 11:32"
        )
        XCTAssertEqual(
            ChatTimeFormatter.timelineString(
                from: try date(2026, 8, 11, 23, 18),
                relativeTo: now,
                calendar: calendar,
                locale: locale
            ),
            "昨天 23:18"
        )
        XCTAssertEqual(
            ChatTimeFormatter.timelineString(
                from: try date(2026, 8, 10, 18, 20),
                relativeTo: now,
                calendar: calendar,
                locale: locale
            ),
            "周一 18:20"
        )
        XCTAssertEqual(
            ChatTimeFormatter.timelineString(
                from: try date(2026, 8, 5, 14, 32),
                relativeTo: now,
                calendar: calendar,
                locale: locale
            ),
            "08-05 14:32"
        )
        XCTAssertEqual(
            ChatTimeFormatter.timelineString(
                from: try date(2025, 12, 28, 20, 15),
                relativeTo: now,
                calendar: calendar,
                locale: locale
            ),
            "2025-12-28 20:15"
        )
    }
}

private extension Message {
    static func fixture(
        id: UUID,
        conversationId: UUID = UUID(uuidString: "82000000-0000-0000-0000-000000000001")!,
        senderId: UUID? = UUID(uuidString: "82000000-0000-0000-0000-000000000002")!,
        createdAt: Date,
        content: String
    ) -> Message {
        Message(
            id: id,
            conversationId: conversationId,
            senderId: senderId,
            content: content,
            messageType: "text",
            metadata: nil,
            isRead: true,
            createdAt: createdAt
        )
    }
}

@MainActor
final class ChatRoomViewModelTests: XCTestCase {
    func testDuplicateSubmitIsIgnoredWhileTextSendIsInFlight() async {
        let conversation = ChatConversationPreview.fixture()
        let senderID = UUID()
        let recorder = ChatRoomSendRecorder(conversationID: conversation.id, senderID: senderID)
        let viewModel = makeViewModel(conversation, senderID: senderID, recorder: recorder)

        viewModel.draftText = "hello"
        viewModel.submitText()
        viewModel.submitText()

        await waitUntil { !viewModel.isSubmittingComposer && viewModel.messages.count == 1 }
        let textAttempts = await recorder.textAttempts
        XCTAssertEqual(textAttempts, 1)
    }

    func testFailedTextSendRemainsRetryableAndRetryDoesNotDuplicate() async {
        let conversation = ChatConversationPreview.fixture()
        let senderID = UUID()
        let recorder = ChatRoomSendRecorder(
            conversationID: conversation.id,
            senderID: senderID,
            textFailures: 1
        )
        let viewModel = makeViewModel(conversation, senderID: senderID, recorder: recorder)

        viewModel.draftText = "retry me"
        viewModel.submitText()

        await waitUntil { viewModel.canRetry }
        XCTAssertTrue(viewModel.canRetry)
        XCTAssertTrue(viewModel.messages.isEmpty)

        viewModel.retryFailedSend()
        await waitUntil { !viewModel.isSubmittingComposer && viewModel.messages.count == 1 }

        let textAttempts = await recorder.textAttempts
        XCTAssertEqual(textAttempts, 2)
        XCTAssertEqual(viewModel.messages.map(\.content), ["retry me"])
    }

    func testSuccessfulSendDoesNotEraseDraftEditedWhileRequestWasInFlight() async {
        let conversation = ChatConversationPreview.fixture()
        let senderID = UUID()
        let recorder = ChatRoomSendRecorder(
            conversationID: conversation.id,
            senderID: senderID,
            textDelayNanoseconds: 30_000_000
        )
        let viewModel = makeViewModel(conversation, senderID: senderID, recorder: recorder)

        viewModel.draftText = "first"
        viewModel.submitText()
        viewModel.draftText = "next draft"

        await waitUntil { !viewModel.isSubmittingComposer && viewModel.messages.count == 1 }
        XCTAssertEqual(viewModel.draftText, "next draft")
    }

    func testFailedMuteKeepsServiceBackedStateAndPresentsError() async {
        let conversation = ChatConversationPreview.fixture()
        let senderID = UUID()
        let recorder = ChatRoomSendRecorder(conversationID: conversation.id, senderID: senderID)
        let chatService = ChatRoomServiceStub(muteShouldFail: true)
        let viewModel = makeViewModel(
            conversation,
            senderID: senderID,
            recorder: recorder,
            chatService: chatService
        )

        viewModel.handleSettingsAction(.setMuted(true))
        await waitUntil { chatService.muteAttempts == 1 && !viewModel.isApplyingPrivacyAction }

        XCTAssertFalse(viewModel.isMuted)
        XCTAssertEqual(viewModel.displayedRoomError, "send failed")
    }

    func testFirstStrangerSendWaitsForConfirmationAndPersistsAcknowledgement() async {
        let conversation = ChatConversationPreview.fixture(
            canChatFreely: false,
            isMutualFollow: false
        )
        let senderID = UUID()
        let recorder = ChatRoomSendRecorder(conversationID: conversation.id, senderID: senderID)
        let safetyStore = ChatStrangerSafetyStoreStub()
        let viewModel = makeViewModel(
            conversation,
            senderID: senderID,
            recorder: recorder,
            safetyStore: safetyStore
        )

        viewModel.draftText = "hello"
        viewModel.submitText()

        XCTAssertEqual(viewModel.alertDestination, .strangerSendConfirmation)
        let attemptsBeforeConfirmation = await recorder.textAttempts
        XCTAssertEqual(attemptsBeforeConfirmation, 0)

        viewModel.confirmPendingSend()
        await waitUntil { !viewModel.isSubmittingComposer && viewModel.messages.count == 1 }

        XCTAssertTrue(
            safetyStore.hasAcknowledged(
                userID: senderID,
                conversationID: conversation.id
            )
        )
        let attemptsAfterConfirmation = await recorder.textAttempts
        XCTAssertEqual(attemptsAfterConfirmation, 1)
    }

    func testImageRetryReusesUploadedAsset() async {
        let conversation = ChatConversationPreview.fixture()
        let senderID = UUID()
        let recorder = ChatRoomSendRecorder(
            conversationID: conversation.id,
            senderID: senderID,
            imageFailures: 1
        )
        let media = ChatRoomMediaServiceStub()
        let viewModel = makeViewModel(
            conversation,
            senderID: senderID,
            recorder: recorder,
            mediaService: media,
            stagedImages: [UIImage()]
        )

        viewModel.submitComposer()
        await waitUntil { viewModel.canRetry }
        XCTAssertEqual(media.uploadCount, 1)

        viewModel.retryFailedSend()
        await waitUntil { !viewModel.isSubmittingComposer && viewModel.messages.count == 1 }

        XCTAssertEqual(media.uploadCount, 1)
        XCTAssertEqual(media.retainedAssets.count, 1)
        let imageAttempts = await recorder.imageAttempts
        XCTAssertEqual(imageAttempts, 2)
    }

    func testCancellingImageSendCleansUploadedAssetAndRestoresImage() async {
        let conversation = ChatConversationPreview.fixture()
        let senderID = UUID()
        let recorder = ChatRoomSendRecorder(conversationID: conversation.id, senderID: senderID)
        let media = ChatRoomMediaServiceStub(uploadDelayNanoseconds: 30_000_000)
        let viewModel = makeViewModel(
            conversation,
            senderID: senderID,
            recorder: recorder,
            mediaService: media,
            stagedImages: [UIImage()]
        )

        viewModel.submitComposer()
        await waitUntil { media.uploadCount == 1 }
        viewModel.cancelActiveMediaWork()
        await waitUntil { !viewModel.isSubmittingComposer && viewModel.stagedImages.count == 1 }

        XCTAssertEqual(media.deletedAssets.count, 1)
        let imageAttempts = await recorder.imageAttempts
        XCTAssertEqual(imageAttempts, 0)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    @MainActor
    func testChatUploadFailureDoesNotFallBackToPostImages() async {
        let userID = UUID()
        let conversationID = UUID()
        var attemptedBuckets: [String] = []
        let service = LiveChatRoomMediaService(
            currentUserID: { userID },
            uploadAsset: { _, bucket, _ in
                attemptedBuckets.append(bucket)
                throw ChatRoomTestError.sendFailed
            },
            deleteAsset: { _ in },
            prepareCleanup: { _ in UUID() },
            markCleanup: { _, _, _ in },
            resolveCleanup: { _ in }
        )

        do {
            _ = try await service.uploadImage(
                UIImage(),
                scope: .direct,
                scopeID: conversationID
            )
            XCTFail("Expected upload to fail")
        } catch {
            XCTAssertEqual(attemptedBuckets, [StorageBuckets.chatImages])
            XCTAssertFalse(attemptedBuckets.contains(StorageBuckets.postImages))
        }
    }

    @MainActor
    func testChatCleanupFailureRemainsDurablyMarkedForRetry() async throws {
        let userID = UUID()
        let conversationID = UUID()
        let cleanupID = UUID()
        var markedCleanupID: UUID?
        var markedSucceeded: Bool?
        var markedErrorCode: String?
        let service = LiveChatRoomMediaService(
            currentUserID: { userID },
            uploadAsset: { _, bucket, path in
                UploadedImageAsset(publicURL: "", bucket: bucket, path: path)
            },
            deleteAsset: { _ in throw ChatRoomTestError.sendFailed },
            prepareCleanup: { _ in cleanupID },
            markCleanup: { id, succeeded, errorCode in
                markedCleanupID = id
                markedSucceeded = succeeded
                markedErrorCode = errorCode
            },
            resolveCleanup: { _ in }
        )

        let asset = try await service.uploadImage(
            UIImage(),
            scope: .direct,
            scopeID: conversationID
        )
        await service.deleteUploadedImage(asset)

        XCTAssertEqual(markedCleanupID, cleanupID)
        XCTAssertEqual(markedSucceeded, false)
        XCTAssertTrue(markedErrorCode?.hasPrefix("storage_delete:") == true)
    }

    func testSignedURLExpirationRefreshesOnceWithoutPersistingURL() async throws {
        let scopeID = UUID()
        let uploaderID = UUID()
        let reference = ChatMediaReference(
            bucket: StorageBuckets.chatImages,
            objectPath: "direct/\(scopeID.uuidString.lowercased())/\(uploaderID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg",
            scope: .direct,
            scopeID: scopeID
        )
        let recorder = ChatMediaLoaderRecorder()
        let loader = ChatMediaDataLoader(
            signURL: { reference, lifetime in
                await recorder.recordSign(reference: reference, lifetime: lifetime)
            },
            download: { url in
                try await recorder.download(url: url)
            }
        )

        let data = try await loader.loadData(for: reference)

        XCTAssertEqual(data, Data("private-image".utf8))
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.signCount, 2)
        XCTAssertEqual(snapshot.downloadCount, 2)
        XCTAssertEqual(
            snapshot.lifetimes,
            [
                ChatMediaDataLoader.signedURLLifetimeSeconds,
                ChatMediaDataLoader.signedURLLifetimeSeconds
            ]
        )
    }

    func testChatMediaReferenceRejectsCrossConversation() {
        let conversationID = UUID()
        let reference = ChatMediaReference(
            bucket: StorageBuckets.chatImages,
            objectPath: "direct/\(conversationID.uuidString.lowercased())/\(UUID().uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg",
            scope: .direct,
            scopeID: conversationID
        )

        XCTAssertTrue(reference.belongs(to: .direct, id: conversationID))
        XCTAssertFalse(reference.belongs(to: .direct, id: UUID()))
        XCTAssertFalse(reference.belongs(to: .group, id: conversationID))
    }

    func testImageMessageMetadataEncodesCanonicalLowercaseScopeID() throws {
        let scopeID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
        let metadata = MessageMetadata(
            imageURL: nil,
            sharedPostCard: nil,
            postContactCard: nil,
            imageBucket: StorageBuckets.chatImages,
            imageObjectPath: "direct/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee/00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000002.jpg",
            imageScope: ChatMediaScope.direct.rawValue,
            imageScopeID: scopeID
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata))
                as? [String: Any]
        )

        XCTAssertEqual(
            object["image_scope_id"] as? String,
            scopeID.uuidString.lowercased()
        )
        XCTAssertNil(object["image_url"])
    }

    func testSecondhandTransactionEventMetadataDecodesAuthoritativeStatus() throws {
        let listingID = UUID()
        let intentID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "secondhand_transaction_event": [
                "kind": "listing_sold",
                "listing_id": listingID.uuidString.lowercased(),
                "intent_id": intentID.uuidString.lowercased()
            ]
        ])

        let metadata = try JSONDecoder().decode(MessageMetadata.self, from: data)

        XCTAssertEqual(metadata.secondhandTransactionEvent?.kind, .listingSold)
        XCTAssertEqual(metadata.secondhandTransactionEvent?.listingId, listingID)
        XCTAssertEqual(metadata.secondhandTransactionEvent?.intentId, intentID)
        XCTAssertEqual(
            metadata.secondhandTransactionEvent?.kind.displayTitle,
            "该商品已售出"
        )
    }

    func testBuyerCancellationUsesTransactionServiceAndKeepsEndedState() async {
        let buyerID = UUID()
        let conversation = ChatConversationPreview.fixture()
        let intent = SecondhandChatPurchaseIntent.fixture(
            conversationID: conversation.id,
            sellerID: conversation.otherUserId,
            buyerID: buyerID,
            role: .buyer
        )
        let transactionService = SecondhandTransactionServiceStub(intent: intent)
        let recorder = ChatRoomSendRecorder(
            conversationID: conversation.id,
            senderID: buyerID
        )
        let viewModel = makeViewModel(
            conversation,
            senderID: buyerID,
            recorder: recorder,
            chatService: ChatRoomServiceStub(),
            transactionService: transactionService
        )

        await viewModel.bootstrap(currentUserID: buyerID)
        XCTAssertEqual(viewModel.secondhandPurchaseIntent?.status, .active)

        viewModel.requestCancelSecondhandPurchaseIntent()
        XCTAssertEqual(viewModel.alertDestination, .cancelSecondhandPurchaseIntent)
        viewModel.confirmCancelSecondhandPurchaseIntent()

        await waitUntil {
            viewModel.secondhandPurchaseIntent?.status == .buyerCancelled
        }
        XCTAssertEqual(transactionService.cancelAttempts, 1)
        XCTAssertFalse(viewModel.secondhandPurchaseIntent?.status.isActive ?? true)
    }

    func testSellerWithMultipleActiveBuyersMustSelectBeforeCompletion() async {
        let sellerID = UUID()
        let conversation = ChatConversationPreview.fixture()
        let currentBuyerID = conversation.otherUserId
        let otherBuyerID = UUID()
        let intent = SecondhandChatPurchaseIntent.fixture(
            conversationID: conversation.id,
            sellerID: sellerID,
            buyerID: currentBuyerID,
            role: .seller
        )
        let transactionService = SecondhandTransactionServiceStub(
            intent: intent,
            buyers: [
                .fixture(buyerID: currentBuyerID, conversationID: conversation.id),
                .fixture(buyerID: otherBuyerID, conversationID: UUID())
            ]
        )
        let recorder = ChatRoomSendRecorder(
            conversationID: conversation.id,
            senderID: sellerID
        )
        let viewModel = makeViewModel(
            conversation,
            senderID: sellerID,
            recorder: recorder,
            chatService: ChatRoomServiceStub(),
            transactionService: transactionService
        )

        await viewModel.bootstrap(currentUserID: sellerID)
        viewModel.requestCompleteSecondhandSale()
        await waitUntil {
            viewModel.sheetDestination?.id == "secondhand-buyer-selection"
        }

        viewModel.selectSecondhandBuyerForCompletion(otherBuyerID)
        await waitUntil {
            viewModel.alertDestination == .completeSecondhandSale(otherBuyerID)
        }
        viewModel.confirmCompleteSecondhandSale(buyerID: otherBuyerID)

        await waitUntil {
            viewModel.secondhandPurchaseIntent?.status == .listingSold
        }
        XCTAssertEqual(transactionService.completedBuyerIDs, [otherBuyerID])
    }

    func testUserDefaultsSafetyAcknowledgementIsScopedToUserAndConversation() {
        let suiteName = "ChatRoomViewModelTests.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsChatStrangerSafetyStore(defaults: defaults)
        let userID = UUID()
        let conversationID = UUID()
        store.acknowledge(userID: userID, conversationID: conversationID)

        XCTAssertTrue(store.hasAcknowledged(userID: userID, conversationID: conversationID))
        XCTAssertFalse(store.hasAcknowledged(userID: UUID(), conversationID: conversationID))
        XCTAssertFalse(store.hasAcknowledged(userID: userID, conversationID: UUID()))
    }

    private func makeViewModel(
        _ conversation: ChatConversationPreview,
        senderID: UUID,
        recorder: ChatRoomSendRecorder,
        chatService: (any ChatRoomServicing)? = nil,
        transactionService: (any SecondhandChatTransactionServicing)? = nil,
        mediaService: ChatRoomMediaServiceStub? = nil,
        safetyStore: ChatStrangerSafetyStoreStub = ChatStrangerSafetyStoreStub(),
        stagedImages: [UIImage] = []
    ) -> ChatRoomViewModel {
        let state = ChatRoomMessageState<Message>(
            operations: ChatRoomMessageOperations(
                loadInitialPage: {
                    ChatMessagePage(messages: [], nextCursor: nil)
                },
                loadOlderPage: { _ in
                    ChatMessagePage(messages: [], nextCursor: nil)
                },
                observe: { _, _, _ in {} },
                sendText: { content, _ in try await recorder.sendText(content) },
                sendImage: { try await recorder.sendImage($0) },
                markRead: {},
                isIncoming: { _ in false },
                marksReadWhenLoadFails: true
            )
        )

        return ChatRoomViewModel(
            conversation: conversation,
            roomState: state,
            chatService: chatService,
            secondhandTransactionService: transactionService,
            mediaService: mediaService ?? ChatRoomMediaServiceStub(),
            strangerSafetyStore: safetyStore,
            currentUserID: senderID,
            stagedImages: stagedImages
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition was not met before timeout", file: file, line: line)
    }
}

private enum ChatRoomTestError: LocalizedError {
    case sendFailed

    var errorDescription: String? { "send failed" }
}

private actor ChatRoomSendRecorder {
    private let conversationID: UUID
    private let senderID: UUID
    private var textFailures: Int
    private var imageFailures: Int
    private let textDelayNanoseconds: UInt64
    private(set) var textAttempts = 0
    private(set) var imageAttempts = 0

    init(
        conversationID: UUID,
        senderID: UUID,
        textFailures: Int = 0,
        imageFailures: Int = 0,
        textDelayNanoseconds: UInt64 = 0
    ) {
        self.conversationID = conversationID
        self.senderID = senderID
        self.textFailures = textFailures
        self.imageFailures = imageFailures
        self.textDelayNanoseconds = textDelayNanoseconds
    }

    func sendText(_ content: String) async throws -> Message {
        textAttempts += 1
        if textDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: textDelayNanoseconds)
        }
        if textFailures > 0 {
            textFailures -= 1
            throw ChatRoomTestError.sendFailed
        }
        return message(content: content)
    }

    func sendImage(_ media: ChatMediaReference) throws -> Message {
        imageAttempts += 1
        if imageFailures > 0 {
            imageFailures -= 1
            throw ChatRoomTestError.sendFailed
        }
        return message(content: media.objectPath)
    }

    private func message(content: String) -> Message {
        return Message.fixture(
            id: UUID(),
            conversationId: conversationID,
            senderId: senderID,
            createdAt: Date(),
            content: content
        )
    }
}

@MainActor
private final class ChatRoomServiceStub: ChatRoomServicing {
    private let muteShouldFail: Bool
    private(set) var muteAttempts = 0

    init(muteShouldFail: Bool = false) {
        self.muteShouldFail = muteShouldFail
    }

    func conversationRemark(for conversationId: UUID) -> String? { nil }
    func displayName(for conversation: ChatConversationPreview) -> String { conversation.displayName }
    func setConversationRemark(conversationId: UUID, remark: String?) {}
    func fetchDirectConversationSettings(conversationId: UUID) async -> DirectConversationSettings { .default }

    func setConversationMuted(conversationId: UUID, isMuted: Bool) async throws {
        muteAttempts += 1
        if muteShouldFail { throw ChatRoomTestError.sendFailed }
    }

    func clearConversationHistory(conversationId: UUID) async throws -> Date { Date() }
    func deleteDirectMessage(messageId: UUID, forEveryone: Bool) async throws {}
    func fetchBlockRelation(with otherUserId: UUID) async -> UserBlockRelation { .none }
    func setUserBlocked(_ otherUserId: UUID, blocked: Bool) async throws {}
    func reportUser(
        reportedUserId: UUID,
        conversationId: UUID?,
        reason: String,
        details: String?
    ) async throws {}
}

@MainActor
private final class SecondhandTransactionServiceStub: SecondhandChatTransactionServicing {
    private(set) var intent: SecondhandChatPurchaseIntent?
    private let buyers: [SecondhandActiveBuyer]
    private(set) var cancelAttempts = 0
    private(set) var completedBuyerIDs: [UUID] = []

    init(
        intent: SecondhandChatPurchaseIntent?,
        buyers: [SecondhandActiveBuyer] = []
    ) {
        self.intent = intent
        self.buyers = buyers
    }

    func fetchSecondhandPurchaseIntent(
        conversationId: UUID
    ) async throws -> SecondhandChatPurchaseIntent? {
        intent
    }

    func fetchSecondhandActiveBuyers(
        listingId: UUID
    ) async throws -> [SecondhandActiveBuyer] {
        buyers
    }

    func cancelSecondhandPurchaseIntent(intentId: UUID) async throws {
        cancelAttempts += 1
        guard let current = intent else { return }
        intent = current.replacing(status: .buyerCancelled)
    }

    func completeSecondhandSale(listingId: UUID, buyerId: UUID) async throws {
        completedBuyerIDs.append(buyerId)
        guard let current = intent else { return }
        intent = current.replacing(
            status: current.buyerId == buyerId ? .completed : .listingSold
        )
    }

    func stopSellingSecondhandListing(listingId: UUID) async throws {
        guard let current = intent else { return }
        intent = current.replacing(status: .sellerStopped)
    }
}

@MainActor
private final class ChatRoomMediaServiceStub: ChatRoomMediaServicing {
    private let uploadDelayNanoseconds: UInt64
    private(set) var uploadCount = 0
    private(set) var deletedAssets: [ChatMediaAsset] = []
    private(set) var retainedAssets: [ChatMediaAsset] = []

    init(uploadDelayNanoseconds: UInt64 = 0) {
        self.uploadDelayNanoseconds = uploadDelayNanoseconds
    }

    func loadImages(from items: [PhotosPickerItem]) async throws -> [UIImage] { [] }

    func uploadImage(
        _ image: UIImage,
        scope: ChatMediaScope,
        scopeID: UUID
    ) async throws -> ChatMediaAsset {
        uploadCount += 1
        if uploadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: uploadDelayNanoseconds)
        }
        let reference = ChatMediaReference(
            bucket: StorageBuckets.chatImages,
            objectPath: "\(scope.rawValue)/\(scopeID.uuidString.lowercased())/\(UUID().uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg",
            scope: scope,
            scopeID: scopeID
        )
        return ChatMediaAsset(reference: reference, cleanupID: UUID())
    }

    func deleteUploadedImage(_ asset: ChatMediaAsset) async {
        deletedAssets.append(asset)
    }

    func retainUploadedImage(_ asset: ChatMediaAsset) async {
        retainedAssets.append(asset)
    }
}

private actor ChatMediaLoaderRecorder {
    private var signCount = 0
    private var downloadCount = 0
    private var lifetimes: [Int] = []

    func recordSign(reference: ChatMediaReference, lifetime: Int) -> URL {
        signCount += 1
        lifetimes.append(lifetime)
        return URL(string: "https://signed.invalid/\(reference.objectPath)?attempt=\(signCount)")!
    }

    func download(url: URL) throws -> Data {
        downloadCount += 1
        if downloadCount == 1 {
            throw ChatMediaLoadError.expiredSignedURL
        }
        return Data("private-image".utf8)
    }

    func snapshot() -> (signCount: Int, downloadCount: Int, lifetimes: [Int]) {
        (signCount, downloadCount, lifetimes)
    }
}

private final class ChatStrangerSafetyStoreStub: ChatStrangerSafetyStoring {
    private var acknowledgements = Set<String>()

    func hasAcknowledged(userID: UUID, conversationID: UUID) -> Bool {
        acknowledgements.contains(key(userID: userID, conversationID: conversationID))
    }

    func acknowledge(userID: UUID, conversationID: UUID) {
        acknowledgements.insert(key(userID: userID, conversationID: conversationID))
    }

    private func key(userID: UUID, conversationID: UUID) -> String {
        "\(userID.uuidString):\(conversationID.uuidString)"
    }
}

private extension ChatConversationPreview {
    static func fixture(
        canChatFreely: Bool? = true,
        isMutualFollow: Bool? = true
    ) -> ChatConversationPreview {
        ChatConversationPreview(
            id: UUID(),
            otherUserId: UUID(),
            otherUserName: "Other User",
            otherUserAvatar: nil,
            relatedPostId: nil,
            lastMessageAt: Date(),
            lastMessagePreview: nil,
            unreadCount: 0,
            canChatFreely: canChatFreely,
            isMutualFollow: isMutualFollow
        )
    }
}

private extension SecondhandChatPurchaseIntent {
    static func fixture(
        conversationID: UUID,
        sellerID: UUID,
        buyerID: UUID,
        role: SecondhandTransactionViewerRole
    ) -> SecondhandChatPurchaseIntent {
        SecondhandChatPurchaseIntent(
            id: UUID(),
            listingId: UUID(),
            conversationId: conversationID,
            sellerId: sellerID,
            buyerId: buyerID,
            status: .active,
            startedAt: Date(),
            updatedAt: Date(),
            listingTitle: "Test listing",
            listingStatus: "active",
            listingIsPrivate: false,
            viewerRole: role
        )
    }

    func replacing(
        status: SecondhandPurchaseIntentStatus
    ) -> SecondhandChatPurchaseIntent {
        SecondhandChatPurchaseIntent(
            id: id,
            listingId: listingId,
            conversationId: conversationId,
            sellerId: sellerId,
            buyerId: buyerId,
            status: status,
            startedAt: startedAt,
            updatedAt: Date(),
            listingTitle: listingTitle,
            listingStatus: status == .completed || status == .listingSold
                ? "completed"
                : listingStatus,
            listingIsPrivate: listingIsPrivate,
            viewerRole: viewerRole
        )
    }
}

private extension SecondhandActiveBuyer {
    static func fixture(
        buyerID: UUID,
        conversationID: UUID
    ) -> SecondhandActiveBuyer {
        SecondhandActiveBuyer(
            buyerId: buyerID,
            buyerName: "Buyer",
            buyerAvatar: nil,
            conversationId: conversationID,
            startedAt: Date()
        )
    }
}
