//
//  ProfileView.swift
//  CheeseApp
//
//  👤 个人中心视图
//  展示真实用户信息、我的发布、设置等
//

import SwiftUI
import PhotosUI

private extension ProfileFollowListMode {
    var title: String {
        switch self {
        case .followers:
            return "粉丝"
        case .following:
            return "关注"
        }
    }

    var emptyText: String {
        switch self {
        case .followers:
            return "暂时还没有粉丝"
        case .following:
            return "你还没有关注任何人"
        }
    }
}

struct ProfileFollowListView: View {
    let userId: UUID
    let mode: ProfileFollowListMode

    @StateObject private var profileSocialService = ProfileSocialService.shared
    @State private var entries: [ProfileFollowListEntry] = []
    @State private var newFollowerCount = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var pendingEntryIDs: Set<UUID> = []
    @State private var unfollowedEntryIDs: Set<UUID> = []

    private var canManageFollowers: Bool {
        mode == .followers && AuthService.shared.currentUser?.id == userId
    }

    private var canManageFollowing: Bool {
        mode == .following && AuthService.shared.currentUser?.id == userId
    }

    private var showsRowManagementAction: Bool {
        canManageFollowers || canManageFollowing
    }

    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else if let errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textMuted)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
            } else if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.2")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text(mode.emptyText)
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.textMuted)
                }
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        if mode == .followers && newFollowerCount > 0 {
                            HStack(spacing: 8) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.red)
                                Text("新粉丝 \(newFollowerCount)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.red)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.08))
                        }

                        ForEach(entries) { entry in
                            HStack(spacing: 8) {
                                NavigationLink(destination: UserPostsView(userId: entry.id)) {
                                    profileRow(entry)
                                }
                                .buttonStyle(.plain)

                                if canManageFollowers {
                                    removeFollowerButton(entry)
                                        .padding(.trailing, 16)
                                } else if canManageFollowing {
                                    followingManagementButton(entry)
                                        .padding(.trailing, 16)
                                }
                            }

                            if entry.id != entries.last?.id {
                                Divider()
                                    .padding(.leading, 76)
                            }
                        }
                    }
                    .background(AppColors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .cheeseCardChrome(cornerRadius: 16)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(AppColors.pageBackground, for: .navigationBar)
        .task {
            await loadEntries()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ProfileSocialEvents.followingDidChange)
        ) { notification in
            guard canManageFollowing,
                  let (targetUserID, isFollowing) = ProfileSocialEvents.change(from: notification),
                  entries.contains(where: { $0.id == targetUserID })
            else { return }

            if isFollowing {
                unfollowedEntryIDs.remove(targetUserID)
            } else {
                unfollowedEntryIDs.insert(targetUserID)
            }
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { if !$0 { actionErrorMessage = nil } }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }

    private func profileRow(_ entry: ProfileFollowListEntry) -> some View {
        HStack(spacing: 12) {
            Group {
                if let avatarURL = entry.avatarURL,
                   let url = URL(string: avatarURL),
                   !avatarURL.isEmpty {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        avatarFallback(name: entry.displayName)
                    }
                } else {
                    avatarFallback(name: entry.displayName)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .tappableAvatarPreview(entry.avatarURL)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                if let subtitle = entry.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer()

            if entry.isNew {
                Text("新粉丝")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.1))
                    .clipShape(Capsule())
            }

            if !showsRowManagementAction {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppColors.cardBackground)
    }

    private func removeFollowerButton(_ entry: ProfileFollowListEntry) -> some View {
        Button {
            Task { await removeFollower(entry) }
        } label: {
            Group {
                if pendingEntryIDs.contains(entry.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Text("移除")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(Color.red)
            .frame(minWidth: 48)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(Color.red.opacity(0.08))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(pendingEntryIDs.contains(entry.id))
    }

    private func followingManagementButton(_ entry: ProfileFollowListEntry) -> some View {
        let isFollowing = !unfollowedEntryIDs.contains(entry.id)

        return Button {
            Task { await setFollowing(isFollowing: !isFollowing, entry: entry) }
        } label: {
            Group {
                if pendingEntryIDs.contains(entry.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Text(isFollowing ? "取消关注" : "关注")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(isFollowing ? AppColors.textPrimary : Color.black)
            .frame(minWidth: 60)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(isFollowing ? AppColors.pageBackground : AppColors.accent)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(
                        isFollowing ? AppColors.textMuted.opacity(0.25) : Color.clear,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(pendingEntryIDs.contains(entry.id))
        .accessibilityLabel("\(isFollowing ? "取消关注" : "关注")\(entry.displayName)")
    }

    private func avatarFallback(name: String) -> some View {
        Circle()
            .fill(AppColors.accent.opacity(0.22))
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
            }
    }

    @MainActor
    private func loadEntries() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let snapshot = try await profileSocialService.loadFollowList(userId: userId, mode: mode)
            entries = snapshot.entries
            unfollowedEntryIDs.removeAll()
            newFollowerCount = snapshot.newFollowerCount
        } catch {
            entries = []
            newFollowerCount = 0
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func removeFollower(_ entry: ProfileFollowListEntry) async {
        guard !pendingEntryIDs.contains(entry.id) else { return }
        pendingEntryIDs.insert(entry.id)
        defer { pendingEntryIDs.remove(entry.id) }

        do {
            try await profileSocialService.removeFollower(followerUserId: entry.id)
            entries.removeAll { $0.id == entry.id }
            if entry.isNew {
                newFollowerCount = max(0, newFollowerCount - 1)
            }
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func setFollowing(isFollowing: Bool, entry: ProfileFollowListEntry) async {
        guard canManageFollowing,
              !pendingEntryIDs.contains(entry.id)
        else { return }
        pendingEntryIDs.insert(entry.id)
        defer { pendingEntryIDs.remove(entry.id) }

        do {
            if isFollowing {
                try await profileSocialService.follow(targetUserId: entry.id)
                unfollowedEntryIDs.remove(entry.id)
            } else {
                try await profileSocialService.unfollow(targetUserId: entry.id)
                unfollowedEntryIDs.insert(entry.id)
            }
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - 编辑资料视图
