//
//  ProfileSocialViews.swift
//  CheeseApp
//
//  关注、粉丝与互关共享的横向分页关系列表。
//

import SwiftUI

private extension ProfileFollowListMode {
    var title: String {
        switch self {
        case .following:
            return "关注"
        case .followers:
            return "粉丝"
        case .mutual:
            return "互关"
        }
    }

    var emptyText: String {
        switch self {
        case .following:
            return "你还没有关注任何人"
        case .followers:
            return "暂时还没有粉丝"
        case .mutual:
            return "暂时还没有互关好友"
        }
    }
}

struct ProfileFollowListView: View {
    let userId: UUID
    let mode: ProfileFollowListMode

    @StateObject private var profileSocialService = ProfileSocialService.shared
    @State private var selectedMode: ProfileFollowListMode
    @State private var snapshot = ProfileFollowListsSnapshot(
        following: [],
        followers: []
    )
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var pendingEntryIDs: Set<UUID> = []

    init(userId: UUID, mode: ProfileFollowListMode) {
        self.userId = userId
        self.mode = mode
        _selectedMode = State(initialValue: mode)
    }

    private var canManageRelationships: Bool {
        AuthService.shared.currentUser?.id == userId
    }

    var body: some View {
        VStack(spacing: 0) {
            relationshipTabs

            Divider()
                .overlay(AppColors.divider)

            TabView(selection: $selectedMode) {
                ForEach(ProfileFollowListMode.allCases) { pageMode in
                    relationshipPage(pageMode)
                        .tag(pageMode)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(AppColors.pageBackground.ignoresSafeArea())
        .navigationTitle("关注与粉丝")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(AppColors.pageBackground, for: .navigationBar)
        .task {
            await loadEntries()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ProfileSocialEvents.followingDidChange)
        ) { notification in
            guard canManageRelationships,
                  let (targetUserID, isFollowing) = ProfileSocialEvents.change(from: notification),
                  let entry = knownEntry(userID: targetUserID)
            else { return }
            snapshot.applyFollowingChange(entry: entry, isFollowing: isFollowing)
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

    private var relationshipTabs: some View {
        HStack(spacing: 0) {
            ForEach(ProfileFollowListMode.allCases) { pageMode in
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        selectedMode = pageMode
                    }
                } label: {
                    VStack(spacing: 9) {
                        Text(pageMode.title)
                            .font(.system(
                                size: 15,
                                weight: selectedMode == pageMode ? .bold : .medium
                            ))
                            .foregroundStyle(
                                selectedMode == pageMode
                                    ? AppColors.textPrimary
                                    : AppColors.textMuted
                            )

                        Capsule()
                            .fill(
                                selectedMode == pageMode
                                    ? AppColors.accentStrong
                                    : Color.clear
                            )
                            .frame(width: 24, height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedMode == pageMode ? .isSelected : [])
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 12)
        .background(AppColors.pageBackground)
    }

    @ViewBuilder
    private func relationshipPage(_ pageMode: ProfileFollowListMode) -> some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let entries = snapshot.entries(for: pageMode)
            if entries.isEmpty {
                emptyState(for: pageMode)
            } else {
                relationshipList(entries, mode: pageMode)
            }
        }
    }

    private func relationshipList(
        _ entries: [ProfileFollowListEntry],
        mode pageMode: ProfileFollowListMode
    ) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        NavigationLink(destination: UserPostsView(userId: entry.id)) {
                            profileRow(entry, showsChevron: !canManageRelationships)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if canManageRelationships {
                            managementActions(for: entry, mode: pageMode)
                                .padding(.trailing, 16)
                        }
                    }
                    .background(AppColors.cardBackground)

                    if entry.id != entries.last?.id {
                        Divider()
                            .overlay(AppColors.divider.opacity(0.8))
                            .padding(.leading, 72)
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(AppColors.cardBackground)
    }

    private func emptyState(for pageMode: ProfileFollowListMode) -> some View {
        VStack(spacing: 10) {
            Image(systemName: pageMode == .mutual ? "person.2.fill" : "person.2")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(pageMode.emptyText)
                .font(.system(size: 14))
                .foregroundStyle(AppColors.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func profileRow(
        _ entry: ProfileFollowListEntry,
        showsChevron: Bool
    ) -> some View {
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
                    .lineLimit(1)
                if let subtitle = entry.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted.opacity(0.6))
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func managementActions(
        for entry: ProfileFollowListEntry,
        mode pageMode: ProfileFollowListMode
    ) -> some View {
        HStack(spacing: 7) {
            switch pageMode {
            case .followers:
                if entry.amFollowing {
                    mutualFollowBadge
                } else {
                    followButton(entry, title: "回关")
                }
                removeFollowerButton(entry)
            case .following, .mutual:
                unfollowButton(entry)
            }
        }
    }

    private var mutualFollowBadge: some View {
        Text("互关")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppColors.accentStrong)
            .frame(minWidth: 48)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(AppColors.accent.opacity(0.16), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(AppColors.accentStrong.opacity(0.55), lineWidth: 1)
            }
            .accessibilityLabel("已互关")
    }

    private func followButton(
        _ entry: ProfileFollowListEntry,
        title: String
    ) -> some View {
        Button {
            Task { await setFollowing(true, entry: entry) }
        } label: {
            actionLabel(title, entryID: entry.id)
                .foregroundStyle(Color.black)
                .background(AppColors.accent, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(AppColors.textPrimary.opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(pendingEntryIDs.contains(entry.id))
        .accessibilityLabel("\(title)\(entry.displayName)")
    }

    private func unfollowButton(_ entry: ProfileFollowListEntry) -> some View {
        Button {
            Task { await setFollowing(false, entry: entry) }
        } label: {
            actionLabel("取消关注", entryID: entry.id)
                .foregroundStyle(AppColors.textMuted)
                .background(AppColors.pageBackground, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(AppColors.textMuted.opacity(0.38), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(pendingEntryIDs.contains(entry.id))
        .accessibilityLabel("取消关注\(entry.displayName)")
    }

    private func removeFollowerButton(_ entry: ProfileFollowListEntry) -> some View {
        Button {
            Task { await removeFollower(entry) }
        } label: {
            actionLabel("移除", entryID: entry.id)
                .foregroundStyle(AppColors.textMuted)
                .background(AppColors.pageBackground, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(AppColors.textMuted.opacity(0.38), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(pendingEntryIDs.contains(entry.id))
        .accessibilityLabel("移除粉丝\(entry.displayName)")
    }

    private func actionLabel(_ title: String, entryID: UUID) -> some View {
        Group {
            if pendingEntryIDs.contains(entryID) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .frame(minWidth: title == "回关" ? 56 : 48)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
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

    private func knownEntry(userID: UUID) -> ProfileFollowListEntry? {
        (snapshot.following + snapshot.followers).first { $0.id == userID }
    }

    @MainActor
    private func loadEntries() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            snapshot = try await profileSocialService.loadFollowLists(userId: userId)
        } catch {
            snapshot = ProfileFollowListsSnapshot(following: [], followers: [])
            if !error.isCancellationLike {
                errorMessage = AppErrorMessage.userMessage(for: error)
            }
        }
    }

    @MainActor
    private func removeFollower(_ entry: ProfileFollowListEntry) async {
        guard !pendingEntryIDs.contains(entry.id) else { return }
        pendingEntryIDs.insert(entry.id)
        defer { pendingEntryIDs.remove(entry.id) }

        do {
            try await profileSocialService.removeFollower(followerUserId: entry.id)
            snapshot.removeFollower(userID: entry.id)
        } catch {
            actionErrorMessage = AppErrorMessage.userMessage(for: error)
        }
    }

    @MainActor
    private func setFollowing(
        _ isFollowing: Bool,
        entry: ProfileFollowListEntry
    ) async {
        guard canManageRelationships,
              !pendingEntryIDs.contains(entry.id)
        else { return }
        pendingEntryIDs.insert(entry.id)
        defer { pendingEntryIDs.remove(entry.id) }

        do {
            if isFollowing {
                try await profileSocialService.follow(targetUserId: entry.id)
            } else {
                try await profileSocialService.unfollow(targetUserId: entry.id)
            }
            snapshot.applyFollowingChange(entry: entry, isFollowing: isFollowing)
        } catch {
            actionErrorMessage = AppErrorMessage.userMessage(for: error)
        }
    }
}
