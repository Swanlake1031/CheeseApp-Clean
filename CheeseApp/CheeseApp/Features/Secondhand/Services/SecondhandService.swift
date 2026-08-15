//
//  SecondhandService.swift
//  CheeseApp
//
//  🛍️ 二手交易服务
//  处理二手商品的 CRUD 操作
//

import Foundation
import Supabase
import UIKit

// MARK: - UI 二手商品模型
struct SecondhandItem: Identifiable, Hashable {
    let id: UUID
    let sellerId: UUID
    let title: String
    let price: Double
    var originalPrice: Double? = nil
    let isNegotiable: Bool
    let category: SecondhandPost.Category
    let condition: String
    let seller: String
    let sellerAvatar: String?
    let isAnonymous: Bool
    let hasSellerProfile: Bool
    var isSellerMcMasterVerified: Bool = false
    let description: String
    let timeAgo: String
    let imageUrl: String?
    let imageUrls: [String]
    var likeCount: Int
    var isLiked: Bool
    var isFavorited: Bool
    var isSold: Bool = false

    static func == (lhs: SecondhandItem, rhs: SecondhandItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var displayImageUrls: [String] {
        if !imageUrls.isEmpty {
            return imageUrls
        }
        return imageUrl.map { [$0] } ?? []
    }
}

struct SecondhandCreateInput {
    let postId: UUID
    let userId: UUID
    let schoolId: UUID
    let title: String
    let description: String
    let isAnonymous: Bool
    let price: Double
    var originalPrice: Double? = nil
    let category: SecondhandPost.Category
    let condition: SecondhandPost.Condition
    let isNegotiable: Bool
    var mentionedUserIDs: [UUID] = []
}

struct SecondhandEditableFields {
    let category: SecondhandPost.Category
    let originalPrice: Double?
    let condition: String
    let isNegotiable: Bool
    let images: [EditablePostImage]

    init(
        category: SecondhandPost.Category = .other,
        originalPrice: Double? = nil,
        condition: String,
        isNegotiable: Bool,
        images: [EditablePostImage] = []
    ) {
        self.category = category
        self.originalPrice = originalPrice
        self.condition = condition
        self.isNegotiable = isNegotiable
        self.images = images
    }
}

enum SecondhandCreatePostError: LocalizedError {
    case publicationOutcomeUnknown(originalError: Error)

    var errorDescription: String? {
        Self.userFacingMessage
    }

    static let userFacingMessage = L10n.tr(
        "Unable to publish this item. Please try again.",
        "发布失败，请稍后重试。"
    )

    static let imageUploadUserFacingMessage = L10n.tr(
        "The image upload failed, so the item was not published. Please try again.",
        "图片上传失败，商品未发布，请重试。"
    )

    static func userFacingMessage(for error: Error) -> String {
        userFacingMessage
    }
}

struct SecondhandPublishingOperations {
    let isAlreadyPublished: (UUID) async throws -> Bool
    let prepare: (UUID, UUID, [PostImageUploadPlan]) async throws -> Void
    let upload: (UIImage, PostImageUploadPlan) async throws -> UploadedImageAsset
    let markUploaded: (UUID, Int) async throws -> Void
    let finalize: (SecondhandCreateInput, UUID) async throws -> UUID
    let abandon: (UUID, String) async throws -> [PostMediaCleanupItem]
    let deleteObject: (UploadedImageAsset) async throws -> Void
    let markCleanup: (UUID, Bool, String?) async throws -> Void
}

struct SecondhandDetailInsert: Encodable {
    let id: String
    let price: Double
    let original_price: Double?
    let category: String
    let condition: String
    let is_negotiable: Bool
    let is_free: Bool
    let can_ship: Bool
    let quantity: Int
    let expires_at: String?
}

struct SecondhandPublishingWorkflow {
    let operations: SecondhandPublishingOperations

    func publish(
        input: SecondhandCreateInput,
        images: [UIImage],
        plans: [PostImageUploadPlan]
    ) async throws -> UUID {
        if try await operations.isAlreadyPublished(input.postId) {
            return input.postId
        }

        let operationID = input.postId
        try await operations.prepare(operationID, input.postId, plans)

        do {
            for (image, plan) in zip(images, plans) {
                _ = try await operations.upload(image, plan)
                try await operations.markUploaded(operationID, plan.orderIndex)
            }
            return try await operations.finalize(input, operationID)
        } catch let publicationError {
            do {
                if try await operations.isAlreadyPublished(input.postId) {
                    return input.postId
                }
            } catch {
                // Exact planned paths remain durably staged while the commit
                // outcome is unknown. Deleting them here could break a post
                // that actually committed.
                throw SecondhandCreatePostError.publicationOutcomeUnknown(
                    originalError: publicationError
                )
            }

            let cleanupItems = (try? await operations.abandon(
                operationID,
                "publication_failed"
            )) ?? []
            if cleanupItems.isEmpty {
                for plan in plans {
                    try? await operations.deleteObject(plan.uploadedAsset)
                }
            } else {
                await clean(cleanupItems)
            }
            throw publicationError
        }
    }

    private func clean(_ items: [PostMediaCleanupItem]) async {
        for item in items where item.status == "pending" {
            guard let asset = item.uploadedAsset else { continue }
            do {
                try await operations.deleteObject(asset)
                try? await operations.markCleanup(item.id, true, nil)
            } catch {
                try? await operations.markCleanup(
                    item.id,
                    false,
                    Self.cleanupErrorCode(error)
                )
            }
        }
    }

    static func cleanupErrorCode(_ error: Error) -> String {
        let nsError = error as NSError
        let domain = nsError.domain
            .replacingOccurrences(
                of: "[^A-Za-z0-9_.:-]",
                with: "_",
                options: .regularExpression
            )
        return String("\(domain):\(nsError.code)".prefix(120))
    }
}

// MARK: - 二手服务
@MainActor
class SecondhandService: ObservableObject {

    static let shared = SecondhandService()

    private let supabase = SupabaseManager.shared

    @Published var items: [SecondhandItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var hasResolvedInitialItemLoad = false
    @Published private(set) var mediaCleanupBacklogCount = 0
    @Published private(set) var mediaCleanupWarning: String?
    @Published private(set) var isLoadingNextPage = false
    @Published private(set) var hasMoreItems = true
    @Published private(set) var pageErrorMessage: String?
    @Published private(set) var accountGeneration: UInt64 = 0
    @Published private(set) var isAccountTransitionInProgress = false
    private var itemCursor: SecondhandPageCursor?
    private var latestItemFetchID: UUID?
    private var stateOwnerID: UUID?
    private static let pageSize = 24

    private init() {}

    var isAccountScopeReady: Bool {
        !isAccountTransitionInProgress && stateOwnerID != nil
    }

    func beginAccountTransition() {
        isAccountTransitionInProgress = true
        resetAccountScopedState(ownerID: nil)
    }

    func activateAccount(_ userID: UUID?) {
        let mustReset = isAccountTransitionInProgress || stateOwnerID != userID
        isAccountTransitionInProgress = false
        guard mustReset else { return }
        resetAccountScopedState(ownerID: userID)
    }

    private func resetAccountScopedState(ownerID: UUID?) {
        accountGeneration &+= 1
        stateOwnerID = ownerID
        itemCursor = nil
        latestItemFetchID = nil
        items = []
        isLoading = false
        errorMessage = nil
        hasResolvedInitialItemLoad = false
        mediaCleanupBacklogCount = 0
        mediaCleanupWarning = nil
        isLoadingNextPage = false
        hasMoreItems = true
        pageErrorMessage = nil
    }

    func isCurrentAccountRequest(generation: UInt64) -> Bool {
        !isAccountTransitionInProgress
            && stateOwnerID != nil
            && accountGeneration == generation
    }

    private func requestGeneration() -> UInt64? {
        guard isAccountScopeReady else { return nil }
        return accountGeneration
    }

    var itemListState: CollectionLoadState {
        CollectionLoadState.resolve(
            hasResolvedInitialLoad: hasResolvedInitialItemLoad,
            isLoading: isLoading,
            hasContent: !items.isEmpty,
            errorMessage: errorMessage
        )
    }

    func publishPost(
        input: SecondhandCreateInput,
        images: [UIImage]
    ) async throws -> UUID {
        guard !images.isEmpty else {
            throw NSError(
                domain: "SecondhandPublishing",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "At least one image is required."]
            )
        }

        let actingUserID = try await AuthService.shared.requireAuthUserId()
        guard input.userId == actingUserID else {
            throw NSError(
                domain: "SecondhandPublishing",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Authenticated user changed before publication."]
            )
        }

        let plans = try ImageUploadService.shared.makePostImageUploadPlans(
            imageCount: images.count,
            userID: actingUserID,
            postID: input.postId,
            operationID: input.postId
        )
        let publishedID = try await SecondhandPublishingWorkflow(
            operations: livePublishingOperations()
        ).publish(
            input: input,
            images: images,
            plans: plans
        )

        await retryPendingMediaCleanup(postID: publishedID)
        return publishedID
    }

    static func makeDetailInsert(input: SecondhandCreateInput) -> SecondhandDetailInsert {
        SecondhandDetailInsert(
            id: input.postId.uuidString,
            price: input.price,
            original_price: input.originalPrice,
            category: input.category.rawValue,
            condition: input.condition.rawValue,
            is_negotiable: input.isNegotiable,
            is_free: false,
            can_ship: false,
            quantity: 1,
            expires_at: nil
        )
    }

    func updatePost(payload: EditableUserPostPayload) async throws {
        let trimmedTitle = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.kind == .secondhand,
              let details = payload.secondhandDetails,
              !trimmedTitle.isEmpty
        else {
            throw NSError(domain: "", code: 400, userInfo: [NSLocalizedDescriptionKey: "标题不能为空"])
        }
        guard let price = payload.price, price >= 0 else {
            throw NSError(domain: "", code: 400, userInfo: [NSLocalizedDescriptionKey: "请填写价格"])
        }

        let actingUserID = try await AuthService.shared.requireAuthUserId()
        let operationID = UUID()
        let plans = try ImageUploadService.shared.makePostImageUploadPlans(
            imageCount: payload.newImages.count,
            userID: actingUserID,
            postID: payload.id,
            operationID: operationID
        )
        try await prepareMediaOperation(
            operationID: operationID,
            postID: payload.id,
            plans: plans
        )

        do {
            for (image, plan) in zip(payload.newImages, plans) {
                _ = try await ImageUploadService.shared.uploadPostImage(
                    image,
                    plan: plan
                )
                try await markMediaUploaded(
                    operationID: operationID,
                    orderIndex: plan.orderIndex
                )
            }

            try await supabase.client.rpc(
                "update_secondhand_post_with_media",
                params: SecondhandPostWithMediaUpdateParams(
                    postID: payload.id,
                    operationID: operationID,
                    title: trimmedTitle,
                    description: payload.description,
                    isPrivate: payload.isPrivate,
                    price: price,
                    originalPrice: details.originalPrice,
                    category: details.category.rawValue,
                    condition: SecondhandPost.Condition(
                        normalizing: details.condition
                    ).rawValue,
                    isNegotiable: details.isNegotiable,
                    keepImageIDs: payload.retainedImageIDs
                )
            ).execute()
        } catch {
            if !plans.isEmpty,
               (try? await mediaOperationIsFinalized(
                operationID: operationID,
                expectedCount: plans.count
               )) == true {
                await retryPendingMediaCleanup(postID: payload.id)
                return
            }

            if !plans.isEmpty {
                let cleanupItems = (try? await abandonMediaOperation(
                    operationID: operationID,
                    reason: "publication_failed"
                )) ?? []
                await performMediaCleanup(cleanupItems)
            }
            throw error
        }

        await retryPendingMediaCleanup(postID: payload.id)
        await fetchItems()
    }

    static func makeDetailUpdate(
        price: Double,
        details: SecondhandEditableFields
    ) -> SecondhandPostEditUpdate {
        SecondhandPostEditUpdate(
            price: price,
            originalPrice: details.originalPrice,
            category: details.category.rawValue,
            condition: SecondhandPost.Condition(normalizing: details.condition).rawValue,
            isNegotiable: details.isNegotiable
        )
    }

    func fetchEditFields(postId: UUID) async throws -> SecondhandEditableFields {
        _ = try await AuthService.shared.requireAuthUserId()
        let row: ProfilePostContractRow = try await supabase.client
            .rpc(
                "get_my_post_edit_contract",
                params: MyPostEditContractParams(postID: postId)
            )
            .single()
            .execute()
            .value

        return SecondhandEditableFields(
            category: SecondhandPost.Category(normalizing: row.category ?? "other"),
            originalPrice: row.originalPrice,
            condition: row.condition ?? SecondhandPost.Condition.good.rawValue,
            isNegotiable: row.isNegotiable ?? false,
            images: row.images.sorted {
                ($0.orderIndex ?? Int.max) < ($1.orderIndex ?? Int.max)
            }
        )
    }

    func deletePost(postId: UUID, authorId: UUID) async throws {
        try await supabase.client.rpc(
            "delete_secondhand_post_with_media",
            params: SecondhandPostIDParams(postID: postId)
        ).execute()

        items.removeAll { $0.id == postId }
        await retryPendingMediaCleanup(postID: postId)
        PostFeatureEvents.postDidChange(kind: .secondhand, authorId: authorId)
    }

    func retryPendingMediaCleanup(postID: UUID? = nil) async {
        guard let requestGeneration = requestGeneration() else { return }
        do {
            let items = try await fetchMediaCleanupBacklog(postID: postID)
            await performMediaCleanup(items)
            let remaining = try await fetchMediaCleanupBacklog(postID: postID)
            guard isCurrentAccountRequest(generation: requestGeneration) else { return }
            mediaCleanupBacklogCount = remaining.count
            mediaCleanupWarning = remaining.isEmpty
                ? nil
                : L10n.tr(
                    "Some marketplace image cleanup is queued for retry.",
                    "部分二手商品图片仍在等待清理重试。"
                )
        } catch {
            guard isCurrentAccountRequest(generation: requestGeneration) else { return }
            mediaCleanupWarning = L10n.tr(
                "Marketplace image cleanup status is temporarily unavailable.",
                "暂时无法读取二手商品图片清理状态。"
            )
        }
    }

    private func livePublishingOperations() -> SecondhandPublishingOperations {
        SecondhandPublishingOperations(
            isAlreadyPublished: { [weak self] postID in
                guard let self else { return false }
                return try await self.isSecondhandPostPublished(postID: postID)
            },
            prepare: { [weak self] operationID, postID, plans in
                guard let self else { throw CancellationError() }
                try await self.prepareMediaOperation(
                    operationID: operationID,
                    postID: postID,
                    plans: plans
                )
            },
            upload: { image, plan in
                try await ImageUploadService.shared.uploadPostImage(
                    image,
                    plan: plan
                )
            },
            markUploaded: { [weak self] operationID, orderIndex in
                guard let self else { throw CancellationError() }
                try await self.markMediaUploaded(
                    operationID: operationID,
                    orderIndex: orderIndex
                )
            },
            finalize: { [weak self] input, operationID in
                guard let self else { throw CancellationError() }
                return try await self.finalizePublication(
                    input: input,
                    operationID: operationID
                )
            },
            abandon: { [weak self] operationID, reason in
                guard let self else { throw CancellationError() }
                return try await self.abandonMediaOperation(
                    operationID: operationID,
                    reason: reason
                )
            },
            deleteObject: { asset in
                try await ImageUploadService.shared.deleteUploadedImageAsset(asset)
            },
            markCleanup: { [weak self] cleanupID, succeeded, errorCode in
                guard let self else { throw CancellationError() }
                try await self.markMediaCleanup(
                    cleanupID: cleanupID,
                    succeeded: succeeded,
                    errorCode: errorCode
                )
            }
        )
    }

    private func isSecondhandPostPublished(postID: UUID) async throws -> Bool {
        let rows: [SecondhandPublishStatusRow] = try await supabase.client.rpc(
            "get_secondhand_publish_status",
            params: SecondhandPostIDParams(postID: postID)
        ).execute().value
        return rows.first?.isComplete == true
    }

    private func prepareMediaOperation(
        operationID: UUID,
        postID: UUID,
        plans: [PostImageUploadPlan]
    ) async throws {
        let rows: [SecondhandPreparedMediaRow] = try await supabase.client.rpc(
            "prepare_post_media_operation",
            params: SecondhandPrepareMediaParams(
                operationID: operationID,
                postID: postID,
                postType: PostKind.secondhand.rawValue,
                media: plans
            )
        ).execute().value

        guard rows.count == plans.count else {
            throw NSError(
                domain: "SecondhandPublishing",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "Unable to prepare all selected images."]
            )
        }
    }

    private func markMediaUploaded(
        operationID: UUID,
        orderIndex: Int
    ) async throws {
        try await supabase.client.rpc(
            "mark_post_media_uploaded",
            params: SecondhandMarkMediaUploadedParams(
                operationID: operationID,
                orderIndex: orderIndex
            )
        ).execute()
    }

    private func finalizePublication(
        input: SecondhandCreateInput,
        operationID: UUID
    ) async throws -> UUID {
        try await supabase.client.rpc(
            "publish_secondhand_post_with_mentions",
            params: PublishSecondhandPostParams(
                postID: input.postId,
                operationID: operationID,
                title: input.title,
                description: input.description,
                isAnonymous: input.isAnonymous,
                isPrivate: false,
                price: input.price,
                originalPrice: input.originalPrice,
                category: input.category.rawValue,
                condition: input.condition.rawValue,
                isNegotiable: input.isNegotiable,
                mentionedUserIDs: input.mentionedUserIDs
            )
        ).execute().value
    }

    private func abandonMediaOperation(
        operationID: UUID,
        reason: String
    ) async throws -> [PostMediaCleanupItem] {
        try await supabase.client.rpc(
            "abandon_post_media_operation",
            params: SecondhandAbandonMediaParams(
                operationID: operationID,
                reason: reason
            )
        ).execute().value
    }

    private func fetchMediaCleanupBacklog(
        postID: UUID?
    ) async throws -> [PostMediaCleanupItem] {
        try await supabase.client.rpc(
            "get_my_post_media_cleanup_backlog",
            params: SecondhandCleanupBacklogParams(postID: postID)
        ).execute().value
    }

    private func markMediaCleanup(
        cleanupID: UUID,
        succeeded: Bool,
        errorCode: String?
    ) async throws {
        try await supabase.client.rpc(
            "mark_post_media_cleanup_attempt",
            params: SecondhandMarkCleanupParams(
                cleanupID: cleanupID,
                succeeded: succeeded,
                errorCode: errorCode
            )
        ).execute()
    }

    private func performMediaCleanup(_ items: [PostMediaCleanupItem]) async {
        for item in items where item.status == "pending" {
            guard let asset = item.uploadedAsset else { continue }
            do {
                try await ImageUploadService.shared.deleteUploadedImageAsset(asset)
                try? await markMediaCleanup(
                    cleanupID: item.id,
                    succeeded: true,
                    errorCode: nil
                )
            } catch {
                try? await markMediaCleanup(
                    cleanupID: item.id,
                    succeeded: false,
                    errorCode: SecondhandPublishingWorkflow.cleanupErrorCode(error)
                )
            }
        }
    }

    private func mediaOperationIsFinalized(
        operationID: UUID,
        expectedCount: Int
    ) async throws -> Bool {
        let rows: [SecondhandMediaStageStatusRow] = try await supabase
            .database("post_media_staging")
            .select("status")
            .eq("operation_id", value: operationID.uuidString)
            .execute()
            .value
        return rows.count == expectedCount && rows.allSatisfy { $0.status == "finalized" }
    }

    // MARK: - 获取所有二手商品
    func fetchItems() async {
        guard let requestGeneration = requestGeneration() else { return }
        let fetchID = UUID()
        latestItemFetchID = fetchID
        isLoading = true
        errorMessage = nil
        pageErrorMessage = nil

        defer {
            if isCurrentAccountRequest(generation: requestGeneration),
               latestItemFetchID == fetchID {
                isLoading = false
            }
        }

        do {
            let dbPosts = try await fetchItemPage(after: nil)
            guard isCurrentAccountRequest(generation: requestGeneration),
                  latestItemFetchID == fetchID
            else { return }
            prefetchPreviewImages(from: dbPosts)
            let favoritePostIds = await PostFavoriteService.shared.fetchFavoritePostIds(
                postIds: dbPosts.map(\.id)
            )
            guard isCurrentAccountRequest(generation: requestGeneration),
                  latestItemFetchID == fetchID
            else { return }
            let refreshedItems = dbPosts.map {
                convertToUIModel($0, isFavorited: favoritePostIds.contains($0.id))
            }
            seedInteractionStates(for: refreshedItems)
            items = refreshedItems
            itemCursor = dbPosts.last.map {
                SecondhandPageCursor(createdAt: $0.createdAt, id: $0.id)
            }
            hasMoreItems = dbPosts.count == Self.pageSize
            hasResolvedInitialItemLoad = true
        } catch {
            guard isCurrentAccountRequest(generation: requestGeneration),
                  latestItemFetchID == fetchID
            else { return }
            if error.isCancellationLike {
                return
            }
            errorMessage = "加载失败: \(error.localizedDescription)"
            hasResolvedInitialItemLoad = true
        }
    }

    func loadNextItemPage() async {
        guard hasMoreItems, !isLoading, !isLoadingNextPage else { return }
        guard let requestGeneration = requestGeneration() else { return }
        let expectedFetchID = latestItemFetchID
        let cursor = itemCursor
        isLoadingNextPage = true
        pageErrorMessage = nil
        defer {
            if isCurrentAccountRequest(generation: requestGeneration),
               latestItemFetchID == expectedFetchID {
                isLoadingNextPage = false
            }
        }

        do {
            let dbPosts = try await fetchItemPage(after: cursor)
            guard isCurrentAccountRequest(generation: requestGeneration),
                  latestItemFetchID == expectedFetchID
            else { return }
            prefetchPreviewImages(from: dbPosts, limit: 8)
            let favoritePostIds = await PostFavoriteService.shared.fetchFavoritePostIds(
                postIds: dbPosts.map(\.id)
            )
            guard isCurrentAccountRequest(generation: requestGeneration),
                  latestItemFetchID == expectedFetchID
            else { return }
            let existingIDs = Set(items.map(\.id))
            let newItems: [SecondhandItem] = dbPosts.compactMap { post in
                guard !existingIDs.contains(post.id) else { return nil }
                return convertToUIModel(
                    post,
                    isFavorited: favoritePostIds.contains(post.id)
                )
            }
            seedInteractionStates(for: newItems)
            items.append(contentsOf: newItems)
            itemCursor = dbPosts.last.map {
                SecondhandPageCursor(createdAt: $0.createdAt, id: $0.id)
            } ?? itemCursor
            hasMoreItems = dbPosts.count == Self.pageSize
        } catch {
            guard isCurrentAccountRequest(generation: requestGeneration),
                  latestItemFetchID == expectedFetchID
            else { return }
            if !error.isCancellationLike {
                pageErrorMessage = L10n.tr(
                    "Unable to load more items. Tap to retry.",
                    "加载更多商品失败，点击重试。"
                )
            }
        }
    }

    private func fetchItemPage(
        after cursor: SecondhandPageCursor?
    ) async throws -> [DBSecondhandPost] {
        try await supabase.client.rpc(
            "get_secondhand_posts_page",
            params: SecondhandPageParams(
                afterCreatedAt: cursor?.createdAt,
                afterID: cursor?.id,
                limit: Self.pageSize
            )
        ).execute().value
    }

    func fetchItem(postId: UUID) async throws -> SecondhandItem {
        let dbPost: DBSecondhandPost = try await supabase.client
            .rpc(
                "get_secondhand_post_detail",
                params: SecondhandPostIDParams(postID: postId)
            )
            .single()
            .execute()
            .value

        let favoritePostIds = await PostFavoriteService.shared.fetchFavoritePostIds(postIds: [dbPost.id])
        let item = convertToUIModel(
            dbPost,
            isFavorited: favoritePostIds.contains(dbPost.id)
        )
        seedInteractionStates(for: [item])
        return item
    }

    /// Loads complete detail models for visible cards in one request so callers
    /// can navigate immediately without refetching a tapped item by ID.
    func fetchItems(postIDs: [UUID]) async throws -> [SecondhandItem] {
        let uniqueIDs = Array(Set(postIDs))
        guard !uniqueIDs.isEmpty else { return [] }

        let dbPosts: [DBSecondhandPost] = try await supabase
            .database("secondhand_posts_view")
            .select()
            .in("id", values: uniqueIDs.map(\.uuidString))
            .execute()
            .value
        return await resolveItems(from: dbPosts)
    }

    func resolveItems(
        from dbPosts: [DBSecondhandPost],
        seedInteractions: Bool = true
    ) async -> [SecondhandItem] {
        prefetchPreviewImages(from: dbPosts)

        let favoritePostIDs = await PostFavoriteService.shared.fetchFavoritePostIds(
            postIds: dbPosts.map(\.id)
        )

        let resolvedItems = dbPosts.map {
            convertToUIModel(
                $0,
                isFavorited: favoritePostIDs.contains($0.id)
            )
        }
        if seedInteractions {
            seedInteractionStates(for: resolvedItems)
        }
        return resolvedItems
    }

    private func prefetchPreviewImages(
        from dbPosts: [DBSecondhandPost],
        limit: Int = 12
    ) {
        let urls = dbPosts.compactMap { post -> URL? in
            guard let imageURLString = post.images?
                .min(by: { ($0.orderIndex ?? Int.max) < ($1.orderIndex ?? Int.max) })?
                .url,
                  let originalURL = URL(string: imageURLString)
            else { return nil }
            return originalURL
        }

        RemoteImageCache.shared.prefetch(
            urls,
            maxPixelSize: 640,
            limit: limit
        )
    }

    func recordView(postId: UUID) async {
        do {
            try await supabase.client
                .rpc(
                    "record_post_view",
                    params: SecondhandPostIDParams(postID: postId)
                )
                .execute()
        } catch {
            if error.isCancellationLike { return }
        }
    }

    func toggleFavorite(postId: UUID, currentlyFavorited: Bool) async throws -> Bool {
        let isFavorited = try await PostFavoriteService.shared.toggleFavorite(
            postId: postId,
            currentlyFavorited: currentlyFavorited,
            unauthorizedMessage: L10n.tr("Please sign in before saving posts", "收藏前请先登录")
        )
        updateFavoriteState(postId: postId, isFavorited: isFavorited)
        return isFavorited
    }

    // MARK: - 转换模型
    private func convertToUIModel(
        _ dbPost: DBSecondhandPost,
        isFavorited: Bool
    ) -> SecondhandItem {
        let category = SecondhandPost.Category(normalizing: dbPost.category)
        let orderedImageURLs = (dbPost.images ?? [])
            .sorted { ($0.orderIndex ?? Int.max) < ($1.orderIndex ?? Int.max) }
            .map(\.url)

        let item = SecondhandItem(
            id: dbPost.id,
            sellerId: dbPost.userId,
            title: dbPost.title,
            price: dbPost.price,
            originalPrice: dbPost.originalPrice,
            isNegotiable: dbPost.isNegotiable,
            category: category,
            condition: SecondhandPost.Condition.displayName(for: dbPost.condition),
            seller: Self.sellerDisplayName(
                isAnonymous: dbPost.isAnonymous,
                rawName: dbPost.userName
            ),
            sellerAvatar: dbPost.isAnonymous ? nil : dbPost.userAvatar,
            isAnonymous: dbPost.isAnonymous,
            hasSellerProfile: !dbPost.isAnonymous && Self.hasUsableSellerName(dbPost.userName),
            isSellerMcMasterVerified: !dbPost.isAnonymous && dbPost.userMcMasterVerified == true,
            description: dbPost.description ?? "",
            timeAgo: Formatters.formatCompactTimeAgo(dbPost.createdAt),
            imageUrl: orderedImageURLs.first,
            imageUrls: orderedImageURLs,
            likeCount: 0,
            isLiked: false,
            isFavorited: isFavorited,
            isSold: Self.isSold(quantity: dbPost.quantity, soldCount: dbPost.soldCount)
        )
        return item
    }

    private func seedInteractionStates(for items: [SecondhandItem]) {
        PostInteractionStore.shared.merge(items.map {
            PostInteractionStore.Update(
                postID: $0.id,
                likeCount: 0,
                isLiked: false,
                isFavorited: $0.isFavorited
            )
        })
    }

    private func updateFavoriteState(postId: UUID, isFavorited: Bool) {
        guard let index = items.firstIndex(where: { $0.id == postId }) else { return }
        items[index].isFavorited = isFavorited
    }

    private static func hasUsableSellerName(_ name: String?) -> Bool {
        guard let name else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func sellerDisplayName(
        isAnonymous: Bool,
        rawName: String?
    ) -> String {
        if isAnonymous {
            return L10n.tr("Anonymous seller", "匿名卖家")
        }
        guard let rawName,
              !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return L10n.tr("Unavailable user", "用户资料不可用")
        }
        return rawName
    }

    static func isSold(quantity: Int?, soldCount: Int?) -> Bool {
        (quantity ?? 1) <= (soldCount ?? 0)
    }
}

// MARK: - 数据库二手帖子模型（secondhand_posts_view）
struct DBSecondhandPost: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    let title: String
    let description: String?
    let category: String
    let condition: String
    let price: Double
    let originalPrice: Double?
    let isNegotiable: Bool
    let quantity: Int?
    let soldCount: Int?
    let createdAt: Date
    let userName: String?
    let userAvatar: String?
    var userMcMasterVerified: Bool? = nil
    let isAnonymous: Bool
    let images: [DBSecondhandImage]?
    let likeCount: Int?
    let viewCount: Int?
    var saveCount: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case description
        case category
        case condition
        case price
        case originalPrice = "original_price"
        case isNegotiable = "is_negotiable"
        case quantity
        case soldCount = "sold_count"
        case createdAt = "created_at"
        case userName = "user_name"
        case userAvatar = "user_avatar"
        case userMcMasterVerified = "user_mcmaster_verified"
        case isAnonymous = "is_anonymous"
        case images
        case likeCount = "like_count"
        case viewCount = "view_count"
        case saveCount = "save_count"
    }
}

struct DBSecondhandImage: Codable {
    let url: String
    let orderIndex: Int?

    enum CodingKeys: String, CodingKey {
        case url
        case orderIndex = "order_index"
    }
}

struct SecondhandPostEditUpdate: Encodable {
    let price: Double
    let originalPrice: Double?
    let category: String
    let condition: String
    let isNegotiable: Bool

    enum CodingKeys: String, CodingKey {
        case price
        case originalPrice = "original_price"
        case category
        case condition
        case isNegotiable = "is_negotiable"
    }
}

private struct SecondhandPreparedMediaRow: Decodable {
    let id: UUID
    let status: String
}

private struct SecondhandMediaStageStatusRow: Decodable {
    let status: String
}

private struct SecondhandPublishStatusRow: Decodable {
    let postID: UUID
    let isComplete: Bool

    enum CodingKeys: String, CodingKey {
        case postID = "post_id"
        case isComplete = "is_complete"
    }
}

private struct SecondhandPrepareMediaParams: Encodable {
    let operationID: UUID
    let postID: UUID
    let postType: String
    let media: [PostImageUploadPlan]

    enum CodingKeys: String, CodingKey {
        case operationID = "p_operation_id"
        case postID = "p_post_id"
        case postType = "p_post_type"
        case media = "p_media"
    }
}

private struct SecondhandMarkMediaUploadedParams: Encodable {
    let operationID: UUID
    let orderIndex: Int

    enum CodingKeys: String, CodingKey {
        case operationID = "p_operation_id"
        case orderIndex = "p_order_index"
    }
}

private struct PublishSecondhandPostParams: Encodable {
    let postID: UUID
    let operationID: UUID
    let title: String
    let description: String
    let isAnonymous: Bool
    let isPrivate: Bool
    let price: Double
    let originalPrice: Double?
    let category: String
    let condition: String
    let isNegotiable: Bool
    let mentionedUserIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case postID = "p_post_id"
        case operationID = "p_operation_id"
        case title = "p_title"
        case description = "p_description"
        case isAnonymous = "p_is_anonymous"
        case isPrivate = "p_is_private"
        case price = "p_price"
        case originalPrice = "p_original_price"
        case category = "p_category"
        case condition = "p_condition"
        case isNegotiable = "p_is_negotiable"
        case mentionedUserIDs = "p_mentioned_user_ids"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(postID, forKey: .postID)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(isAnonymous, forKey: .isAnonymous)
        try container.encode(isPrivate, forKey: .isPrivate)
        try container.encode(price, forKey: .price)
        if let originalPrice {
            try container.encode(originalPrice, forKey: .originalPrice)
        } else {
            try container.encodeNil(forKey: .originalPrice)
        }
        try container.encode(category, forKey: .category)
        try container.encode(condition, forKey: .condition)
        try container.encode(isNegotiable, forKey: .isNegotiable)
        try container.encode(mentionedUserIDs, forKey: .mentionedUserIDs)
    }
}

private struct SecondhandPostWithMediaUpdateParams: Encodable {
    let postID: UUID
    let operationID: UUID
    let title: String
    let description: String
    let isPrivate: Bool
    let price: Double
    let originalPrice: Double?
    let category: String
    let condition: String
    let isNegotiable: Bool
    let keepImageIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case postID = "p_post_id"
        case operationID = "p_operation_id"
        case title = "p_title"
        case description = "p_description"
        case isPrivate = "p_is_private"
        case price = "p_price"
        case originalPrice = "p_original_price"
        case category = "p_category"
        case condition = "p_condition"
        case isNegotiable = "p_is_negotiable"
        case keepImageIDs = "p_keep_image_ids"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(postID, forKey: .postID)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(isPrivate, forKey: .isPrivate)
        try container.encode(price, forKey: .price)
        if let originalPrice {
            try container.encode(originalPrice, forKey: .originalPrice)
        } else {
            try container.encodeNil(forKey: .originalPrice)
        }
        try container.encode(category, forKey: .category)
        try container.encode(condition, forKey: .condition)
        try container.encode(isNegotiable, forKey: .isNegotiable)
        try container.encode(keepImageIDs, forKey: .keepImageIDs)
    }
}

private struct SecondhandProfilePostsParams: Encodable {
    let userID: UUID

    enum CodingKeys: String, CodingKey {
        case userID = "p_user_id"
    }
}

private struct SecondhandPostIDParams: Encodable {
    let postID: UUID

    enum CodingKeys: String, CodingKey {
        case postID = "p_post_id"
    }
}

private struct SecondhandAbandonMediaParams: Encodable {
    let operationID: UUID
    let reason: String

    enum CodingKeys: String, CodingKey {
        case operationID = "p_operation_id"
        case reason = "p_reason"
    }
}

private struct SecondhandCleanupBacklogParams: Encodable {
    let postID: UUID?

    enum CodingKeys: String, CodingKey {
        case postID = "p_post_id"
    }
}

private struct SecondhandMarkCleanupParams: Encodable {
    let cleanupID: UUID
    let succeeded: Bool
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case cleanupID = "p_cleanup_id"
        case succeeded = "p_succeeded"
        case errorCode = "p_error_code"
    }
}


private struct SecondhandPageCursor {
    let createdAt: Date
    let id: UUID
}

private struct SecondhandPageParams: Encodable {
    let afterCreatedAt: Date?
    let afterID: UUID?
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case afterCreatedAt = "p_after_created_at"
        case afterID = "p_after_id"
        case limit = "p_limit"
    }
}
