import SwiftUI

struct GroupChatDetailsView: View {
    let onLeftGroup: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: GroupChatDetailsViewModel

    init(group: ChatGroupPreview, onLeftGroup: @escaping () -> Void) {
        self.onLeftGroup = onLeftGroup
        _viewModel = StateObject(wrappedValue: GroupChatDetailsViewModel(group: group))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                header
                muteCard
                membersCard
                leaveButton

                if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(AppColors.pageBackground.ignoresSafeArea())
        .cheesePageTopBar(title: "群聊详情")
        .cheeseTabBarHidden(true)
        .task {
            await viewModel.loadIfNeeded()
        }
        .alert(item: $viewModel.alertDestination) { destination in
            alert(for: destination)
        }
        .navigationDestination(item: $viewModel.profileUserID) { userID in
            UserPostsView(userId: userID)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            groupAvatar
                .frame(width: 86, height: 86)
                .clipShape(Circle())
                .tappableImagePreview(viewModel.group.avatarURL)

            Text(viewModel.group.displayName)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)

            Text("\(viewModel.effectiveMemberCount) 人")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textMuted)
        }
        .padding(.top, 8)
    }

    private var muteCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)

            Text("消息免打扰")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AppColors.textPrimary)

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { viewModel.isMuted },
                    set: viewModel.setMuted
                )
            )
            .labelsHidden()
            .tint(AppColors.textPrimary)
            .disabled(viewModel.isSavingMute || viewModel.isLeaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .cheeseCardChrome(cornerRadius: 16)
    }

    private var membersCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("群成员")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Text("\(viewModel.effectiveMemberCount)")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if viewModel.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("正在加载成员...")
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            } else if viewModel.members.isEmpty {
                Text("暂无成员数据")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            } else {
                ForEach(viewModel.members) { member in
                    GroupDetailMemberRow(
                        member: member,
                        canRemove: viewModel.isOwner && member.role != "owner",
                        onOpenProfile: {
                            viewModel.profileUserID = member.id
                        },
                        onRemove: {
                            viewModel.requestRemoval(of: member)
                        }
                    )

                    if member.id != viewModel.members.last?.id {
                        Divider()
                            .padding(.leading, 70)
                    }
                }
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .cheeseCardChrome(cornerRadius: 16)
    }

    private var leaveButton: some View {
        Button(role: .destructive) {
            viewModel.requestLeave()
        } label: {
            HStack {
                Text(viewModel.isOwner ? "解散群聊" : "退出群聊")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if viewModel.isLeaving {
                    ProgressView()
                        .scaleEffect(0.9)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .cheeseCardChrome(cornerRadius: 16)
        }
        .buttonStyle(CheeseContainerButtonStyle())
        .disabled(viewModel.isLeaving || viewModel.isLoading)
        .padding(.bottom, 74)
    }

    private var groupAvatar: some View {
        Group {
            if let avatar = viewModel.group.avatarURL,
               let url = URL(string: avatar),
               !avatar.isEmpty {
                CachedRemoteImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    avatarFallback
                }
            } else {
                avatarFallback
            }
        }
    }

    private var avatarFallback: some View {
        Circle()
            .fill(AppColors.accent.opacity(0.2))
            .overlay {
                Text(String(viewModel.group.displayName.prefix(1)).uppercased())
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
            }
    }

    private func alert(for destination: GroupChatDetailsAlertDestination) -> Alert {
        switch destination {
        case .leave:
            return Alert(
                title: Text(viewModel.leaveAlertTitle),
                message: Text(viewModel.leaveAlertMessage),
                primaryButton: .cancel(Text("取消")),
                secondaryButton: .destructive(
                    Text(viewModel.isOwner ? "解散" : "退出")
                ) {
                    Task {
                        if await viewModel.leaveGroup() {
                            dismiss()
                            onLeftGroup()
                        }
                    }
                }
            )
        case .removeMember(let member):
            return Alert(
                title: Text("移出该成员？"),
                message: Text("\(member.displayName) 将被移出该群聊。"),
                primaryButton: .cancel(Text("取消")),
                secondaryButton: .destructive(Text("移出")) {
                    Task { await viewModel.removeMember(member) }
                }
            )
        }
    }
}

private struct GroupDetailMemberRow: View {
    let member: ChatGroupMemberSummary
    let canRemove: Bool
    let onOpenProfile: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpenProfile) {
                HStack(spacing: 12) {
                    avatarView
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)

                        Text(member.roleLabel)
                            .font(.system(size: 12))
                            .foregroundStyle(
                                member.role == "owner"
                                    ? AppColors.textPrimary
                                    : AppColors.textMuted
                            )
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.92))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white)
    }

    private var avatarView: some View {
        Group {
            if let avatar = member.avatarURL,
               let url = URL(string: avatar),
               !avatar.isEmpty {
                CachedRemoteImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    avatarFallback
                }
            } else {
                avatarFallback
            }
        }
    }

    private var avatarFallback: some View {
        Circle()
            .fill(AppColors.accent.opacity(0.18))
            .overlay {
                Text(String(member.displayName.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
            }
    }
}
