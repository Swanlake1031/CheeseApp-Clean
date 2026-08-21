//
//  ForumListView.swift
//  CheeseApp
//
//  💬 论坛列表视图
//  展示论坛帖子，支持分类筛选
//

import SwiftUI
extension ForumPostItem {
    var editableSummary: UserPostSummary {
        UserPostSummary(
            id: id,
            kind: .forum,
            title: title,
            description: content,
            subtitle: boardName,
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
            subtitle: boardName,
            summary: content,
            imageURLs: imageUrls.compactMap(URL.init(string:))
        )
    }

    var forumFeedCardItem: HomeCardItem {
        let avatar = authorAvatar
            .flatMap(URL.init(string:))
            .map(ImageSource.url) ?? .placeholder

        return HomeCardItem(
            postId: id,
            authorId: authorId,
            image: imageUrls.first
                .flatMap(URL.init(string:))
                .map(ImageSource.url) ?? .placeholder,
            images: imageUrls
                .compactMap(URL.init(string:))
                .map(ImageSource.url),
            title: title,
            subtitle: content,
            footer: .posted(name: authorName, avatar: avatar),
            isAuthorMcMasterVerified: !isAnonymous && isAuthorMcMasterVerified,
            category: .forum,
            viewCount: views,
            badgeText: boardName,
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
    var headerStyle: ForumCardHeaderStyle = .board
    var onTap: (() -> Void)?
    var onLikeTap: (() async -> Void)?
    var onFavoriteTap: (() async -> Void)?
    var onEditTap: (() -> Void)?
    var onShareTap: (() -> Void)?
    var onBoardTap: (() -> Void)?

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
            forumHeaderStyle: headerStyle,
            onTap: onTap,
            onBoardTap: onBoardTap,
            onLikeTap: {
                Task { await onLikeTap?() }
            },
            onFavoriteTap: {
                Task { await onFavoriteTap?() }
            },
            onShareTap: onShareTap
        )
        .padding(.horizontal, 4)
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
            errorMessage = error.localizedDescription
        }
    }
}

/// The exact interactive forum card used inside profile surfaces. Management
/// controls remain an overlay owned by the current-user profile only.
struct ProfileForumPostCardView: View {
    let post: ForumPostItem
    let onTap: () -> Void
    var onBoardTap: (() -> Void)?
    var onShareTap: (() -> Void)?
    var onActionError: ((String) -> Void)?
    var showsOwnerAnonymousBadge = false

    @State private var isUpdatingLike = false
    @State private var isUpdatingFavorite = false

    var body: some View {
        ForumPostCardView(
            post: post,
            isOwnPost: false,
            headerStyle: .board,
            onTap: onTap,
            onLikeTap: { await toggleLike() },
            onFavoriteTap: { await toggleFavorite() },
            onEditTap: nil,
            onShareTap: onShareTap,
            onBoardTap: onBoardTap
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
                onActionError?(error.localizedDescription)
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
                onActionError?(error.localizedDescription)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ForumBoardView(
            boardID: UUID(
                uuidString: "f0000000-0000-0000-0000-000000000005"
            )!
        )
    }
}
