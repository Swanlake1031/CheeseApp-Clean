import XCTest
import PhotosUI
import SwiftUI
import UIKit
@testable import CheeseApp

@MainActor
final class ChatRoomHistoryViewModelTests: XCTestCase {
    func testLoadSortAndSearchAreOwnedByViewModel() async {
        let conversationID = UUID()
        let oldest = Message.historyFixture(
            conversationID: conversationID,
            content: "office hours",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let newestImage = Message.historyFixture(
            conversationID: conversationID,
            content: "image",
            messageType: "image",
            createdAt: Date(timeIntervalSince1970: 200)
        )
        var loadCount = 0
        let viewModel = ChatRoomHistoryViewModel(conversationID: conversationID) { id, cursor in
            XCTAssertEqual(id, conversationID)
            XCTAssertNil(cursor)
            loadCount += 1
            return ChatMessagePage(messages: [oldest, newestImage], nextCursor: nil)
        }

        await viewModel.loadIfNeeded()
        await viewModel.loadIfNeeded()

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(viewModel.filteredMessages.map(\.id), [newestImage.id, oldest.id])

        viewModel.queryText = "图片"
        XCTAssertEqual(viewModel.filteredMessages.map(\.id), [newestImage.id])

        viewModel.queryText = "OFFICE"
        XCTAssertEqual(viewModel.filteredMessages.map(\.id), [oldest.id])
    }

    func testLoadFailureOwnsErrorAndEmptyState() async {
        let viewModel = ChatRoomHistoryViewModel(conversationID: UUID()) { _, _ in
            throw ChatAuditTestError.failed
        }

        await viewModel.loadIfNeeded()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.errorMessage, "failed")
    }

    func testOlderPageFailurePreservesLoadedMessagesAndCanRetry() async {
        let conversationID = UUID()
        let newest = Message.historyFixture(
            conversationID: conversationID,
            content: "new",
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let oldest = Message.historyFixture(
            conversationID: conversationID,
            content: "old",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let cursor = ChatMessagePageCursor(createdAt: newest.createdAt, id: newest.id)
        var olderAttempts = 0
        let viewModel = ChatRoomHistoryViewModel(conversationID: conversationID) { _, suppliedCursor in
            guard suppliedCursor != nil else {
                return ChatMessagePage(messages: [newest], nextCursor: cursor)
            }
            olderAttempts += 1
            if olderAttempts == 1 { throw ChatAuditTestError.failed }
            return ChatMessagePage(messages: [oldest], nextCursor: nil)
        }

        await viewModel.loadIfNeeded()
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.messages.map(\.id), [newest.id])
        XCTAssertEqual(viewModel.pageErrorMessage, "failed")
        XCTAssertTrue(viewModel.hasMore)

        await viewModel.loadMore()

        XCTAssertEqual(viewModel.messages.map(\.id), [newest.id, oldest.id])
        XCTAssertNil(viewModel.pageErrorMessage)
        XCTAssertFalse(viewModel.hasMore)
    }
}

@MainActor
final class GroupChatRoomViewModelTests: XCTestCase {
    func testStoppedRoomRejectsStaleOlderHistoryResponse() async {
        let group = ChatGroupPreview.auditFixture()
        let newest = GroupMessage.auditFixture(
            groupID: group.id,
            content: "new",
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let oldest = GroupMessage.auditFixture(
            groupID: group.id,
            content: "old",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let cursor = ChatMessagePageCursor(createdAt: newest.createdAt, id: newest.id)
        let state = ChatRoomMessageState<GroupMessage>(
            operations: ChatRoomMessageOperations(
                loadInitialPage: {
                    ChatMessagePage(messages: [newest], nextCursor: cursor)
                },
                loadOlderPage: { _ in
                    try await Task.sleep(nanoseconds: 30_000_000)
                    return ChatMessagePage(messages: [oldest], nextCursor: nil)
                },
                observe: { _, _, _ in {} },
                sendText: { _, _ in newest },
                sendImage: { _ in newest },
                markRead: {},
                isIncoming: { _ in false },
                marksReadWhenLoadFails: false
            )
        )

        await state.bootstrap()
        let task = Task { await state.loadOlderHistory() }
        try? await Task.sleep(nanoseconds: 5_000_000)
        state.stop()
        await task.value

        XCTAssertEqual(state.messages.map(\.id), [newest.id])
        XCTAssertFalse(state.isLoadingOlderHistory)
    }

    func testDuplicateSubmitIsIgnoredAndEditedDraftIsPreserved() async {
        let group = ChatGroupPreview.auditFixture()
        let recorder = GroupMessageRecorder(groupID: group.id, delayNanoseconds: 30_000_000)
        let roomState = makeRoomState(recorder: recorder)
        let viewModel = GroupChatRoomViewModel(group: group, roomState: roomState)

        viewModel.draftText = "first"
        viewModel.submitText()
        viewModel.submitText()
        viewModel.draftText = "next draft"

        await waitUntil { !viewModel.isComposerBusy && viewModel.messages.count == 1 }

        let sendAttempts = await recorder.sendAttempts
        XCTAssertEqual(sendAttempts, 1)
        XCTAssertEqual(viewModel.messages.map(\.content), ["first"])
        XCTAssertEqual(viewModel.draftText, "next draft")
    }

    func testMultipleStagedImagesSendWithGroupScope() async {
        let group = ChatGroupPreview.auditFixture()
        let recorder = GroupMessageRecorder(groupID: group.id)
        let mediaService = GroupChatMediaServiceStub()
        let viewModel = GroupChatRoomViewModel(
            group: group,
            roomState: makeRoomState(recorder: recorder),
            mediaService: mediaService,
            stagedImages: [UIImage(), UIImage()]
        )

        XCTAssertEqual(viewModel.imageSelectionLimit, 9)
        XCTAssertEqual(viewModel.stagedImages.count, 2)

        viewModel.submitComposer()
        await waitUntil {
            !viewModel.isComposerBusy && viewModel.stagedImages.isEmpty
        }

        let sendAttempts = await recorder.sendAttempts
        XCTAssertEqual(sendAttempts, 2)
        XCTAssertEqual(mediaService.uploadedScopes, [.group, .group])
        XCTAssertEqual(mediaService.retainedAssets.count, 2)
        XCTAssertEqual(viewModel.messages.count, 2)
    }

    func testNavigationUsesOneTypedDestination() {
        let group = ChatGroupPreview.auditFixture()
        let viewModel = GroupChatRoomViewModel(
            group: group,
            roomState: makeRoomState(recorder: GroupMessageRecorder(groupID: group.id))
        )
        let userID = UUID()

        viewModel.openDetails()
        XCTAssertEqual(viewModel.destination, .details)

        viewModel.openProfile(userID)
        XCTAssertEqual(viewModel.destination, .userProfile(userID))
    }

    private func makeRoomState(
        recorder: GroupMessageRecorder
    ) -> ChatRoomMessageState<GroupMessage> {
        ChatRoomMessageState<GroupMessage>(
            operations: ChatRoomMessageOperations(
                loadInitialPage: {
                    ChatMessagePage(messages: [], nextCursor: nil)
                },
                loadOlderPage: { _ in
                    ChatMessagePage(messages: [], nextCursor: nil)
                },
                observe: { _, _, _ in {} },
                sendText: { content, _ in
                    try await recorder.send(content, messageType: "text")
                },
                sendImage: { try await recorder.send($0.objectPath, messageType: "image") },
                markRead: {},
                isIncoming: { _ in false },
                marksReadWhenLoadFails: false
            )
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

private enum ChatAuditTestError: LocalizedError {
    case failed

    var errorDescription: String? { "failed" }
}

private actor GroupMessageRecorder {
    private let groupID: UUID
    private let senderID = UUID()
    private let delayNanoseconds: UInt64
    private(set) var sendAttempts = 0

    init(groupID: UUID, delayNanoseconds: UInt64 = 0) {
        self.groupID = groupID
        self.delayNanoseconds = delayNanoseconds
    }

    func send(_ content: String, messageType: String) async throws -> GroupMessage {
        sendAttempts += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return GroupMessage(
            id: UUID(),
            groupId: groupID,
            senderId: senderID,
            content: content,
            messageType: messageType,
            metadata: nil,
            isDeleted: false,
            createdAt: Date(),
            senderName: "Tester",
            senderAvatar: nil
        )
    }
}

@MainActor
private final class GroupChatMediaServiceStub: ChatRoomMediaServicing {
    private(set) var uploadedScopes: [ChatMediaScope] = []
    private(set) var deletedAssets: [ChatMediaAsset] = []
    private(set) var retainedAssets: [ChatMediaAsset] = []

    func loadImages(from items: [PhotosPickerItem]) async throws -> [UIImage] { [] }

    func uploadImage(
        _ image: UIImage,
        scope: ChatMediaScope,
        scopeID: UUID
    ) async throws -> ChatMediaAsset {
        uploadedScopes.append(scope)
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

private extension Message {
    static func historyFixture(
        conversationID: UUID,
        content: String,
        messageType: String = "text",
        createdAt: Date
    ) -> Message {
        Message(
            id: UUID(),
            conversationId: conversationID,
            senderId: UUID(),
            content: content,
            messageType: messageType,
            metadata: nil,
            isRead: true,
            createdAt: createdAt
        )
    }
}

private extension ChatGroupPreview {
    static func auditFixture() -> ChatGroupPreview {
        ChatGroupPreview(
            id: UUID(),
            name: "Study Group",
            avatarURL: nil,
            lastMessageAt: Date(),
            lastMessagePreview: nil,
            memberCount: 3
        )
    }
}

private extension GroupMessage {
    static func auditFixture(
        groupID: UUID,
        content: String,
        createdAt: Date
    ) -> GroupMessage {
        GroupMessage(
            id: UUID(),
            groupId: groupID,
            senderId: UUID(),
            content: content,
            messageType: "text",
            metadata: nil,
            isDeleted: false,
            createdAt: createdAt,
            senderName: "Tester",
            senderAvatar: nil
        )
    }
}
