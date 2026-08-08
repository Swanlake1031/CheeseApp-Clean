//
//  PostSharePresentation.swift
//  CheeseApp
//
//  App-level native share and Chat destination presentation.
//

import SwiftUI
import UIKit
import LinkPresentation

@MainActor
enum PostShareService {
    static func copyLink(for payload: PostSharePayload) {
        UIPasteboard.general.url = payload.canonicalURL
        UIPasteboard.general.string = payload.canonicalURL.absoluteString
    }
}

struct PostShareSheet: UIViewControllerRepresentable {
    let payload: PostSharePayload

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let source = PostShareItemSource(payload: payload)
        let controller = UIActivityViewController(
            activityItems: [source, payload.canonicalURL],
            applicationActivities: nil
        )
        controller.excludedActivityTypes = [.assignToContact, .saveToCameraRoll]
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private final class PostShareItemSource: NSObject, UIActivityItemSource {
    private let payload: PostSharePayload

    init(payload: PostSharePayload) {
        self.payload = payload
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        payload.composedText
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        payload.composedText
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        payload.title
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        PostShareMetadataFactory.make(for: payload)
    }
}

enum PostShareMetadataFactory {
    static let iconAssetName = "CheeseAppLogo"

    static func make(for payload: PostSharePayload) -> LPLinkMetadata {
        let metadata = LPLinkMetadata()
        metadata.title = payload.previewTitle
        metadata.originalURL = payload.canonicalURL
        metadata.url = payload.canonicalURL

        if let imageURL = payload.imageURL,
           let provider = NSItemProvider(contentsOf: imageURL) {
            metadata.imageProvider = provider
        }

        if let icon = appIcon() {
            metadata.iconProvider = NSItemProvider(object: icon)
        }

        return metadata
    }

    static func appIcon() -> UIImage? {
        UIImage(named: iconAssetName)?.withRenderingMode(.alwaysOriginal)
    }
}

@MainActor
enum ShareFeedbackPresenter {
    static func show(
        _ message: String,
        assign: @escaping @MainActor (String?) -> Void
    ) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            assign(message)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.2)) {
                    assign(nil)
                }
            }
        }
    }
}

private struct ShareFeedbackToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.82))
                        .clipShape(Capsule())
                        .padding(.top, 72)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
    }
}

extension View {
    func shareFeedbackToast(message: Binding<String?>) -> some View {
        modifier(ShareFeedbackToastModifier(message: message))
    }
}

struct CheesePostShareBottomSheet: View {
    let payload: PostSharePayload
    let onSent: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var chatService = ChatService.shared

    @State private var sendingTargetId: UUID?
    @State private var showSystemShareSheet = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var selectedTargetIDs: Set<UUID> = []
    @State private var shareNote = ""

    private var directTargets: [PostChatShareTarget] {
        var seen = Set<UUID>()
        let conversations = (chatService.conversations + chatService.messageRequests).filter {
            seen.insert($0.id).inserted
        }

        return conversations.map { conversation in
            PostChatShareTarget(
                id: conversation.id,
                kind: .direct(conversation),
                title: chatService.displayName(for: conversation),
                subtitle: conversationPreviewText(conversation),
                avatarURL: conversation.otherUserAvatar,
                lastActiveAt: conversation.lastMessageAt
            )
        }
    }

    private var groupTargets: [PostChatShareTarget] {
        chatService.groupConversations.map { group in
            PostChatShareTarget(
                id: group.id,
                kind: .group(group),
                title: group.displayName,
                subtitle: L10n.tr("Group · \(group.memberCount) people", "群聊 · \(group.memberCount)人"),
                avatarURL: group.avatarURL,
                lastActiveAt: group.lastMessageAt
            )
        }
    }

    private var recentTargets: [PostChatShareTarget] {
        (directTargets + groupTargets)
            .sorted { lhs, rhs in lhs.lastActiveAt > rhs.lastActiveAt }
    }

    private var selectedTargets: [PostChatShareTarget] {
        recentTargets.filter { selectedTargetIDs.contains($0.id) }
    }

    private var bottomSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }

    private var preferredSheetHeight: CGFloat {
        let minHeight: CGFloat = selectedTargets.isEmpty ? 284 : 392
        let maxHeight = UIScreen.main.bounds.height * 0.78
        return min(minHeight, maxHeight)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.black.opacity(0.12))
                    .frame(width: 38, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                HStack {
                    Text(L10n.tr("Share to", "分享给"))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppColors.textMuted)
                            .frame(width: 32, height: 32)
                            .background(Color.black.opacity(0.06))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)

                shareTargetsSection

                Divider()
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 12)

                ZStack(alignment: .top) {
                    if selectedTargets.isEmpty {
                        quickActionsSection
                    } else {
                        composeSection
                    }
                }
                .frame(maxWidth: .infinity, minHeight: selectedTargets.isEmpty ? 108 : 208, alignment: .topLeading)
                .padding(.horizontal, 18)
                .padding(.bottom, max(10, min(18, bottomSafeAreaInset * 0.45)))

                if let statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background((statusIsError ? Color.red : Color.black).opacity(0.82))
                        .clipShape(Capsule())
                        .padding(.bottom, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .scrollBounceBehavior(.basedOnSize)
        .background(
            AppColors.pageBackground
                .ignoresSafeArea()
        )
        .presentationDetents([.height(preferredSheetHeight)])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .presentationBackground(AppColors.pageBackground)
        .presentationCornerRadius(28)
        .task {
            await chatService.refreshConversations()
        }
        .onChange(of: recentTargets.map(\.id)) { _, latestIds in
            selectedTargetIDs = selectedTargetIDs.intersection(Set(latestIds))
        }
        .sheet(isPresented: $showSystemShareSheet) {
            PostShareSheet(payload: payload)
        }
    }

    @ViewBuilder
    private var shareTargetsSection: some View {
        if chatService.isLoadingConversations && recentTargets.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text(L10n.tr("Loading recent chats...", "正在加载最近聊天..."))
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 108)
        } else if recentTargets.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 30))
                    .foregroundStyle(AppColors.textMuted)
                Text(L10n.tr("No recent chats", "暂无可分享的聊天"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text(L10n.tr("Go to Messages first, then come back to share.", "先去消息页发起聊天，再回来分享。"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 108)
            .padding(.horizontal, 18)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(recentTargets.prefix(14)) { target in
                        Button {
                            toggleTargetSelection(target)
                        } label: {
                            PostChatShareTargetAvatar(
                                target: target,
                                isSending: sendingTargetId == target.id,
                                isSelected: selectedTargetIDs.contains(target.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(sendingTargetId != nil)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
            }
            .frame(height: 104)
        }
    }

    private var quickActionsSection: some View {
        HStack(alignment: .top, spacing: 10) {
            PostShareQuickActionButton(
                icon: "message.fill",
                title: L10n.tr("WeChat", "微信"),
                tint: AppColors.accent,
                iconColor: .black
            ) {
                showSystemShareSheet = true
            }

            PostShareQuickActionButton(
                icon: "paperplane.fill",
                title: L10n.tr("System Share", "系统分享"),
                tint: AppColors.accent,
                iconColor: .black
            ) {
                showSystemShareSheet = true
            }

            PostShareQuickActionButton(
                icon: "link",
                title: L10n.tr("Copy Link", "复制链接"),
                tint: AppColors.accent,
                iconColor: .black
            ) {
                UIPasteboard.general.string = payload.canonicalURL.absoluteString
                showStatus(L10n.tr("Link copied", "已复制链接"), isError: false)
            }

            PostShareQuickActionButton(
                icon: "doc.on.doc.fill",
                title: L10n.tr("Copy Text", "复制文案"),
                tint: AppColors.accent,
                iconColor: .black
            ) {
                UIPasteboard.general.string = payload.composedText
                showStatus(L10n.tr("Copied text", "已复制文案"), isError: false)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .padding(.top, 2)
    }

    private var composeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(
                L10n.tr("Say something to your friends...", "跟朋友说点什么吧..."),
                text: $shareNote,
                axis: .vertical
            )
            .textInputAutocapitalization(.sentences)
            .lineLimit(1...3)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(AppColors.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.05))
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: payload.kind.icon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(AppColors.accentStrong)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(payload.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                    if let subtitle = payload.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.textMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button {
                Task { await sendToSelectedTargets() }
            } label: {
                Text(L10n.tr("Send", "发送"))
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(red: 1, green: 0.2, blue: 0.35))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(sendingTargetId != nil)
        }
        .frame(maxWidth: .infinity, minHeight: 208, alignment: .topLeading)
    }

    private func conversationPreviewText(_ conversation: ChatConversationPreview) -> String {
        let preview = conversation.lastMessagePreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return preview.isEmpty ? L10n.tr("Direct message", "私信") : preview
    }

    private func toggleTargetSelection(_ target: PostChatShareTarget) {
        if selectedTargetIDs.contains(target.id) {
            selectedTargetIDs.remove(target.id)
        } else {
            selectedTargetIDs.insert(target.id)
        }
    }

    @MainActor
    private func sendToSelectedTargets() async {
        guard sendingTargetId == nil else { return }
        let targets = selectedTargets
        guard !targets.isEmpty else { return }

        let card = SharedPostCardMetadata(
            postKind: payload.kind.rawValue,
            postId: payload.postId,
            title: payload.title,
            subtitle: payload.subtitle,
            summary: payload.summary,
            imageURL: payload.imageURL?.absoluteString,
            authorName: AuthService.shared.currentUser?.fullName
        )
        let note = shareNote.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            for target in targets {
                sendingTargetId = target.id
                switch target.kind {
                case .direct(let conversation):
                    if !note.isEmpty {
                        _ = try await chatService.sendMessage(conversationId: conversation.id, content: note)
                    }
                    _ = try await chatService.sendSharedPostCardMessage(
                        conversationId: conversation.id,
                        card: card
                    )
                case .group(let group):
                    if !note.isEmpty {
                        _ = try await chatService.sendGroupMessage(groupId: group.id, content: note)
                    }
                    _ = try await chatService.sendGroupSharedPostCardMessage(
                        groupId: group.id,
                        card: card
                    )
                }
            }

            sendingTargetId = nil
            shareNote = ""
            selectedTargetIDs.removeAll()
            if targets.count == 1, let name = targets.first?.title {
                onSent(name)
            } else {
                onSent(L10n.tr("\(targets.count) chats", "\(targets.count)个聊天"))
            }
            dismiss()
        } catch {
            sendingTargetId = nil
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func showStatus(_ message: String, isError: Bool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            statusMessage = message
            statusIsError = isError
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeInOut(duration: 0.18)) {
                statusMessage = nil
            }
        }
    }
}

private struct PostChatShareTarget: Identifiable {
    enum Kind {
        case direct(ChatConversationPreview)
        case group(ChatGroupPreview)
    }

    let id: UUID
    let kind: Kind
    let title: String
    let subtitle: String
    let avatarURL: String?
    let lastActiveAt: Date
}

private struct PostChatShareTargetAvatar: View {
    let target: PostChatShareTarget
    let isSending: Bool
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let avatar = target.avatarURL,
                       let url = URL(string: avatar),
                       !avatar.isEmpty {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            avatarFallback
                        }
                    } else {
                        avatarFallback
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(
                            isSelected ? AppColors.accentStrong : Color.clear,
                            lineWidth: 2
                        )
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppColors.accentStrong)
                        .background(AppColors.pageBackground, in: Circle())
                        .offset(x: 3, y: 3)
                }

                if isSending {
                    Circle()
                        .fill(Color.black.opacity(0.36))
                        .frame(width: 56, height: 56)
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                }
            }

            Text(target.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                .frame(width: 68)

            Text(target.subtitle)
                .font(.system(size: 10))
                .foregroundStyle(AppColors.textMuted)
                .lineLimit(1)
                .frame(width: 68)
        }
        .frame(width: 68, alignment: .top)
        .contentShape(Rectangle())
    }

    private var avatarFallback: some View {
        Circle()
            .fill(AppColors.accent)
            .overlay {
                Text(String(target.title.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
            }
    }
}

private struct PostShareQuickActionButton: View {
    let icon: String
    let title: String
    let tint: Color
    var iconColor: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(iconColor)
                    }

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 68, alignment: .topLeading)
        }
        .buttonStyle(.plain)
    }
}
