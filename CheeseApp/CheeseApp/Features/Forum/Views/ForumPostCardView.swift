//
//  ForumListView.swift
//  CheeseApp
//
//  💬 论坛列表视图
//  展示论坛帖子，支持分类筛选
//

import SwiftUI
import UIKit
extension ForumPostItem {
    var editableSummary: UserPostSummary {
        UserPostSummary(
            id: id,
            kind: .forum,
            title: title,
            description: content,
            subtitle: "",
            price: nil,
            createdAt: Date(),
            authorId: authorId ?? UUID(),
            authorName: authorName,
            authorAvatarURL: authorAvatar
        )
    }

    var sharePayload: PostSharePayload {
        PostSharePayload(
            kind: .forum,
            postId: id,
            title: title,
            subtitle: nil,
            summary: content,
            imageURLs: imageUrls.compactMap(URL.init(string:))
        )
    }

    var forumFeedCardItem: HomeCardItem {
        let avatar = isAnonymous
            ? ImageSource.placeholder
            : authorAvatar
                .flatMap(URL.init(string:))
                .map(ImageSource.url) ?? .placeholder

        return HomeCardItem(
            postId: id,
            authorId: isAnonymous ? nil : authorId,
            image: imageUrls.first
                .flatMap(URL.init(string:))
                .map(ImageSource.url) ?? .placeholder,
            images: imageUrls
                .compactMap(URL.init(string:))
                .map(ImageSource.url),
            title: title,
            subtitle: content,
            footer: .posted(name: authorName, avatar: avatar),
            isAnonymous: isAnonymous,
            isAuthorOfficial: !isAnonymous && isAuthorOfficial,
            isAuthorMcMasterVerified: !isAnonymous && isAuthorMcMasterVerified,
            category: .forum,
            viewCount: views,
            badgeText: nil,
            boardID: boardID,
            boardIcon: boardIcon,
            timeText: timeAgo,
            likeCount: likes,
            commentCount: comments,
            isSystemPinned: isPinned,
            initiallyLiked: isLiked
        )
    }
}

// MARK: - 论坛帖子卡片
struct ForumPostCardView: View {
    @ObservedObject private var interactionStore = PostInteractionStore.shared

    let post: ForumPostItem
    let isOwnPost: Bool
    var recommendationContext: ForumRecommendationEventContext? = nil
    var onTap: (() -> Void)?
    var onLikeTap: (() async -> Void)?
    var onFavoriteTap: (() async -> Void)?
    var onEditTap: (() -> Void)?
    var onShareTap: (() -> Void)?
    var onAuthorTap: (() -> Void)?

    private var interaction: PostInteractionState {
        interactionStore.state(
            for: post.id,
            fallbackLikeCount: post.likes,
            fallbackIsLiked: post.isLiked
        )
    }

    var body: some View {
        ContentCardView(
            item: post.forumFeedCardItem,
            interaction: interaction,
            onTap: onTap,
            onAuthorTap: onAuthorTap,
            onLikeTap: {
                Task { await onLikeTap?() }
            },
            onFavoriteTap: {
                Task { await onFavoriteTap?() }
            },
            onShareTap: onShareTap
        )
        .padding(.horizontal, 4)
        .modifier(
            RecommendationVisibilityModifier(
                postID: post.id,
                context: recommendationContext
            )
        )
        .contextMenu {
            if isOwnPost {
                Button {
                    onEditTap?()
                } label: {
                    Label(L10n.tr("Edit", "编辑"), systemImage: "square.and.pencil")
                }
            }
        }
    }

}

private struct RecommendationCardFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

enum ForumRecommendationVisibilityPolicy {
    static let minimumVisibleFraction = 0.5
    static let qualifiedImpressionMilliseconds = 1_000
    static let meaningfulReadMilliseconds = 3_000

    static func qualifies(
        visibleFraction: Double,
        dwellMilliseconds: Int
    ) -> (qualifiedImpression: Bool, meaningfulRead: Bool) {
        guard visibleFraction >= minimumVisibleFraction else {
            return (false, false)
        }
        return (
            dwellMilliseconds >= qualifiedImpressionMilliseconds,
            dwellMilliseconds >= meaningfulReadMilliseconds
        )
    }
}

private struct RecommendationVisibilityModifier: ViewModifier {
    let postID: UUID
    let context: ForumRecommendationEventContext?

    @State private var visibilityGeneration: UUID?

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: RecommendationCardFrameKey.self,
                        value: proxy.frame(in: .global)
                    )
                }
            }
            .onPreferenceChange(RecommendationCardFrameKey.self) { frame in
                updateVisibility(frame)
            }
            .onDisappear {
                visibilityGeneration = nil
            }
    }

    @MainActor
    private func updateVisibility(_ frame: CGRect) {
        guard let context, frame.height > 0, frame.width > 0 else {
            visibilityGeneration = nil
            return
        }
        let viewport = UIScreen.main.bounds
        let intersection = frame.intersection(viewport)
        let fraction = intersection.isNull
            ? 0
            : min(max(intersection.height / frame.height, 0), 1)
        guard fraction >= ForumRecommendationVisibilityPolicy.minimumVisibleFraction else {
            visibilityGeneration = nil
            return
        }
        guard visibilityGeneration == nil else { return }

        let generation = UUID()
        visibilityGeneration = generation
        Task { @MainActor in
            await ForumService.shared.recordRecommendationEvent(
                postID: postID,
                type: .impression,
                context: context,
                visibleFraction: fraction
            )
            try? await Task.sleep(
                nanoseconds: UInt64(
                    ForumRecommendationVisibilityPolicy.qualifiedImpressionMilliseconds
                ) * 1_000_000
            )
            guard visibilityGeneration == generation else { return }
            await ForumService.shared.recordRecommendationEvent(
                postID: postID,
                type: .qualifiedImpression,
                context: context,
                visibleFraction: fraction,
                dwellMilliseconds: ForumRecommendationVisibilityPolicy
                    .qualifiedImpressionMilliseconds
            )
            try? await Task.sleep(
                nanoseconds: UInt64(
                    ForumRecommendationVisibilityPolicy.meaningfulReadMilliseconds
                    - ForumRecommendationVisibilityPolicy.qualifiedImpressionMilliseconds
                ) * 1_000_000
            )
            guard visibilityGeneration == generation else { return }
            await ForumService.shared.recordRecommendationEvent(
                postID: postID,
                type: .meaningfulRead,
                context: context,
                visibleFraction: fraction,
                dwellMilliseconds: ForumRecommendationVisibilityPolicy
                    .meaningfulReadMilliseconds
            )
        }
    }
}

// MARK: - Profile forum surface

/// Resolves the complete forum models needed by the shared forum renderer.
/// Profile RPCs intentionally return compact activity summaries, so profiles
/// batch-hydrate their forum rows instead of rebuilding a second card style.
@MainActor
final class ProfileForumPostLoader: ObservableObject {
    @Published private(set) var postsByID: [UUID: ForumPostItem] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var hasResolved = false
    @Published private(set) var errorMessage: String?

    private var activeRequestID: UUID?
    private var activeViewerID: UUID?

    func load(
        postIDs: [UUID],
        viewerID: UUID?,
        force: Bool = false
    ) async {
        var seen: Set<UUID> = []
        let uniqueIDs = postIDs.filter { seen.insert($0).inserted }
        let requestedIDs = Set(uniqueIDs)

        if activeViewerID != viewerID {
            activeViewerID = viewerID
            postsByID = [:]
            hasResolved = false
            errorMessage = nil
        }

        postsByID = postsByID.filter { requestedIDs.contains($0.key) }

        guard !uniqueIDs.isEmpty else {
            activeRequestID = nil
            isLoading = false
            hasResolved = true
            errorMessage = nil
            return
        }

        if !force {
            let cachedPosts = ForumService.shared.posts.filter {
                requestedIDs.contains($0.id)
            }
            for post in cachedPosts {
                postsByID[post.id] = post
            }
        }

        let unresolvedIDs = force
            ? uniqueIDs
            : uniqueIDs.filter { postsByID[$0] == nil }
        guard !unresolvedIDs.isEmpty else {
            activeRequestID = nil
            isLoading = false
            hasResolved = true
            errorMessage = nil
            return
        }

        let requestID = UUID()
        activeRequestID = requestID
        isLoading = true
        errorMessage = nil
        defer {
            if activeRequestID == requestID {
                isLoading = false
            }
        }

        do {
            let posts = try await ForumService.shared.fetchPosts(
                postIDs: unresolvedIDs
            )
            guard activeRequestID == requestID,
                  activeViewerID == viewerID
            else { return }
            for post in posts where requestedIDs.contains(post.id) {
                postsByID[post.id] = post
            }
            hasResolved = true
        } catch {
            guard activeRequestID == requestID,
                  activeViewerID == viewerID
            else { return }
            if error.isCancellationLike { return }
            hasResolved = true
            errorMessage = AppErrorMessage.userMessage(for: error)
        }
    }
}

/// The exact interactive forum card used inside profile surfaces. Management
/// controls remain an overlay owned by the current-user profile only.
struct ProfileForumPostCardView: View {
    let post: ForumPostItem
    let onTap: () -> Void
    var onShareTap: (() -> Void)?
    var onActionError: ((String) -> Void)?
    var showsOwnerAnonymousBadge = false

    @State private var isUpdatingLike = false
    @State private var isUpdatingFavorite = false

    var body: some View {
        ForumPostCardView(
            post: post,
            isOwnPost: false,
            onTap: onTap,
            onLikeTap: { await toggleLike() },
            onFavoriteTap: { await toggleFavorite() },
            onEditTap: nil,
            onShareTap: onShareTap
        )
        .overlay(alignment: .topTrailing) {
            if showsOwnerAnonymousBadge {
                Label("匿名 · 仅自己可见", systemImage: "eye.slash.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(AppColors.accent, in: Capsule())
                    .padding(.top, 9)
                    // Leave the far trailing edge free for the management menu.
                    .padding(.trailing, 46)
                    .allowsHitTesting(false)
                    .accessibilityLabel("匿名发布，仅自己可见")
            }
        }
    }

    @MainActor
    private func toggleLike() async {
        guard !isUpdatingLike else { return }
        isUpdatingLike = true
        defer { isUpdatingLike = false }

        let store = PostInteractionStore.shared
        let previous = store.state(
            for: post.id,
            fallbackLikeCount: post.likes,
            fallbackIsLiked: post.isLiked
        )
        let desiredIsLiked = !previous.isLiked
        guard store.beginLikeMutation(
            postID: post.id,
            desiredIsLiked: desiredIsLiked
        ) else { return }

        store.replace(
            postID: post.id,
            with: PostInteractionState(
                likeCount: max(
                    previous.likeCount + (desiredIsLiked ? 1 : -1),
                    0
                ),
                isLiked: desiredIsLiked,
                isFavorited: previous.isFavorited
            )
        )

        do {
            let confirmed = try await ForumService.shared.toggleLike(
                postId: post.id,
                currentlyLiked: previous.isLiked
            )
            store.finishLikeMutation(
                postID: post.id,
                committedIsLiked: confirmed
            )
        } catch {
            store.replace(postID: post.id, with: previous)
            store.finishLikeMutation(
                postID: post.id,
                committedIsLiked: nil
            )
            if !error.isCancellationLike {
                onActionError?(AppErrorMessage.userMessage(for: error))
            }
        }
    }

    @MainActor
    private func toggleFavorite() async {
        guard !isUpdatingFavorite else { return }
        isUpdatingFavorite = true
        defer { isUpdatingFavorite = false }

        let store = PostInteractionStore.shared
        let previous = store.state(
            for: post.id,
            fallbackLikeCount: post.likes,
            fallbackIsLiked: post.isLiked
        )
        store.setFavorite(
            postID: post.id,
            isFavorited: !previous.isFavorited
        )

        do {
            let confirmed = try await ForumService.shared.toggleFavorite(
                postId: post.id,
                currentlyFavorited: previous.isFavorited
            )
            store.setFavorite(postID: post.id, isFavorited: confirmed)
        } catch {
            store.replace(postID: post.id, with: previous)
            if !error.isCancellationLike {
                onActionError?(AppErrorMessage.userMessage(for: error))
            }
        }
    }
}
