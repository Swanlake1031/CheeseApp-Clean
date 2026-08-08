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
}

// MARK: - 论坛帖子卡片
struct ForumPostCardView: View {
    @ObservedObject private var interactionStore = PostInteractionStore.shared

    let post: ForumPostItem
    let isOwnPost: Bool
    var onTap: (() -> Void)?
    var onLikeTap: (() async -> Void)?
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
        VStack(alignment: .leading, spacing: 12) {
            // 头部：分类 + 时间 + 置顶
            HStack {
                // 分类标签
                Button {
                    onBoardTap?()
                } label: {
                    HStack(spacing: 6) {
                    Image(systemName: post.boardIcon)
                        .font(.system(size: 10))
                    Text(post.boardName)
                        .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(.systemGray6))
                .cornerRadius(6)

                if post.isPinned {
                    HStack(spacing: 4) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                        Text(L10n.tr("Pinned", "置顶"))
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(AppColors.accentStrong)
                }

                Spacer()

                Text(post.timeAgo)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Menu {
                    if isOwnPost {
                        Button {
                            onEditTap?()
                        } label: {
                            Label(L10n.tr("Edit", "编辑"), systemImage: "square.and.pencil")
                        }
                    } else {
                        Label(L10n.tr("Open details to report", "进入详情后可检举"), systemImage: "flag")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.textMuted)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .tint(AppColors.textMuted)
            }

            // 作者信息
            HStack(spacing: 10) {
                if post.isAnonymous {
                    Circle()
                        .fill(Color(.systemGray4))
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: "theatermasks.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                        }

                    Text(L10n.tr("Anonymous", "匿名"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    if let authorId = post.authorId {
                        NavigationLink {
                            UserPostsView(userId: authorId)
                        } label: {
                            HStack(spacing: 10) {
                                postAvatar(size: 32)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 4) {
                                        Text(post.authorName)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(AppColors.textPrimary)
                                        if post.isAuthorMcMasterVerified {
                                            McMasterStudentBadge()
                                        }
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        postAvatar(size: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(post.authorName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppColors.textPrimary)
                                if post.isAuthorMcMasterVerified {
                                    McMasterStudentBadge()
                                }
                            }
                        }
                    }
                }
            }

            // 标题
            Text(post.title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 内容预览
            Text(post.content)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 图片预览（如果有）
            if post.hasImage {
                if let firstURLString = post.imageUrls.first, let url = URL(string: firstURLString) {
                    CachedRemoteImage(url: url, targetPixelWidth: 1024) { image in
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 150)
                            .clipped()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.14))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .tappableImagePreview(post.imageUrls, selected: firstURLString)
                }
            }

            Divider()

            // 底部：互动数据
            HStack(spacing: 6) {
                // 点赞
                HStack(spacing: 4) {
                    Button {
                        Task { await onLikeTap?() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: interaction.isLiked ? "heart.fill" : "heart")
                                .foregroundStyle(interaction.isLiked ? AppColors.likeActive : .secondary)
                            Text("\(interaction.likeCount)")
                                .monospacedDigit()
                                .foregroundStyle(interaction.isLiked ? AppColors.likeActive : AppColors.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 52, alignment: .leading)

                // 评论
                HStack(spacing: 4) {
                    Image(systemName: "bubble.right")
                    Text("\(post.comments)")
                        .monospacedDigit()
                }
                .frame(width: 52, alignment: .leading)

                // 浏览
                HStack(spacing: 4) {
                    Image(systemName: "eye")
                    Text("\(post.views)")
                        .monospacedDigit()
                }
                .frame(width: 52, alignment: .leading)

                Spacer()

                // 分享
                Button(action: { onShareTap?() }) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .cheeseCardChrome(cornerRadius: 20)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { onTap?() }
    }

    private func postAvatar(size: CGFloat) -> some View {
        Group {
            if let avatar = post.authorAvatar,
               let url = URL(string: avatar),
               !avatar.isEmpty {
                CachedRemoteImage(url: url, targetPixelWidth: 160) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    postAvatarFallback(size: size)
                }
            } else {
                postAvatarFallback(size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .tappableAvatarPreview(post.authorAvatar)
    }

    private func postAvatarFallback(size: CGFloat) -> some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [AppColors.accentStrong.opacity(0.95), AppColors.accent],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

}

#Preview {
    NavigationStack {
        ForumListView()
    }
}
