//
//  ForumService.swift
//  CheeseApp
//
//  💬 论坛服务
//  处理论坛帖子的 CRUD 操作
//

import Foundation
import Supabase
import UIKit

// MARK: - UI 论坛帖子模型
struct ForumPostItem: Identifiable, Hashable {
    let id: UUID
    let authorId: UUID?
    let authorAvatar: String?
    let title: String
    let content: String
    let boardID: UUID
    let boardName: String
    let boardIcon: String
    let boardAllowsAnonymous: Bool
    let authorName: String
    let isAnonymous: Bool
    let isAuthorOfficial: Bool
    var isAuthorMcMasterVerified: Bool = false
    let timeAgo: String
    let createdAt: Date
    var likes: Int
    var comments: Int
    var views: Int
    var isLiked: Bool
    let isPinned: Bool
    let imageUrls: [String]
    let hasImage: Bool
}

struct ForumPostPage {
    let items: [ForumPostItem]
    let cursor: ForumPostPageCursor?
    let hasMore: Bool
}

struct ForumPostPageCursor: Equatable {
    let isPinned: Bool
    let hotScore: Double
    let createdAt: Date
    let id: UUID
}

struct ForumSearchPage {
    let items: [ForumPostItem]
    let cursor: ForumSearchPageCursor?
    let hasMore: Bool
}

struct ForumSearchPageCursor: Equatable {
    let rankScore: Double
    let createdAt: Date
    let id: UUID
}

struct ForumCommentItem: Identifiable, Hashable {
    let id: UUID
    let postId: UUID
    let userId: UUID
    let parentId: UUID?
    let content: String
    let isAnonymous: Bool
    let likeCount: Int
    let createdAt: Date
    let timeAgo: String
    let authorName: String
    let authorAvatar: String?
    let isAuthorOfficial: Bool
    var isAuthorMcMasterVerified: Bool = false
    var isAuthorDeactivated: Bool = false
}

struct ForumCreateInput {
    let postId: UUID
    let userId: UUID
    let schoolId: UUID
    let title: String
    let content: String
    let isAnonymous: Bool
    var isPrivate: Bool = false
    let boardID: UUID
    var mentionedUserIDs: [UUID] = []
}

enum ForumCreatePostError: LocalizedError {
    case detailInsertFailedRollbackFailed(detailError: Error, rollbackError: Error)
    case publicationOutcomeUnknown(originalError: Error)

    var errorDescription: String? {
        Self.userFacingMessage
    }

    static let userFacingMessage = L10n.tr(
        "Unable to publish this post. Please try again.",
        "发布失败，请稍后重试。"
    )

    static let imageUploadUserFacingMessage = L10n.tr(
        "The post and its images could not be published. Please try again.",
        "帖子与图片未能完整发布，请重试。"
    )

    static func userFacingMessage(for error: Error) -> String {
        userFacingMessage
    }
}

struct ForumPublishingOperations {
    let isAlreadyPublished: (UUID) async throws -> Bool
    let prepare: (UUID, UUID, [PostImageUploadPlan]) async throws -> Void
    let upload: (UIImage, PostImageUploadPlan) async throws -> UploadedImageAsset
    let markUploaded: (UUID, Int) async throws -> Void
    let finalize: (ForumCreateInput, UUID) async throws -> UUID
    let abandon: (UUID, String) async throws -> [PostMediaCleanupItem]
    let deleteObject: (UploadedImageAsset) async throws -> Void
    let markCleanup: (UUID, Bool, String?) async throws -> Void
}

struct ForumPublishingWorkflow {
    let operations: ForumPublishingOperations

    func publish(
        input: ForumCreateInput,
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
                throw ForumCreatePostError.publicationOutcomeUnknown(
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

// MARK: - 论坛服务
@MainActor
class ForumService: ObservableObject {

    static let shared = ForumService()

    private let supabase = SupabaseManager.shared

    @Published var posts: [ForumPostItem] = []
    @Published private(set) var boards: [ForumBoard] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var mediaCleanupBacklogCount = 0
    @Published private(set) var mediaCleanupWarning: String?
    @Published private(set) var isLoadingNextPage = false
    @Published private(set) var hasMorePosts = true
    @Published private(set) var pageErrorMessage: String?
    @Published private(set) var accountGeneration: UInt64 = 0
    @Published private(set) var isAccountTransitionInProgress = false
    private var latestPostFetchID: UUID?
    private var postCursor: ForumPostPageCursor?
    private var activeBoardID: UUID?
    private var activeSort: ForumPostSort = .latest
    private var stateOwnerID: UUID?
    private static let pageSize = 24

    private init() {}

    @Published private(set) var hasResolvedInitialPostLoad = false

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
        latestPostFetchID = nil
        postCursor = nil
        activeBoardID = nil
        activeSort = .latest
        posts = []
        boards = []
        isLoading = false
        errorMessage = nil
        mediaCleanupBacklogCount = 0
        mediaCleanupWarning = nil
        isLoadingNextPage = false
        hasMorePosts = true
        pageErrorMessage = nil
        hasResolvedInitialPostLoad = false
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

    var postListState: CollectionLoadState {
        CollectionLoadState.resolve(
            hasResolvedInitialLoad: hasResolvedInitialPostLoad,
            isLoading: isLoading,
            hasContent: !posts.isEmpty,
            errorMessage: errorMessage
        )
    }

    func publishPost(
        input: ForumCreateInput,
        images: [UIImage]
    ) async throws -> UUID {
        let actingUserID = try await AuthService.shared.requireAuthUserId()
        guard input.userId == actingUserID else {
            throw NSError(
                domain: "ForumPublishing",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Authenticated user changed before publication."]
            )
        }

        let operationID = input.postId
        let plans = try ImageUploadService.shared.makePostImageUploadPlans(
            imageCount: images.count,
            userID: actingUserID,
            postID: input.postId,
            operationID: operationID
        )
        let workflow = ForumPublishingWorkflow(operations: livePublishingOperations())
        let publishedID = try await workflow.publish(
            input: input,
            images: images,
            plans: plans
        )

        await retryPendingMediaCleanup(postID: publishedID)
        return publishedID
    }


    func updatePost(
        payload: EditableUserPostPayload,
        retainedImageIDs: [UUID],
        newImages: [UIImage]
    ) async throws {
        guard payload.kind == .forum,
              let details = payload.forumDetails,
              let boardID = details.boardID
        else {
            throw NSError(
                domain: "ForumPublishing",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "请选择板块"]
            )
        }

        let actingUserID = try await AuthService.shared.requireAuthUserId()
        let operationID = UUID()
        let plans = try ImageUploadService.shared.makePostImageUploadPlans(
            imageCount: newImages.count,
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
            for (image, plan) in zip(newImages, plans) {
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
                "update_forum_post_with_media",
                params: ForumPostWithMediaUpdateParams(
                    postID: payload.id,
                    operationID: operationID,
                    boardID: boardID,
                    title: payload.title,
                    description: payload.description,
                    isAnonymous: payload.isAnonymous ?? details.isAnonymous,
                    isPrivate: payload.isPrivate,
                    allowComments: details.allowComments,
                    keepImageIDs: retainedImageIDs
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
        await fetchPosts()
    }

    func deletePost(postID: UUID) async throws {
        try await supabase.client.rpc(
            "delete_forum_post_with_media",
            params: ForumPostIDParams(postID: postID)
        ).execute()

        posts.removeAll { $0.id == postID }
        await retryPendingMediaCleanup(postID: postID)
        PostFeatureEvents.postDidChange(
            kind: .forum,
            authorId: AuthService.shared.currentUser?.id
        )
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
                    "Some post media cleanup is queued for retry.",
                    "部分帖子图片仍在等待清理重试。"
                )
        } catch {
            guard isCurrentAccountRequest(generation: requestGeneration) else { return }
            mediaCleanupWarning = L10n.tr(
                "Post media cleanup status is temporarily unavailable.",
                "暂时无法读取帖子图片清理状态。"
            )
        }
    }

    private func livePublishingOperations() -> ForumPublishingOperations {
        ForumPublishingOperations(
            isAlreadyPublished: { [weak self] postID in
                guard let self else { return false }
                return try await self.isForumPostPublished(postID: postID)
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
                return try await self.finalizeForumPublication(
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

    private func isForumPostPublished(postID: UUID) async throws -> Bool {
        let rows: [ForumPublishStatusRow] = try await supabase.client.rpc(
            "get_forum_publish_status",
            params: ForumPostIDParams(postID: postID)
        ).execute().value
        return rows.first?.isComplete == true
    }

    private func prepareMediaOperation(
        operationID: UUID,
        postID: UUID,
        plans: [PostImageUploadPlan]
    ) async throws {
        let rows: [PreparedPostMediaRow] = try await supabase.client.rpc(
            "prepare_post_media_operation",
            params: PreparePostMediaParams(
                operationID: operationID,
                postID: postID,
                postType: PostKind.forum.rawValue,
                media: plans
            )
        ).execute().value

        guard rows.count == plans.count else {
            throw NSError(
                domain: "ForumPublishing",
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
            params: MarkPostMediaUploadedParams(
                operationID: operationID,
                orderIndex: orderIndex
            )
        ).execute()
    }

    private func finalizeForumPublication(
        input: ForumCreateInput,
        operationID: UUID
    ) async throws -> UUID {
        try await supabase.client.rpc(
            "publish_forum_post_with_mentions",
            params: PublishForumPostParams(
                postID: input.postId,
                operationID: operationID,
                boardID: input.boardID,
                title: input.title,
                description: input.content,
                isAnonymous: input.isAnonymous,
                isPrivate: input.isPrivate,
                allowComments: true,
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
            params: AbandonPostMediaParams(
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
            params: MediaCleanupBacklogParams(postID: postID)
        ).execute().value
    }

    private func markMediaCleanup(
        cleanupID: UUID,
        succeeded: Bool,
        errorCode: String?
    ) async throws {
        try await supabase.client.rpc(
            "mark_post_media_cleanup_attempt",
            params: MarkMediaCleanupParams(
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
                    errorCode: ForumPublishingWorkflow.cleanupErrorCode(error)
                )
            }
        }
    }

    private func mediaOperationIsFinalized(
        operationID: UUID,
        expectedCount: Int
    ) async throws -> Bool {
        let rows: [PostMediaStageStatusRow] = try await supabase
            .database("post_media_staging")
            .select("status")
            .eq("operation_id", value: operationID.uuidString)
            .execute()
            .value
        return rows.count == expectedCount && rows.allSatisfy { $0.status == "finalized" }
    }

    func fetchBoards() async {
        guard let requestGeneration = requestGeneration() else { return }
        do {
            let fetchedBoards: [ForumBoard] = try await supabase
                .database("forum_boards_view")
                .select()
                .neq("status", value: ForumBoard.Status.archived.rawValue)
                .order("created_at", ascending: true)
                .execute()
                .value
            guard isCurrentAccountRequest(generation: requestGeneration) else { return }
            boards = fetchedBoards
        } catch {
            if isCurrentAccountRequest(generation: requestGeneration),
               !error.isCancellationLike {
                errorMessage = L10n.tr("Unable to load boards", "板块加载失败")
            }
        }
    }

    // MARK: - 获取论坛帖子
    func fetchPosts(
        boardID: UUID? = nil,
        sort: ForumPostSort = .latest,
        replacingContent: Bool = false
    ) async {
        guard let requestGeneration = requestGeneration() else { return }
        let fetchID = UUID()
        latestPostFetchID = fetchID
        activeBoardID = boardID
        activeSort = sort
        postCursor = nil
        hasMorePosts = true

        if replacingContent {
            posts = []
            hasResolvedInitialPostLoad = false
        }

        isLoading = true
        errorMessage = nil
        pageErrorMessage = nil

        defer {
            if isCurrentAccountRequest(generation: requestGeneration),
               latestPostFetchID == fetchID {
                isLoading = false
            }
        }

        do {
            let page = try await fetchPostPage(
                boardID: boardID,
                sort: sort,
                after: nil
            )
            guard isCurrentAccountRequest(generation: requestGeneration),
                  latestPostFetchID == fetchID
            else { return }
            posts = boardID == nil ? Self.spreadingBoards(in: page.items) : page.items
            postCursor = page.cursor
            hasMorePosts = page.hasMore
            hasResolvedInitialPostLoad = true
        } catch {
            guard isCurrentAccountRequest(generation: requestGeneration),
                  latestPostFetchID == fetchID
            else { return }
            if error.isCancellationLike {
                return
            }
            errorMessage = "加载失败: \(error.localizedDescription)"
            hasResolvedInitialPostLoad = true
        }
    }

    func loadNextPostPage() async {
        guard hasMorePosts, !isLoading, !isLoadingNextPage else { return }
        guard let requestGeneration = requestGeneration() else { return }
        let expectedFetchID = latestPostFetchID
        let boardID = activeBoardID
        let sort = activeSort
        let cursor = postCursor
        isLoadingNextPage = true
        pageErrorMessage = nil
        defer {
            if isCurrentAccountRequest(generation: requestGeneration),
               latestPostFetchID == expectedFetchID {
                isLoadingNextPage = false
            }
        }

        do {
            let page = try await fetchPostPage(
                boardID: boardID,
                sort: sort,
                after: cursor
            )
            guard isCurrentAccountRequest(generation: requestGeneration),
                  latestPostFetchID == expectedFetchID,
                  activeBoardID == boardID,
                  activeSort == sort
            else { return }
            let existingIDs = Set(posts.map(\.id))
            let appended = page.items.filter { !existingIDs.contains($0.id) }
            posts.append(contentsOf: boardID == nil
                ? Self.spreadingBoards(in: appended)
                : appended
            )
            postCursor = page.cursor ?? postCursor
            hasMorePosts = page.hasMore
        } catch {
            guard isCurrentAccountRequest(generation: requestGeneration),
                  latestPostFetchID == expectedFetchID
            else { return }
            if !error.isCancellationLike {
                pageErrorMessage = L10n.tr(
                    "Unable to load more posts. Tap to retry.",
                    "加载更多帖子失败，点击重试。"
                )
            }
        }
    }

    func fetchPostPage(
        boardID: UUID?,
        sort: ForumPostSort,
        after cursor: ForumPostPageCursor?
    ) async throws -> ForumPostPage {
        let dbPosts: [DBForumPost] = try await supabase.client.rpc(
            "get_forum_posts_page",
            params: ForumPostPageParams(
                boardID: boardID,
                sort: sort.rawValue,
                afterIsPinned: cursor?.isPinned,
                afterHotScore: sort == .hottest ? cursor?.hotScore : nil,
                afterCreatedAt: cursor?.createdAt,
                afterID: cursor?.id,
                limit: Self.pageSize
            )
        ).execute().value
        let reactions = await PostReactionService.shared.fetchStates(
            postIds: dbPosts.map(\.id)
        )
        let items = dbPosts.map {
            Self.makePostItem($0, reaction: reactions[$0.id])
        }
        seedInteractionStates(items)
        let nextCursor = dbPosts.last.map {
            ForumPostPageCursor(
                isPinned: $0.isPinned ?? false,
                hotScore: $0.hotScore ?? 0,
                createdAt: $0.createdAt,
                id: $0.id
            )
        }
        return ForumPostPage(
            items: items,
            cursor: nextCursor,
            hasMore: dbPosts.count == Self.pageSize
        )
    }

    func fetchPostItems(
        boardID: UUID? = nil,
        query searchText: String? = nil,
        sort: ForumPostSort = .latest
    ) async throws -> [ForumPostItem] {
        if searchText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return try await fetchPostPage(
                boardID: boardID,
                sort: sort,
                after: nil
            ).items
        }

        return try await fetchSearchPage(
            query: searchText ?? "",
            boardID: boardID,
            after: nil
        ).items
    }

    func fetchSearchPage(
        query: String,
        boardID: UUID?,
        after cursor: ForumSearchPageCursor?
    ) async throws -> ForumSearchPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ForumSearchPage(items: [], cursor: nil, hasMore: false)
        }

        let references: [ForumSearchReferenceRow] = try await supabase.client.rpc(
            "search_forum_post_ids_page",
            params: ForumSearchPageParams(
                query: trimmed,
                boardID: boardID,
                afterRankScore: cursor?.rankScore,
                afterCreatedAt: cursor?.createdAt,
                afterID: cursor?.id,
                limit: Self.pageSize
            )
        ).execute().value

        let ids = references.map(\.id)
        guard !ids.isEmpty else {
            return ForumSearchPage(items: [], cursor: nil, hasMore: false)
        }

        let dbPosts: [DBForumPost] = try await supabase
            .database("forum_posts_view")
            .select()
            .in("id", values: ids.map(\.uuidString))
            .execute()
            .value
        let reactions = await PostReactionService.shared.fetchStates(postIds: ids)
        let postByID = Dictionary(
            uniqueKeysWithValues: dbPosts.map {
                ($0.id, Self.makePostItem($0, reaction: reactions[$0.id]))
            }
        )
        let items = references.compactMap { postByID[$0.id] }
        seedInteractionStates(items)
        let nextCursor = references.last.map {
            ForumSearchPageCursor(
                rankScore: $0.rankScore,
                createdAt: $0.createdAt,
                id: $0.id
            )
        }
        return ForumSearchPage(
            items: items,
            cursor: nextCursor,
            hasMore: references.count == Self.pageSize
        )
    }

    // MARK: - 获取单个帖子
    func fetchPost(postId: UUID) async throws -> ForumPostItem {
        let dbPost: DBForumPost = try await supabase
            .database("forum_posts_view")
            .select()
            .eq("id", value: postId.uuidString)
            .single()
            .execute()
            .value

        let reactionState = await PostReactionService.shared.fetchStates(postIds: [dbPost.id])[dbPost.id]
        let item = Self.makePostItem(dbPost, reaction: reactionState)
        seedInteractionStates([item])
        upsertLocalPost(item)
        return item
    }

    func fetchPosts(postIDs: [UUID]) async throws -> [ForumPostItem] {
        let uniqueIDs = Array(Set(postIDs))
        guard !uniqueIDs.isEmpty else { return [] }

        let dbPosts: [DBForumPost] = try await supabase
            .database("forum_posts_view")
            .select()
            .in("id", values: uniqueIDs.map(\.uuidString))
            .execute()
            .value

        let reactionStates = await PostReactionService.shared.fetchStates(
            postIds: dbPosts.map(\.id)
        )
        let items = dbPosts.map { Self.makePostItem($0, reaction: reactionStates[$0.id]) }
        seedInteractionStates(items)
        items.forEach(upsertLocalPost)
        return items
    }

    func fetchBoardModerators(boardID: UUID) async throws -> [ForumBoardModerator] {
        let memberships: [ForumBoardModeratorMembershipRow] = try await supabase
            .database("forum_board_memberships")
            .select("user_id,role")
            .eq("board_id", value: boardID.uuidString)
            .in("role", values: ["moderator", "admin"])
            .execute()
            .value
        guard !memberships.isEmpty else { return [] }

        let profiles: [DBProfileLite] = try await supabase
            .database("profile_public_view")
            .select("id,full_name,avatar_url")
            .in("id", values: memberships.map(\.userID.uuidString))
            .execute()
            .value
        let profileByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return memberships.compactMap { membership in
            guard let profile = profileByID[membership.userID],
                  let role = ForumBoard.MembershipRole(rawValue: membership.role) else { return nil }
            return ForumBoardModerator(
                id: membership.userID,
                fullName: profile.fullName,
                avatarURL: profile.avatarUrl,
                role: role
            )
        }
    }

    func setBoardMemberRole(
        boardID: UUID,
        userID: UUID,
        role: ForumBoard.MembershipRole
    ) async throws {
        try await supabase.client
            .rpc(
                "set_forum_board_member_role",
                params: ForumBoardRoleParams(boardID: boardID, userID: userID, role: role.rawValue)
            )
            .execute()
        await fetchBoards()
    }

    func fetchBoardReports(boardID: UUID) async throws -> [ForumBoardReport] {
        let posts: [DBOwnForumPostLite] = try await supabase
            .database("forum_posts_view")
            .select("id,title")
            .eq("board_id", value: boardID.uuidString)
            .execute()
            .value
        guard !posts.isEmpty else { return [] }

        let rows: [ForumBoardReportRow] = try await supabase
            .database("post_reports")
            .select("id,post_id,reason,details,status,created_at")
            .`in`("post_id", values: posts.map { $0.id as any PostgrestFilterValue })
            .`in`("status", values: ["pending", "reviewing"])
            .order("created_at", ascending: false)
            .execute()
            .value
        let titles = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0.title) })
        return rows.compactMap { row in
            guard let status = ForumBoardReport.Status(rawValue: row.status) else { return nil }
            return ForumBoardReport(
                id: row.id,
                postID: row.postID,
                postTitle: titles[row.postID] ?? L10n.tr("Deleted post", "已删除帖子"),
                reason: row.reason,
                details: row.details,
                status: status,
                createdAt: row.createdAt
            )
        }
    }

    func setReportStatus(reportID: UUID, status: ForumBoardReport.Status) async throws {
        try await supabase
            .database("post_reports")
            .update(["status": status.rawValue])
            .eq("id", value: reportID.uuidString)
            .execute()
    }

    func updateBoard(
        _ board: ForumBoard,
        name: String,
        description: String,
        rules: String,
        allowsAnonymous: Bool,
        status: ForumBoard.Status
    ) async throws {
        try await supabase
            .database("forum_boards")
            .update(ForumBoardUpdate(
                name: name,
                description: description,
                rules: rules,
                allowsAnonymousPosts: allowsAnonymous,
                status: status.rawValue
            ))
            .eq("id", value: board.id.uuidString)
            .execute()
        await fetchBoards()
    }

    func setPostPinned(postID: UUID, isPinned: Bool) async throws {
        try await supabase
            .database("forum_posts")
            .update(["is_pinned": isPinned])
            .eq("id", value: postID.uuidString)
            .execute()
    }

    func hidePost(postID: UUID) async throws {
        try await supabase
            .database("posts")
            .update(["status": "inactive"])
            .eq("id", value: postID.uuidString)
            .execute()
        posts.removeAll { $0.id == postID }
    }

    func recordView(postId: UUID) async {
        let previousLocalCount = posts.first(where: { $0.id == postId })?.views
        do {
            try await supabase.client
                .rpc("record_post_view", params: RecordPostViewParams(pPostId: postId))
                .execute()
            if let previousLocalCount {
                updateLocalViewCount(postId: postId, viewCount: previousLocalCount + 1)
            }
            await refreshLocalViewCount(
                postId: postId,
                fallbackViewCount: previousLocalCount.map { $0 + 1 }
            )
        } catch {
            if error.isCancellationLike {
                return
            }
        }
    }

    // MARK: - 获取评论
    func observeCommentChanges(
        postId: UUID,
        onChange: @escaping @MainActor () async -> Void
    ) -> () -> Void {
        let channel = supabase.client.channel(
            "forum-comments-\(postId.uuidString)-\(UUID().uuidString)"
        )
        let changes = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "comments",
            filter: .eq("post_id", value: postId)
        )
        let task = Task {
            do {
                try await channel.subscribeWithError()
                for await _ in changes {
                    guard !Task.isCancelled else { break }
                    await onChange()
                }
            } catch {
                // Pull-to-refresh and the next detail appearance remain
                // authoritative fallbacks for temporary realtime disconnects.
            }
        }

        return { [supabase] in
            task.cancel()
            Task { await supabase.client.removeChannel(channel) }
        }
    }

    func fetchComments(postId: UUID) async throws -> [ForumCommentItem] {
        let rows: [DBCommentRow] = try await supabase
            .database("comments")
            .select()
            .eq("post_id", value: postId.uuidString)
            .order("created_at", ascending: true)
            .execute()
            .value

        let userIds = Array(Set(rows.filter { !$0.isAnonymous }.map(\.userId)))
        var profileMap: [UUID: DBProfileLite] = [:]

        if !userIds.isEmpty {
            let idFilters = userIds.map { $0 as any PostgrestFilterValue }
            let profiles: [DBProfileLite] = try await supabase
                .database("profile_public_view")
                .select("id,full_name,avatar_url,is_official,is_mcmaster_verified")
                .`in`("id", values: idFilters)
                .execute()
                .value
            profileMap = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        }

        let mapped = rows.map { row in
            let profile = profileMap[row.userId]
            let authorName: String = {
                if row.isAnonymous {
                    return L10n.tr("Anonymous comment", "匿名评论")
                }
                if row.authorIsDeactivated == true { return "已注销" }
                if let fullName = profile?.fullName, !fullName.isEmpty { return fullName }
                if let email = profile?.email, let localPart = email.split(separator: "@").first, !localPart.isEmpty {
                    return String(localPart)
                }
                return "User"
            }()

            return ForumCommentItem(
                id: row.id,
                postId: row.postId,
                userId: row.userId,
                parentId: row.parentId,
                content: row.content,
                isAnonymous: row.isAnonymous,
                likeCount: row.likeCount,
                createdAt: row.createdAt,
                timeAgo: Formatters.formatCompactTimeAgo(row.createdAt, useJustNow: true),
                authorName: authorName,
                authorAvatar: row.isAnonymous || row.authorIsDeactivated == true
                    ? nil
                    : profile?.avatarUrl,
                isAuthorOfficial: !row.isAnonymous
                    && row.authorIsDeactivated != true
                    && profile?.isOfficial == true,
                isAuthorMcMasterVerified: !row.isAnonymous
                    && row.authorIsDeactivated != true
                    && profile?.isMcMasterVerified == true,
                isAuthorDeactivated: row.authorIsDeactivated == true
            )
        }
        return mapped
    }

    func fetchLikedCommentIds(commentIds: [UUID]) async -> Set<UUID> {
        guard !commentIds.isEmpty,
              let userId = try? await AuthService.shared.requireAuthUserId()
        else { return [] }

        do {
            let ids = commentIds.map { $0 as any PostgrestFilterValue }
            let rows: [DBCommentLikeTargetRow] = try await supabase
                .database("likes")
                .select("target_id")
                .eq("user_id", value: userId.uuidString)
                .eq("target_type", value: "comment")
                .`in`("target_id", values: ids)
                .execute()
                .value
            return Set(rows.map(\.targetId))
        } catch {
            return []
        }
    }

    func toggleCommentLike(commentId: UUID, currentlyLiked: Bool) async throws -> Bool {
        let userId = try await AuthService.shared.requireAuthUserId()

        if currentlyLiked {
            try await supabase
                .database("likes")
                .delete()
                .eq("user_id", value: userId.uuidString)
                .eq("target_type", value: "comment")
                .eq("target_id", value: commentId.uuidString)
                .execute()
            return false
        }

        do {
            try await supabase
                .database("likes")
                .insert(DBCommentLikeInsert(
                    userId: userId,
                    targetType: "comment",
                    targetId: commentId
                ))
                .execute()
            return true
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("duplicate key") || message.contains("unique") {
                return true
            }
            throw error
        }
    }

    // MARK: - 点赞 / 取消点赞
    func toggleLike(postId: UUID, currentlyLiked: Bool) async throws -> Bool {
        let newLiked = try await PostReactionService.shared.toggle(postId: postId, currentlyLiked: currentlyLiked)
        updateLocalLikeState(postId: postId, isLiked: newLiked)
        return newLiked
    }

    func isFavorite(postId: UUID) async -> Bool {
        await PostFavoriteService.shared.fetchFavoritePostIds(postIds: [postId]).contains(postId)
    }

    func toggleFavorite(postId: UUID, currentlyFavorited: Bool) async throws -> Bool {
        try await PostFavoriteService.shared.toggleFavorite(
            postId: postId,
            currentlyFavorited: currentlyFavorited
        )
    }

    // MARK: - 发布评论
    func createComment(
        commentId: UUID,
        postId: UUID,
        content: String,
        isAnonymous: Bool,
        parentId: UUID? = nil,
        mentionedUserIds: [UUID] = []
    ) async throws -> UUID {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return commentId }

        do {
            _ = try await AuthService.shared.requireAuthUserId()
        } catch {
            await AuthService.shared.checkSession()
            throw NSError(
                domain: "",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: L10n.tr("Please sign in before commenting", "请先登入后再评论")]
            )
        }

        let createdID: UUID = try await supabase.client
            .rpc(
                "create_forum_comment_with_mentions",
                params: CreateForumCommentParams(
                    commentID: commentId,
                    postID: postId,
                    content: trimmed,
                    isAnonymous: isAnonymous,
                    parentID: parentId,
                    mentionedUserIDs: Array(mentionedUserIds.prefix(10))
                )
            )
            .execute()
            .value

        if let index = posts.firstIndex(where: { $0.id == postId }) {
            posts[index].comments += 1
        }
        return createdID
    }

    // MARK: - 删除评论
    func deleteComment(commentId: UUID, postId: UUID) async throws {
        try await supabase
            .database("comments")
            .delete()
            .eq("id", value: commentId.uuidString)
            .execute()

        if let index = posts.firstIndex(where: { $0.id == postId }) {
            posts[index].comments = max(posts[index].comments - 1, 0)
        }
    }

    // MARK: - 转换模型
    static func makePostItem(_ dbPost: DBForumPost, reaction: PostReactionState?) -> ForumPostItem {
        let authorName = dbPost.isAnonymous
            ? L10n.tr("Anonymous", "匿名")
            : (dbPost.userName ?? L10n.tr("Unknown", "未知用户"))

        return ForumPostItem(
            id: dbPost.id,
            // Keep authorId for ownership checks (edit/delete), even for anonymous posts.
            authorId: dbPost.userId,
            authorAvatar: dbPost.isAnonymous ? nil : dbPost.userAvatar,
            title: dbPost.title,
            content: dbPost.description ?? "",
            boardID: dbPost.boardID,
            boardName: dbPost.boardName,
            boardIcon: dbPost.boardIcon,
            boardAllowsAnonymous: dbPost.boardAllowsAnonymous,
            authorName: authorName,
            isAnonymous: dbPost.isAnonymous,
            isAuthorOfficial: !dbPost.isAnonymous && dbPost.userOfficial == true,
            isAuthorMcMasterVerified: !dbPost.isAnonymous && dbPost.userMcMasterVerified == true,
            timeAgo: Formatters.formatCompactTimeAgo(dbPost.createdAt, useJustNow: true),
            createdAt: dbPost.createdAt,
            likes: dbPost.likeCount ?? 0,
            comments: dbPost.commentCount ?? 0,
            views: dbPost.viewCount ?? 0,
            isLiked: reaction?.isLiked ?? false,
            isPinned: dbPost.isPinned ?? false,
            imageUrls: dbPost.images?.map(\.url) ?? [],
            hasImage: !(dbPost.images?.isEmpty ?? true)
        )
    }

    static func spreadingBoards(in posts: [ForumPostItem]) -> [ForumPostItem] {
        guard posts.count > 2 else { return posts }
        var remaining = posts
        var result: [ForumPostItem] = []
        while !remaining.isEmpty {
            let repeatedBoard = result.count >= 2
                && result[result.count - 1].boardID == result[result.count - 2].boardID
            let index: Int
            if repeatedBoard,
               let different = remaining.firstIndex(where: { $0.boardID != result.last?.boardID }) {
                index = different
            } else {
                index = 0
            }
            result.append(remaining.remove(at: index))
        }
        return result
    }

    private func updateLocalLikeState(postId: UUID, isLiked: Bool) {
        guard let index = posts.firstIndex(where: { $0.id == postId }) else { return }

        var updated = posts[index]
        guard updated.isLiked != isLiked else { return }

        updated.isLiked = isLiked
        let delta = isLiked ? 1 : -1
        updated.likes = max(updated.likes + delta, 0)

        // Re-assigning the whole array guarantees @Published emits for detail views
        // that listen to service.$posts.
        var nextPosts = posts
        nextPosts[index] = updated
        posts = nextPosts
    }

    private func seedInteractionStates(_ items: [ForumPostItem]) {
        PostInteractionStore.shared.mergeServerSnapshots(
            items.map {
                PostInteractionStore.Update(
                    postID: $0.id,
                    likeCount: $0.likes,
                    isLiked: $0.isLiked
                )
            }
        )
    }

    private func upsertLocalPost(_ post: ForumPostItem) {
        if let index = posts.firstIndex(where: { $0.id == post.id }) {
            posts[index] = post
        } else {
            posts.insert(post, at: 0)
        }
    }

    private func refreshLocalViewCount(postId: UUID, fallbackViewCount: Int? = nil) async {
        var bestViewCount = fallbackViewCount

        do {
            let row: DBForumPostViewCountRow = try await supabase
                .database("forum_posts_view")
                .select("id,view_count")
                .eq("id", value: postId.uuidString)
                .single()
                .execute()
                .value
            if let count = row.viewCount {
                bestViewCount = max(bestViewCount ?? 0, count)
            }
        } catch {
        }

        do {
            let row: DBBasePostViewCountRow = try await supabase
                .database("posts")
                .select("id,view_count")
                .eq("id", value: postId.uuidString)
                .single()
                .execute()
                .value
            if let count = row.viewCount {
                bestViewCount = max(bestViewCount ?? 0, count)
            }
        } catch {
        }

        if let bestViewCount {
            updateLocalViewCount(postId: postId, viewCount: bestViewCount)
        }
    }

    private func updateLocalViewCount(postId: UUID, viewCount: Int) {
        guard let index = posts.firstIndex(where: { $0.id == postId }) else { return }
        posts[index].views = max(viewCount, posts[index].views)
    }

}

// MARK: - 数据库论坛帖子模型（forum_posts_view）
struct DBForumPost: Codable, Identifiable {
    let id: UUID
    let userId: UUID?
    let title: String
    let description: String?
    let boardID: UUID
    let boardName: String
    let boardIcon: String
    let boardAllowsAnonymous: Bool
    let isAnonymous: Bool
    let isPinned: Bool?
    let likeCount: Int?
    let commentCount: Int?
    let viewCount: Int?
    let hotScore: Double?
    let createdAt: Date
    let userName: String?
    let userAvatar: String?
    let userOfficial: Bool?
    var userMcMasterVerified: Bool? = nil
    let viewerOwnsPost: Bool?
    let images: [DBForumImage]?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case description
        case boardID = "board_id"
        case boardName = "board_name"
        case boardIcon = "board_icon"
        case boardAllowsAnonymous = "board_allows_anonymous"
        case isAnonymous = "is_anonymous"
        case isPinned = "is_pinned"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case viewCount = "view_count"
        case hotScore = "hot_score"
        case createdAt = "created_at"
        case userName = "user_name"
        case userAvatar = "user_avatar"
        case userOfficial = "user_official"
        case userMcMasterVerified = "user_mcmaster_verified"
        case viewerOwnsPost = "viewer_owns_post"
        case images
    }
}

struct DBForumImage: Codable {
    let id: UUID?
    let url: String
    let orderIndex: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case orderIndex = "order_index"
    }
}

private struct RecordPostViewParams: Encodable {
    let pPostId: UUID

    enum CodingKeys: String, CodingKey {
        case pPostId = "p_post_id"
    }
}

private struct ForumSearchReferenceRow: Decodable {
    let id: UUID
    let rankScore: Double
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case rankScore = "rank_score"
        case createdAt = "created_at"
    }
}

private struct ForumSearchPageParams: Encodable {
    let query: String
    let boardID: UUID?
    let afterRankScore: Double?
    let afterCreatedAt: Date?
    let afterID: UUID?
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case query = "p_query"
        case boardID = "p_board_id"
        case afterRankScore = "p_after_rank_score"
        case afterCreatedAt = "p_after_created_at"
        case afterID = "p_after_id"
        case limit = "p_limit"
    }
}

private struct DBForumPostViewCountRow: Decodable {
    let id: UUID
    let viewCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case viewCount = "view_count"
    }
}

private struct DBBasePostViewCountRow: Decodable {
    let id: UUID
    let viewCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case viewCount = "view_count"
    }
}

private struct DBOwnForumPostLite: Codable {
    let id: UUID
    let title: String
}

struct DBCommentRow: Codable, Identifiable {
    let id: UUID
    let postId: UUID
    let userId: UUID
    let parentId: UUID?
    let content: String
    let isAnonymous: Bool
    let authorIsDeactivated: Bool?
    let likeCount: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case postId = "post_id"
        case userId = "user_id"
        case parentId = "parent_id"
        case content
        case isAnonymous = "is_anonymous"
        case authorIsDeactivated = "author_is_deactivated"
        case likeCount = "like_count"
        case createdAt = "created_at"
    }
}

private struct DBCommentLikeTargetRow: Decodable {
    let targetId: UUID

    enum CodingKeys: String, CodingKey {
        case targetId = "target_id"
    }
}

private struct DBCommentLikeInsert: Encodable {
    let userId: UUID
    let targetType: String
    let targetId: UUID

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case targetType = "target_type"
        case targetId = "target_id"
    }
}

struct DBProfileLite: Codable {
    let id: UUID
    let fullName: String?
    let avatarUrl: String?
    let email: String?
    let isOfficial: Bool?
    var isMcMasterVerified: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case avatarUrl = "avatar_url"
        case email
        case isOfficial = "is_official"
        case isMcMasterVerified = "is_mcmaster_verified"
    }
}

private struct CreateForumCommentParams: Encodable {
    let commentID: UUID
    let postID: UUID
    let content: String
    let isAnonymous: Bool
    let parentID: UUID?
    let mentionedUserIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case commentID = "p_comment_id"
        case postID = "p_post_id"
        case content = "p_content"
        case isAnonymous = "p_is_anonymous"
        case parentID = "p_parent_id"
        case mentionedUserIDs = "p_mentioned_user_ids"
    }
}

private struct ForumBoardRoleParams: Encodable {
    let boardID: UUID
    let userID: UUID
    let role: String

    enum CodingKeys: String, CodingKey {
        case boardID = "p_board_id"
        case userID = "p_user_id"
        case role = "p_role"
    }
}

private struct ForumBoardReportRow: Decodable {
    let id: UUID
    let postID: UUID
    let reason: String
    let details: String?
    let status: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, reason, details, status
        case postID = "post_id"
        case createdAt = "created_at"
    }
}

private struct ForumBoardModeratorMembershipRow: Decodable {
    let userID: UUID
    let role: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case role
    }
}

private struct ForumBoardUpdate: Encodable {
    let name: String
    let description: String
    let rules: String
    let allowsAnonymousPosts: Bool
    let status: String

    enum CodingKeys: String, CodingKey {
        case name, description, rules, status
        case allowsAnonymousPosts = "allows_anonymous_posts"
    }
}

private struct PreparedPostMediaRow: Decodable {
    let id: UUID
    let status: String
}

private struct PostMediaStageStatusRow: Decodable {
    let status: String
}

private struct ForumPublishStatusRow: Decodable {
    let postID: UUID
    let isComplete: Bool

    enum CodingKeys: String, CodingKey {
        case postID = "post_id"
        case isComplete = "is_complete"
    }
}

private struct PreparePostMediaParams: Encodable {
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

private struct MarkPostMediaUploadedParams: Encodable {
    let operationID: UUID
    let orderIndex: Int

    enum CodingKeys: String, CodingKey {
        case operationID = "p_operation_id"
        case orderIndex = "p_order_index"
    }
}

private struct PublishForumPostParams: Encodable {
    let postID: UUID
    let operationID: UUID
    let boardID: UUID
    let title: String
    let description: String
    let isAnonymous: Bool
    let isPrivate: Bool
    let allowComments: Bool
    let mentionedUserIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case postID = "p_post_id"
        case operationID = "p_operation_id"
        case boardID = "p_board_id"
        case title = "p_title"
        case description = "p_description"
        case isAnonymous = "p_is_anonymous"
        case isPrivate = "p_is_private"
        case allowComments = "p_allow_comments"
        case mentionedUserIDs = "p_mentioned_user_ids"
    }
}

private struct ForumPostWithMediaUpdateParams: Encodable {
    let postID: UUID
    let operationID: UUID
    let boardID: UUID
    let title: String
    let description: String
    let isAnonymous: Bool
    let isPrivate: Bool
    let allowComments: Bool
    let keepImageIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case postID = "p_post_id"
        case operationID = "p_operation_id"
        case boardID = "p_board_id"
        case title = "p_title"
        case description = "p_description"
        case isAnonymous = "p_is_anonymous"
        case isPrivate = "p_is_private"
        case allowComments = "p_allow_comments"
        case keepImageIDs = "p_keep_image_ids"
    }
}

private struct ForumPostIDParams: Encodable {
    let postID: UUID

    enum CodingKeys: String, CodingKey {
        case postID = "p_post_id"
    }
}

private struct AbandonPostMediaParams: Encodable {
    let operationID: UUID
    let reason: String

    enum CodingKeys: String, CodingKey {
        case operationID = "p_operation_id"
        case reason = "p_reason"
    }
}

private struct MediaCleanupBacklogParams: Encodable {
    let postID: UUID?

    enum CodingKeys: String, CodingKey {
        case postID = "p_post_id"
    }
}

private struct MarkMediaCleanupParams: Encodable {
    let cleanupID: UUID
    let succeeded: Bool
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case cleanupID = "p_cleanup_id"
        case succeeded = "p_succeeded"
        case errorCode = "p_error_code"
    }
}


private struct ForumPostPageParams: Encodable {
    let boardID: UUID?
    let sort: String
    let afterIsPinned: Bool?
    let afterHotScore: Double?
    let afterCreatedAt: Date?
    let afterID: UUID?
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case boardID = "p_board_id"
        case sort = "p_sort"
        case afterIsPinned = "p_after_is_pinned"
        case afterHotScore = "p_after_hot_score"
        case afterCreatedAt = "p_after_created_at"
        case afterID = "p_after_id"
        case limit = "p_limit"
    }
}
