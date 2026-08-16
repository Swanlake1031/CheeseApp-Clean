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

#Preview {
    NavigationStack {
        ForumBoardView(
            boardID: UUID(
                uuidString: "f0000000-0000-0000-0000-000000000005"
            )!
        )
    }
}
