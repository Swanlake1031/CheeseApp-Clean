//
//  ContentCardView.swift
//  CheeseApp
//
//  Reddit / 贴吧式首页信息流卡片。它只渲染 HomeCardItem 与提交用户意图，
//  真实点赞、收藏状态仍由 HomeViewModel 和现有全局 service 管理。
//

import SwiftUI

enum ForumCardHeaderStyle {
    case board
    case author
}

struct ContentCardView: View {
    let item: HomeCardItem
    var interaction: PostInteractionState?
    var forumHeaderStyle: ForumCardHeaderStyle = .board
    var presentsSecondhandAsForumBoard = false
    var usesSecondhandRowSurface = false
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
        VStack(
            alignment: .leading,
            spacing: item.category == .forum ? 9 : 13
        ) {
            if item.category == .forum {
                switch forumHeaderStyle {
                case .board:
                    forumBoardHeader
                case .author:
                    forumAuthorHeader
                }
            } else {
                metadataRow
            }

            discussionTextSummary

            if !item.images.isEmpty {
                FeedMediaStrip(
                    images: item.images,
                    metrics: .forum
                )
            }

            interactionRow
                .padding(
                    .top,
                    item.category == .forum ? -4 : 0
                )
        }
        .modifier(
            DiscussionFeedSurfaceModifier(
                isForum: item.category == .forum
            )
        )
    }

    private var discussionTextSummary: some View {
        VStack(
            alignment: .leading,
            spacing: item.category == .forum ? 8 : 13
        ) {
            Text(displayTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !displaySubtitle.isEmpty {
                Text(displaySubtitle)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(AppColors.textMuted)
                    .lineLimit(3)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Feed previews must not reserve layout rows for backend-authored leading or
    /// trailing newlines. The detail screen still receives the unmodified content.
    private var displayTitle: String {
        item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displaySubtitle: String {
        item.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var forumBoardHeader: some View {
        HStack(spacing: 10) {
            Button(action: { onBoardTap?() }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(AppColors.accent.opacity(0.28))

                    Image(systemName: item.boardIcon ?? "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppColors.accentStrong)
                }
                .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .disabled(onBoardTap == nil)
            .accessibilityLabel(forumBoardAccessibilityLabel)

            VStack(alignment: .leading, spacing: 3) {
                Button(action: { onBoardTap?() }) {
                    HStack(spacing: 5) {
                        Text(item.badgeText ?? item.category.localizedTitle)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AppColors.textPrimary)
                            .lineLimit(1)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AppColors.textMuted)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .disabled(onBoardTap == nil)
                .accessibilityLabel(forumBoardAccessibilityLabel)

                boardMetadataRow
            }

            Spacer(minLength: 0)
        }
    }

    private var forumBoardAccessibilityLabel: String {
        L10n.tr(
            "Open \(item.badgeText ?? "forum") board",
            "进入\(item.badgeText ?? "论坛")板块"
        )
    }

    /// A board page already establishes the category in its own header, so its
    /// rows identify the author instead. Mixed feeds keep the board header.
    private var forumAuthorHeader: some View {
        HStack(spacing: 10) {
            footerAvatar

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(footerName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)

                    if item.isAuthorMcMasterVerified {
                        McMasterStudentBadge()
                    }
                }

                if let timeText = item.timeText, !timeText.isEmpty {
                    Text(timeText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColors.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var secondhandCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            secondhandHeader

            secondhandTitleAndPrice

            if !displaySubtitle.isEmpty {
                Text(displaySubtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.textMuted)
                    .lineLimit(2)
                    .lineSpacing(2)
            }

            if !item.images.isEmpty {
                FeedMediaStrip(
                    images: item.images,
                    metrics: .secondhand,
                    targetPixelWidth: 900
                )
            }

            interactionRow
        }
        .modifier(
            SecondhandFeedSurfaceModifier(
                usesRowPresentation: presentsSecondhandAsForumBoard
                    || usesSecondhandRowSurface
            )
        )
    }

    private var secondhandTitleAndPrice: some View {
        VStack(
            alignment: .leading,
            spacing: presentsSecondhandAsForumBoard ? 7 : 13
        ) {
            Text(displayTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var secondhandHeader: some View {
        if presentsSecondhandAsForumBoard {
            secondhandBoardHeader
        } else {
            Button(action: { onAuthorTap?() }) {
                metadataRow
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onAuthorTap == nil)
        }
    }

    /// Recommended is a mixed feed, so marketplace posts identify their product
    /// surface exactly where forum posts identify their board. The existing
    /// marketplace capsule remains on the trailing edge as a quick content-type
    /// marker, while seller and timestamp occupy the secondary line.
    private var secondhandBoardHeader: some View {
        HStack(spacing: 10) {
            Button(action: { onBoardTap?() }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(AppColors.accent.opacity(0.28))

                    Image(systemName: "bag.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppColors.accentStrong)
                }
                .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .disabled(onBoardTap == nil)
            .accessibilityLabel(L10n.tr("Open Secondhand", "进入二手板块"))

            VStack(alignment: .leading, spacing: 3) {
                Button(action: { onBoardTap?() }) {
                    HStack(spacing: 5) {
                        Text(item.category.localizedTitle)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AppColors.textPrimary)
                            .lineLimit(1)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AppColors.textMuted)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .disabled(onBoardTap == nil)
                .accessibilityLabel(L10n.tr("Open Secondhand", "进入二手板块"))

                boardMetadataRow
            }

            Spacer(minLength: 8)

            categoryCapsule
        }
    }

    private var boardMetadataRow: some View {
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

            categoryCapsule
        }
    }

    private var categoryCapsule: some View {
        Text(item.category.localizedTitle)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(AppColors.textPrimary.opacity(0.76))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(AppColors.accent.opacity(0.2))
            .clipShape(Capsule())
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
                    Image(systemName: interaction?.isFavorited == true ? "star.fill" : "star")
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
    func plainFeedCardSurface() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    func feedCardSurface() -> some View {
        plainFeedCardSurface()
            .cheeseCardChrome(cornerRadius: 20)
    }
}

private struct DiscussionFeedSurfaceModifier: ViewModifier {
    let isForum: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isForum {
            content
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Divider()
                        .overlay(AppColors.divider)
                }
        } else {
            content.feedCardSurface()
        }
    }
}

private struct SecondhandFeedSurfaceModifier: ViewModifier {
    let usesRowPresentation: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesRowPresentation {
            content
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Divider()
                        .overlay(AppColors.divider)
                }
        } else {
            content.plainFeedCardSurface()
        }
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
