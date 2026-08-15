import SwiftUI

struct ChatFollowSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = ChatFollowSearchViewModel()
    @State private var profileRoute: ChatFollowProfileRoute?

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.pageBackground
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    ChatInboxSearchField(
                        placeholder: "搜索名字、学校、地区或 UID",
                        text: Binding(
                            get: { viewModel.query },
                            set: { viewModel.updateQuery($0) }
                        )
                    )

                    content
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 20)
            }
            .navigationTitle("添加好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .navigationDestination(item: $profileRoute) { route in
                UserPostsView(userId: route.id)
            }
            .onReceive(NotificationCenter.default.publisher(for: ProfileSocialEvents.followingDidChange)) { notification in
                guard let (targetUserID, isFollowing) = ProfileSocialEvents.change(
                    from: notification
                ) else { return }
                viewModel.applyFollowChange(
                    targetUserID: targetUserID,
                    isFollowing: isFollowing
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
            VStack(spacing: 12) {
                InlineErrorBanner(text: errorMessage)

                if !viewModel.results.isEmpty {
                    resultsList
                } else {
                    Spacer()
                }
            }
        } else if viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyPrompt(
                icon: "person.2.wave.2",
                title: "搜索想添加的人",
                message: "可以按昵称、学校、地区或 UID 查找，找到后可查看主页或关注。"
            )
        } else if viewModel.isLoading && viewModel.results.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在搜索用户...")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.results.isEmpty {
            emptyPrompt(
                icon: "magnifyingglass",
                title: "没有找到匹配用户",
                message: "试试昵称、学校、地区，或输入完整 UID。"
            )
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(viewModel.results) { profile in
                    ChatFollowSearchRow(
                        profile: profile,
                        isBusy: viewModel.isToggling(profile.id),
                        onOpenProfile: {
                            profileRoute = ChatFollowProfileRoute(id: profile.id)
                        },
                        onToggleFollow: {
                            Task { await viewModel.toggleFollow(for: profile) }
                        }
                    )

                    if profile.id != viewModel.results.last?.id {
                        Divider()
                            .padding(.leading, 74)
                    }
                }
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .cheeseCardChrome(cornerRadius: 18)
            .padding(.bottom, 24)
        }
    }

    private func emptyPrompt(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(AppColors.textMuted)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
    }
}

struct GroupChatRow: View {
    let group: ChatGroupPreview

    var body: some View {
        HStack(spacing: 14) {
            avatarView

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(group.displayName)
                        .font(.system(size: 15, weight: .semibold))

                    Spacer()

                    HStack(spacing: 6) {
                        Text(formatTime(group.lastMessageAt))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if group.isMuted {
                            Image(systemName: "bell.slash.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppColors.textMuted.opacity(0.9))
                        }
                    }
                }

                Text(group.lastMessagePreview?.isEmpty == false ? group.lastMessagePreview! : "还没有消息")
                    .font(.system(size: 13))
                    .foregroundStyle(group.unreadCount > 0 ? .primary : .secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(group.memberCount) 人")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColors.textMuted)
                }
            }

            if group.unreadCount > 0 {
                Text("\(group.unreadCount)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppColors.accent)
                    .clipShape(Capsule())
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white)
    }

    private var avatarView: some View {
        Group {
            if let avatar = group.avatarURL,
                      let url = URL(string: avatar),
                      !avatar.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        avatarFallback
                    }
                }
            } else {
                avatarFallback
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(Circle())
        .tappableImagePreview(group.avatarURL)
    }

    private var avatarFallback: some View {
        Circle()
            .fill(AppColors.accent.opacity(0.24))
            .overlay {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
            }
    }

    private func formatTime(_ date: Date) -> String {
        ChatListTimeFormatter.string(from: date)
    }
}

struct MutualFollowSelectionRow: View {
    let profile: MutualFollowProfile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let avatarURL = profile.avatarURL,
                   let url = URL(string: avatarURL),
                   !avatarURL.isEmpty {
                    CachedRemoteImage(url: url, targetPixelWidth: 128) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        avatarFallback
                    }
                } else {
                    avatarFallback
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(Circle())
            .tappableAvatarPreview(profile.avatarURL)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.fullName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                if let university = profile.university, !university.isEmpty {
                    Text(university)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textMuted)
                }
            }

            Spacer()

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isSelected ? AppColors.textPrimary : AppColors.textMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white)
    }

    private var avatarFallback: some View {
        Circle()
            .fill(AppColors.accent.opacity(0.2))
            .overlay {
                Text(String(profile.fullName.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
            }
    }
}

private struct ChatFollowSearchRow: View {
    let profile: SearchProfileResult
    let isBusy: Bool
    let onOpenProfile: () -> Void
    let onToggleFollow: () -> Void

    private var followButtonText: String {
        if profile.isMutualFollow {
            return "互相关注"
        }
        if profile.isFollowing {
            return "已关注"
        }
        return "关注"
    }

    private var secondaryText: String? {
        let university = profile.university?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let university, !university.isEmpty {
            return university
        }
        if let bio = profile.bio?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
            return bio
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpenProfile) {
                HStack(spacing: 12) {
                    avatar

                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.fullName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)

                        if let secondaryText {
                            Text(secondaryText)
                                .font(.system(size: 12))
                                .foregroundStyle(AppColors.textMuted)
                                .lineLimit(2)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            Button(action: onToggleFollow) {
                HStack(spacing: 6) {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(followButtonText)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(profile.isFollowing ? AppColors.textPrimary : Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    profile.isFollowing
                    ? AppColors.textPrimary.opacity(0.08)
                    : AppColors.accent
                )
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white)
    }

    private var avatar: some View {
        Group {
            if let avatarURL = profile.avatarURL,
               let url = URL(string: avatarURL),
               !avatarURL.isEmpty {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    avatarFallback
                }
            } else {
                avatarFallback
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(Circle())
        .tappableAvatarPreview(profile.avatarURL)
    }

    private var avatarFallback: some View {
        Circle()
            .fill(AppColors.accent.opacity(0.2))
            .overlay {
                Text(String(profile.fullName.prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
            }
    }
}

struct ChatUserProfileRoute: Identifiable, Hashable {
    let id: UUID
}

private struct ChatFollowProfileRoute: Identifiable, Hashable {
    let id: UUID
}
