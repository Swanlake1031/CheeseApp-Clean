//
//  ChatRoomView.swift
//  CheeseApp
//
//  💬 单聊会话页
//

import SwiftUI

struct ChatMessageContentView: View {
    let message: Message
    let isMine: Bool
    let onOpenPostRoute: (PostDeepLinkRoute) -> Void
    let onOpenSharedPost: (SharedPostCardMetadata) -> Void

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
            if let quotedMessage = message.metadata?.quotedMessage {
                ChatQuotedMessageView(quotedMessage: quotedMessage, isMine: isMine)
            }
            messageContentView(message, isMine: isMine)
        }
    }

    private func messageContentView(_ message: Message, isMine: Bool) -> some View {
        Group {
            if let card = message.metadata?.postContactCard {
                postContactCardView(card: card, isMine: isMine)
            } else if let card = message.metadata?.sharedPostCard {
                ChatSharedPostCardView(card: card, onOpen: onOpenSharedPost)
            } else if message.messageType == "image",
                      let reference = message.metadata?.chatMediaReference,
                      reference.belongs(to: .direct, id: message.conversationId) {
                ChatPrivateMediaImageView(reference: reference)
            } else if message.messageType == "image" {
                ChatPrivateMediaUnavailableView()
            } else {
                Text(message.content)
                    .font(.system(size: 15))
                    .foregroundStyle(isMine ? .black : AppColors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isMine ? AppColors.chatOutgoingBubble : Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                isMine ? Color.clear : Color.black.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            }
        }
    }

    private func postContactCardView(card: PostContactCardMetadata, isMine: Bool) -> some View {
        let presentation = postContactCardPresentation(for: card.postKind)
        let requesterName = card.requesterName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let postRoute: PostDeepLinkRoute? = {
            guard let postId = card.postId,
                  let kind = PostKind(remoteValue: card.postKind) else {
                return nil
            }
            return PostDeepLinkRoute(kind: kind, postId: postId)
        }()

        return richMessageCard(tint: presentation.tint) {
            messageCardHeader(
                icon: presentation.icon,
                title: presentation.title,
                tint: presentation.tint,
                chipText: presentation.kindText,
                showsDisclosure: postRoute != nil
            )

            messageCardHeroImage(
                imageURL: card.imageURL,
                icon: presentation.icon,
                tint: presentation.tint
            )

            VStack(alignment: .leading, spacing: 8) {
                if let requesterName, !requesterName.isEmpty {
                    Text(
                        isMine
                            ? L10n.tr("Card sent with the original post preview", "已附上帖子卡片，方便对方快速识别")
                            : "\(requesterName) 想联系你"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted)
                }

                Text(card.title)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(3)

                if let subtitle = card.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(presentation.tint)
                        .lineLimit(2)
                }

                if let summary = card.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textMuted)
                        .lineSpacing(3)
                        .lineLimit(4)
                }
            }

            if let note = card.note?.trimmingCharacters(in: .whitespacesAndNewlines),
               !note.isEmpty {
                messageCardNote(note, tint: presentation.tint)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            guard let postRoute else { return }
            onOpenPostRoute(postRoute)
        }
    }

    private func richMessageCard<Content: View>(
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .foregroundStyle(AppColors.textPrimary)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(0.04),
            radius: 10,
            x: 0,
            y: 4
        )
    }

    private func messageCardHeader(
        icon: String,
        title: String,
        tint: Color,
        chipText: String,
        showsDisclosure: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.14))

                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tint)
                }
                .frame(width: 30, height: 30)

                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if showsDisclosure {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint.opacity(0.9))
                }
                messageCardPill(chipText, tint: tint)
            }
        }
    }

    private func messageCardPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.14), lineWidth: 1)
            )
    }

    private func messageCardNote(_ note: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("Note", "附言"))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)

            Text(note)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColors.textPrimary)
                .lineSpacing(3)
                .lineLimit(4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.08))
        )
    }

    @ViewBuilder
    private func messageCardHeroImage(imageURL: String?, icon: String, tint: Color) -> some View {
        if let imageURL,
           let url = URL(string: imageURL),
           !imageURL.isEmpty {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    LinearGradient(
                        colors: [tint.opacity(0.28), tint.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(tint.opacity(0.8))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
        } else {
            LinearGradient(
                colors: [tint.opacity(0.28), tint.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(alignment: .leading) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.26))

                        Image(systemName: icon)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .frame(width: 54, height: 54)

                    Text(L10n.tr("Post Preview", "帖子预览"))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.95))

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func postContactCardPresentation(for postKind: String) -> (title: String, kindText: String, icon: String, tint: Color) {
        switch postKind.lowercased() {
        case PostKind.secondhand.rawValue:
            return (
                L10n.tr("Seller Contact Card", "卖家联系卡"),
                L10n.tr("Secondhand", "二手"),
                "bag.fill",
                AppColors.categoryColor(for: "secondhand")
            )
        case PostKind.forum.rawValue:
            return (
                L10n.tr("Author Contact Card", "作者联系卡"),
                L10n.tr("Forum", "论坛"),
                "bubble.left.and.bubble.right.fill",
                AppColors.categoryColor(for: "forum")
            )
        default:
            return (
                L10n.tr("Contact Card", "联系卡"),
                postKind.capitalized,
                "message.fill",
                AppColors.link
            )
        }
    }

}

/// Canonical timeline presentation for a post shared into direct or group chat.
/// Shared content is a card in its own right, so it deliberately does not inherit
/// the sender's yellow text-bubble background.
struct ChatSharedPostCardView: View {
    let card: SharedPostCardMetadata
    let onOpen: (SharedPostCardMetadata) -> Void

    private var presentation: (kindText: String, icon: String, tint: Color) {
        switch PostKind(remoteValue: card.postKind) {
        case .forum:
            return (
                L10n.tr("Forum", "论坛"),
                "bubble.left.and.bubble.right.fill",
                AppColors.categoryColor(for: "forum")
            )
        case .secondhand:
            return (
                L10n.tr("Secondhand", "二手"),
                "bag.fill",
                AppColors.categoryColor(for: "secondhand")
            )
        default:
            return (card.postKind.capitalized, "doc.text.image.fill", AppColors.link)
        }
    }

    private var imageURL: URL? {
        guard let value = card.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return URL(string: value)
    }

    var body: some View {
        let presentation = presentation

        Button {
            onOpen(card)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(presentation.tint.opacity(0.14))

                        Image(systemName: presentation.icon)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(presentation.tint)
                    }
                    .frame(width: 30, height: 30)

                    Text(L10n.tr("Shared Post Card", "帖子分享卡"))
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(presentation.tint.opacity(0.9))

                    Text(presentation.kindText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(presentation.tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(presentation.tint.opacity(0.12))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(presentation.tint.opacity(0.14), lineWidth: 1)
                        )
                }

                if let imageURL {
                    CachedRemoteImage(url: imageURL, targetPixelWidth: 720) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        LinearGradient(
                            colors: [
                                presentation.tint.opacity(0.22),
                                presentation.tint.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.black.opacity(0.05), lineWidth: 1)
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr(
                        "Post preview attached. Tap to view details.",
                        "已附上帖子卡片，点击查看详情"
                    ))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted)

                    Text(card.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(3)

                    if let subtitle = card.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(presentation.tint)
                            .lineLimit(2)
                    }

                    if let summary = card.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 13))
                            .foregroundStyle(AppColors.textMuted)
                            .lineSpacing(3)
                            .lineLimit(4)
                    }

                    if let authorName = card.authorName?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !authorName.isEmpty {
                        Text(authorName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppColors.textMuted)
                            .lineLimit(1)
                    }
                }
            }
            .foregroundStyle(AppColors.textPrimary)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(presentation.tint.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(L10n.tr("Shared Post", "分享帖子"))：\(card.title)"))
    }
}

struct ChatQuotedMessageView: View {
    let quotedMessage: QuotedMessageMetadata
    let isMine: Bool

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(isMine ? Color.black.opacity(0.45) : AppColors.link)
                .frame(width: 2, height: 16)

            (
                Text("\(quotedMessage.senderName)：")
                    .fontWeight(.semibold)
                + Text(quotedMessage.displayPreview)
            )
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(AppColors.textMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 220, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isMine ? AppColors.chatOutgoingBubble.opacity(0.72) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}

struct ChatPrivateMediaImageView: View {
    let reference: ChatMediaReference
    var width: CGFloat = 180
    var height: CGFloat = 180
    var loader: ChatMediaDataLoader = .live

    @State private var image: UIImage?
    @State private var didFail = false
    @State private var showsPreview = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { showsPreview = true }
            } else if didFail {
                ChatPrivateMediaUnavailableView(width: width, height: height)
            } else {
                ZStack {
                    Color.gray.opacity(0.15)
                    ProgressView()
                }
                .frame(width: width, height: height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: reference) {
            image = nil
            didFail = false
            do {
                let data = try await loader.loadData(for: reference)
                try Task.checkCancellation()
                guard let loaded = UIImage(data: data) else {
                    throw ChatMediaLoadError.invalidResponse
                }
                image = loaded
            } catch is CancellationError {
                return
            } catch {
                didFail = true
            }
        }
        .fullScreenCover(isPresented: $showsPreview) {
            if let image {
                LocalImagePreviewView(image: image)
                    .presentationBackground(.clear)
            }
        }
    }
}

struct ChatPrivateMediaUnavailableView: View {
    var width: CGFloat = 180
    var height: CGFloat = 180

    var body: some View {
        ZStack {
            Color.gray.opacity(0.15)
            VStack(spacing: 6) {
                Image(systemName: "lock.fill")
                Text("图片不可用")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(AppColors.textMuted)
        }
        .frame(width: width, height: height)
    }
}
