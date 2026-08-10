//
//  ChatRoomServices.swift
//  CheeseApp
//
//  Side-effect boundaries used by the direct-message room.
//

import Foundation
import PhotosUI
import Supabase
import SwiftUI
import UIKit

@MainActor
protocol ChatRoomServicing: AnyObject {
    func conversationRemark(for conversationId: UUID) -> String?
    func displayName(for conversation: ChatConversationPreview) -> String
    func setConversationRemark(conversationId: UUID, remark: String?)
    func fetchDirectConversationSettings(conversationId: UUID) async -> DirectConversationSettings
    func setConversationMuted(conversationId: UUID, isMuted: Bool) async throws
    func clearConversationHistory(conversationId: UUID) async throws -> Date
    func deleteDirectMessage(messageId: UUID, forEveryone: Bool) async throws
    func fetchBlockRelation(with otherUserId: UUID) async -> UserBlockRelation
    func setUserBlocked(_ otherUserId: UUID, blocked: Bool) async throws
    func reportUser(
        reportedUserId: UUID,
        conversationId: UUID?,
        reason: String,
        details: String?
    ) async throws
}

extension ChatService: ChatRoomServicing {}

@MainActor
protocol SecondhandChatTransactionServicing: AnyObject {
    func fetchSecondhandPurchaseIntent(
        conversationId: UUID
    ) async throws -> SecondhandChatPurchaseIntent?
    func fetchSecondhandActiveBuyers(
        listingId: UUID
    ) async throws -> [SecondhandActiveBuyer]
    func cancelSecondhandPurchaseIntent(intentId: UUID) async throws
    func completeSecondhandSale(listingId: UUID, buyerId: UUID) async throws
    func stopSellingSecondhandListing(listingId: UUID) async throws
}

extension ChatService: SecondhandChatTransactionServicing {}

@MainActor
protocol ChatRoomMediaServicing {
    func loadImages(from items: [PhotosPickerItem]) async throws -> [UIImage]
    func uploadImage(
        _ image: UIImage,
        scope: ChatMediaScope,
        scopeID: UUID
    ) async throws -> ChatMediaAsset
    func deleteUploadedImage(_ asset: ChatMediaAsset) async
    func retainUploadedImage(_ asset: ChatMediaAsset) async
}

struct ChatMediaAsset: Hashable {
    let reference: ChatMediaReference
    let cleanupID: UUID

    var uploadedAsset: UploadedImageAsset {
        UploadedImageAsset(
            publicURL: "",
            bucket: reference.bucket,
            path: reference.objectPath
        )
    }
}

enum ChatMediaLoadError: Error, Equatable {
    case invalidReference
    case expiredSignedURL
    case invalidResponse
}

/// A signed URL is an in-memory transport detail only. Every load signs the
/// exact private object again, and a rejected/expired URL is refreshed once.
struct ChatMediaDataLoader {
    typealias SignURL = (ChatMediaReference, Int) async throws -> URL
    typealias Download = (URL) async throws -> Data

    static let signedURLLifetimeSeconds = 300

    let signURL: SignURL
    let download: Download

    func loadData(for reference: ChatMediaReference) async throws -> Data {
        guard reference.hasValidContract else {
            throw ChatMediaLoadError.invalidReference
        }

        for attempt in 0...1 {
            let url = try await signURL(
                reference,
                Self.signedURLLifetimeSeconds
            )
            do {
                return try await download(url)
            } catch ChatMediaLoadError.expiredSignedURL where attempt == 0 {
                continue
            }
        }
        throw ChatMediaLoadError.expiredSignedURL
    }

    static let live = ChatMediaDataLoader(
        signURL: { reference, expiresIn in
            try await SupabaseManager.shared
                .storage(reference.bucket)
                .createSignedURL(
                    path: reference.objectPath,
                    expiresIn: expiresIn
                )
        },
        download: { url in
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let session = URLSession(configuration: .ephemeral)
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ChatMediaLoadError.invalidResponse
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ChatMediaLoadError.expiredSignedURL
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ChatMediaLoadError.invalidResponse
            }
            return data
        }
    )
}

@MainActor
struct LiveChatRoomMediaService: ChatRoomMediaServicing {
    typealias CurrentUserID = () async throws -> UUID
    typealias UploadAsset = (UIImage, String, String) async throws -> UploadedImageAsset
    typealias DeleteAsset = (UploadedImageAsset) async throws -> Void
    typealias PrepareCleanup = (ChatMediaReference) async throws -> UUID
    typealias MarkCleanup = (UUID, Bool, String?) async throws -> Void
    typealias ResolveCleanup = (UUID) async throws -> Void

    private let currentUserID: CurrentUserID
    private let uploadAsset: UploadAsset
    private let deleteAsset: DeleteAsset
    private let prepareCleanup: PrepareCleanup
    private let markCleanup: MarkCleanup
    private let resolveCleanup: ResolveCleanup

    init(
        currentUserID: @escaping CurrentUserID = {
            try await AuthService.shared.requireAuthUserId()
        },
        uploadAsset: @escaping UploadAsset = { image, bucket, path in
            try await ImageUploadService.shared.uploadPrivateImageAsset(
                image,
                to: bucket,
                path: path
            )
        },
        deleteAsset: @escaping DeleteAsset = { asset in
            try await ImageUploadService.shared.deleteUploadedImageAsset(asset)
        },
        prepareCleanup: @escaping PrepareCleanup = { reference in
            try await SupabaseManager.shared.client.rpc(
                "prepare_chat_media_cleanup",
                params: PrepareChatMediaCleanupParams(reference: reference)
            ).execute().value
        },
        markCleanup: @escaping MarkCleanup = { cleanupID, succeeded, errorCode in
            try await SupabaseManager.shared.client.rpc(
                "mark_chat_media_cleanup_attempt",
                params: MarkChatMediaCleanupParams(
                    cleanupID: cleanupID,
                    succeeded: succeeded,
                    errorCode: errorCode
                )
            ).execute()
        },
        resolveCleanup: @escaping ResolveCleanup = { cleanupID in
            try await SupabaseManager.shared.client.rpc(
                "resolve_chat_media_cleanup",
                params: ResolveChatMediaCleanupParams(cleanupID: cleanupID)
            ).execute()
        }
    ) {
        self.currentUserID = currentUserID
        self.uploadAsset = uploadAsset
        self.deleteAsset = deleteAsset
        self.prepareCleanup = prepareCleanup
        self.markCleanup = markCleanup
        self.resolveCleanup = resolveCleanup
    }

    func loadImages(from items: [PhotosPickerItem]) async throws -> [UIImage] {
        var images: [UIImage] = []
        images.reserveCapacity(items.count)

        for item in items {
            try Task.checkCancellation()
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else { continue }
            images.append(image)
        }

        return images
    }

    func uploadImage(
        _ image: UIImage,
        scope: ChatMediaScope,
        scopeID: UUID
    ) async throws -> ChatMediaAsset {
        let userID = try await currentUserID()
        let objectPath = [
            scope.rawValue,
            scopeID.uuidString.lowercased(),
            userID.uuidString.lowercased(),
            "\(UUID().uuidString.lowercased()).jpg"
        ].joined(separator: "/")

        let reference = ChatMediaReference(
            bucket: StorageBuckets.chatImages,
            objectPath: objectPath,
            scope: scope,
            scopeID: scopeID
        )
        guard reference.hasValidContract else {
            throw ChatMediaLoadError.invalidReference
        }

        // The durable obligation is committed before Storage receives bytes.
        // A crash or timeout therefore leaves an observable exact path for the
        // independent cleanup worker instead of an orphan.
        let cleanupID = try await prepareCleanup(reference)
        var uploadedAsset = ChatMediaAsset(
            reference: reference,
            cleanupID: cleanupID
        ).uploadedAsset

        do {
            let uploaded = try await uploadAsset(
                image,
                StorageBuckets.chatImages,
                objectPath
            )
            uploadedAsset = uploaded
            guard uploaded.bucket == reference.bucket,
                  uploaded.path == reference.objectPath
            else { throw ChatMediaLoadError.invalidReference }
            return ChatMediaAsset(reference: reference, cleanupID: cleanupID)
        } catch {
            await compensateFailedUpload(
                cleanupID: cleanupID,
                uploadedAsset: uploadedAsset
            )
            throw error
        }
    }

    func deleteUploadedImage(_ asset: ChatMediaAsset) async {
        do {
            try await deleteAsset(asset.uploadedAsset)
            try? await markCleanup(asset.cleanupID, true, nil)
        } catch {
            try? await markCleanup(
                asset.cleanupID,
                false,
                Self.cleanupErrorCode(error)
            )
        }
    }

    func retainUploadedImage(_ asset: ChatMediaAsset) async {
        // If this acknowledgement is interrupted, the worker rechecks active
        // message references before deleting and resolves the obligation.
        try? await resolveCleanup(asset.cleanupID)
    }

    private func compensateFailedUpload(
        cleanupID: UUID,
        uploadedAsset: UploadedImageAsset
    ) async {
        do {
            try await deleteAsset(uploadedAsset)
            try? await markCleanup(cleanupID, true, nil)
        } catch {
            try? await markCleanup(
                cleanupID,
                false,
                Self.cleanupErrorCode(error)
            )
        }
    }

    private static func cleanupErrorCode(_ error: Error) -> String {
        let code = (error as NSError).code
        return "storage_delete:\(code)"
    }
}

private struct PrepareChatMediaCleanupParams: Encodable {
    let scope: String
    let scopeID: UUID
    let objectPath: String
    let reason = "upload_reserved"

    init(reference: ChatMediaReference) {
        scope = reference.scope.rawValue
        scopeID = reference.scopeID
        objectPath = reference.objectPath
    }

    enum CodingKeys: String, CodingKey {
        case scope = "p_scope"
        case scopeID = "p_scope_id"
        case objectPath = "p_object_path"
        case reason = "p_reason"
    }
}

private struct MarkChatMediaCleanupParams: Encodable {
    let cleanupID: UUID
    let succeeded: Bool
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case cleanupID = "p_cleanup_id"
        case succeeded = "p_succeeded"
        case errorCode = "p_error_code"
    }
}

private struct ResolveChatMediaCleanupParams: Encodable {
    let cleanupID: UUID
    let resolution = "retained_by_message"

    enum CodingKeys: String, CodingKey {
        case cleanupID = "p_cleanup_id"
        case resolution = "p_resolution"
    }
}

protocol ChatStrangerSafetyStoring {
    func hasAcknowledged(userID: UUID, conversationID: UUID) -> Bool
    func acknowledge(userID: UUID, conversationID: UUID)
}

struct UserDefaultsChatStrangerSafetyStore: ChatStrangerSafetyStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasAcknowledged(userID: UUID, conversationID: UUID) -> Bool {
        defaults.bool(forKey: storageKey(userID: userID, conversationID: conversationID))
    }

    func acknowledge(userID: UUID, conversationID: UUID) {
        defaults.set(
            true,
            forKey: storageKey(userID: userID, conversationID: conversationID)
        )
    }

    private func storageKey(userID: UUID, conversationID: UUID) -> String {
        "chat.strangerSafetyAcknowledged.\(userID.uuidString).\(conversationID.uuidString)"
    }
}
