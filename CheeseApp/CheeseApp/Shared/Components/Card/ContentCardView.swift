//
//  ContentCardView.swift
//  CheeseApp
//
//  Reddit / 贴吧式首页信息流卡片。它只渲染 HomeCardItem 与提交用户意图，
//  真实点赞、收藏状态仍由 HomeViewModel 和现有全局 service 管理。
//

import SwiftUI

struct ContentCardView: View {
    let item: HomeCardItem
    var interaction: PostInteractionState?
    var onTap: (() -> Void)?
    var onBoardTap: (() -> Void)?
    var onAuthorTap: (() -> Void)?
    var onLikeTap: (() -> Void)?
    var onFavoriteTap: (() -> Void)?
    var onShareTap: (() -> Void)?

    var body: some View {
        Group {
            if item.isSeatRadar {
                seatRadarCard
            } else if item.category == .secondhand {
                secondhandCard
            } else {
                discussionCard
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { onTap?() }
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
    }

    private var discussionCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            if item.category == .forum {
                forumBoardHeader
            } else {
                metadataRow
            }

            if !item.image.isPlaceholder {
                HStack(alignment: .top, spacing: 12) {
                    discussionTextSummary

                    item.image.view(targetPixelWidth: 384)
                        .frame(width: 104, height: 104)
                        .clipped()
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 13,
                                style: .continuous
                            )
                        )
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: 13,
                                style: .continuous
                            )
                            .stroke(AppColors.cardBorder, lineWidth: 1)
                        }
                }
            } else {
                discussionTextSummary
            }

            interactionRow
        }
        .feedCardSurface()
    }

    private var discussionTextSummary: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(item.title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !item.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(item.subtitle)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(AppColors.textMuted)
                    .lineLimit(3)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var forumBoardHeader: some View {
        Button(action: { onBoardTap?() }) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(AppColors.accent.opacity(0.28))

                    Image(systemName: item.boardIcon ?? "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppColors.accentStrong)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(item.badgeText ?? item.category.localizedTitle)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AppColors.textPrimary)
                            .lineLimit(1)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AppColors.textMuted)
                    }

                    HStack(spacing: 5) {
                        Text(footerName)
                        if item.isAuthorMcMasterVerified {
                            McMasterStudentBadge()
                        }
                        if let timeText = item.timeText, !timeText.isEmpty {
                            Text("·")
                            Text(timeText)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColors.textMuted)
                    .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onBoardTap == nil)
        .accessibilityLabel(
            L10n.tr(
                "Open \(item.badgeText ?? "forum") board",
                "进入\(item.badgeText ?? "论坛")板块"
            )
        )
    }

    private var secondhandCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Button(action: { onAuthorTap?() }) {
                metadataRow
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onAuthorTap == nil)

            Text(item.title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(3)

            if let priceText = item.priceText {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(priceText)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(AppColors.accentStrong)

                    if let originalPriceText = item.originalPriceText {
                        Text(originalPriceText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppColors.textMuted)
                            .strikethrough(true, color: AppColors.textMuted)
                            .lineLimit(1)
                    }
                }
            }

            item.image.view(targetPixelWidth: 1024)
                .frame(maxWidth: .infinity)
                .frame(height: 210)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

            interactionRow
        }
        .feedCardSurface()
    }

    private var seatRadarCard: some View {
        HStack(spacing: 15) {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(AppColors.accent)
                .frame(width: 54, height: 54)
                .overlay {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.black)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Text(item.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "arrow.up.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppColors.accent)
        }
        .padding(17)
        .background(Color.black.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.13), radius: 13, y: 6)
    }

    private var metadataRow: some View {
        HStack(spacing: 8) {
            footerAvatar

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(footerName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)

                    if item.isAuthorMcMasterVerified {
                        McMasterStudentBadge()
                    }
                }

                HStack(spacing: 5) {
                    Text(item.badgeText ?? item.category.localizedTitle)
                    if let timeText = item.timeText, !timeText.isEmpty {
                        Text("·")
                        Text(timeText)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
                .lineLimit(1)
            }

            Spacer()

            Text(item.category.localizedTitle)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AppColors.textPrimary.opacity(0.76))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(AppColors.accent.opacity(0.2))
                .clipShape(Capsule())
        }
    }

    private var interactionRow: some View {
        HStack(spacing: 22) {
            if item.category != .secondhand {
                Button(action: { onLikeTap?() }) {
                    Label(
                        "\(interaction?.likeCount ?? item.likeCount)",
                        systemImage: interaction?.isLiked == true ? "heart.fill" : "heart"
                    )
                    .foregroundStyle(interaction?.isLiked == true ? AppColors.likeActive : AppColors.textMuted)
                }
                .disabled(onLikeTap == nil)
            }

            if item.category != .secondhand {
                Label("\(item.commentCount)", systemImage: "bubble.left")
                    .foregroundStyle(AppColors.textMuted)
            }

            Spacer()

            HStack(spacing: 12) {
                Button(action: { onFavoriteTap?() }) {
                    Image(systemName: interaction?.isFavorited == true ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(
                            interaction?.isFavorited == true
                                ? AppColors.accentStrong
                                : AppColors.textMuted
                        )
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .disabled(onFavoriteTap == nil)
                .accessibilityLabel(
                    Text(interaction?.isFavorited == true
                         ? L10n.tr("Remove saved post", "取消收藏")
                         : L10n.tr("Save post", "收藏帖子"))
                )

                Button(action: { onShareTap?() }) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(AppColors.textMuted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .disabled(onShareTap == nil)
                .accessibilityLabel(Text(L10n.tr("Share post", "分享帖子")))
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
    }

    @ViewBuilder
    private var footerAvatar: some View {
        switch item.footer {
        case .posted(_, let avatar), .hosted(_, let avatar):
            AvatarView(source: avatar, size: 32)
        case .avatars(_, let avatars):
            AvatarView(source: avatars.first ?? .placeholder, size: 32)
        case .none:
            AvatarView(source: .placeholder, size: 32)
        }
    }

    private var footerName: String {
        switch item.footer {
        case .posted(let name, _), .hosted(let name, _):
            return name
        case .avatars(let countText, _):
            return countText
        case .none:
            return L10n.tr("Campus user", "校园用户")
        }
    }
}

private extension View {
    func feedCardSurface() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .cheeseCardChrome(cornerRadius: 20)
    }
}

struct AvatarView: View {
    let source: ImageSource
    let size: CGFloat

    var body: some View {
        Group {
            if source.isPlaceholder {
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
                            .font(.system(size: size * 0.44, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            } else {
                source.view(targetPixelWidth: 160)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white, lineWidth: 1))
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 14) {
            ContentCardView(
                item: HomeCardItem(
                    title: "ECON 2H03 教授选谁比较好？",
                    subtitle: "想选一门 workload 稳定一点的课，有修过的同学可以分享一下吗？",
                    footer: .posted(name: "Mac 大二小土豆", avatar: .placeholder),
                    category: .forum,
                    badgeText: "校园",
                    timeText: "8 min",
                    likeCount: 28,
                    commentCount: 14
                ),
                interaction: PostInteractionState(likeCount: 28, isLiked: false, isFavorited: true)
            )
        }
        .padding()
    }
    .background(AppColors.pageBackground)
}
