//
//  ProfileView.swift
//  CheeseApp
//
//  👤 个人中心视图
//  展示真实用户信息、我的发布、设置等
//

import SwiftUI
import PhotosUI
import UIKit

struct ProfileView: View {
    @EnvironmentObject var authService: AuthService
    let isActive: Bool
    @State private var showingEditProfile = false
    @State private var isLoadingSocialSummary = false
    @State private var isRefreshingProfile = false
    @State private var activityRefreshGeneration = 0
    @State private var lastProfileRefreshAt: Date?
    @State private var myPostCount = 0
    @State private var fallbackPublicID: String?
    @State private var uidCopyFeedbackMessage: String?
    @State private var activitySharingPost: PostSharePayload?
    @State private var activityEditingPost: UserPostSummary?
    @State private var activityShareFeedbackMessage: String?
    @StateObject private var profileSocialService = ProfileSocialService.shared
    @StateObject private var userPostsService = UserPostsService()

    // 用户便捷访问
    private var user: Profile? { authService.currentUser }
    private var socialSummary: ProfileSocialSummary {
        profileSocialService.summary(for: user?.id)
    }
    private var shouldShowGenderBadge: Bool {
        (user?.isGenderVisible ?? true)
            && ["male", "female", "non_binary"].contains(user?.gender ?? "")
    }

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()

            GeometryReader { contentProxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // 用户资料使用与首页信息流一致的无框内容面。
                        userInfoCard

                        ProfileActivityView(
                            isEmbedded: true,
                            externalRefreshGeneration: activityRefreshGeneration,
                            onPresentShare: { payload in
                                activitySharingPost = payload
                            },
                            onPresentEditor: { post in
                                activityEditingPost = post
                            }
                        )
                    }
                    .frame(
                        width: max(contentProxy.size.width - 32, 0),
                        alignment: .top
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .refreshable {
                    await refreshProfile(force: true)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingEditProfile) {
            EditProfileView()
        }
        .navigationDestination(item: $activityEditingPost) { post in
            EditPostSheet(post: post) { payload in
                try await userPostsService.update(payload: payload)
                activityRefreshGeneration &+= 1
            }
        }
        .safeAreaInset(edge: .top) {
            CheeseInlineTopBar {
                EmptyView()
            } center: {
                Text(L10n.tr("Profile", "个人档案"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
            } trailing: {
                NavigationLink(destination: SettingsView()) {
                    PostToolbarIconCircle(icon: "gearshape")
                }
                .buttonStyle(.plain)
            }
        }
        .cheesePostSharePanel(item: $activitySharingPost) { message in
            ShareFeedbackPresenter.show(message) {
                activityShareFeedbackMessage = $0
            }
        }
        .task(id: authService.currentUser?.id) {
            await refreshProfile(force: true)
        }
        .onChange(of: authService.currentUser?.id) { _, _ in
            activityEditingPost = nil
        }
        .onChange(of: isActive) { _, active in
            guard active else { return }
            // Re-entering Profile is the membership reconciliation point for
            // liked/saved snapshots and for completed/private post state.
            Task { await refreshProfile(force: true) }
        }
        .shareFeedbackToast(message: $uidCopyFeedbackMessage)
        .shareFeedbackToast(message: $activityShareFeedbackMessage)
    }

    // MARK: - 用户信息卡片
    private var userInfoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if user?.isOfficialAccount == true {
                    OfficialAccountAvatar(size: 56)
                } else if let avatarUrl = user?.avatarUrl, let url = URL(string: avatarUrl) {
                    CachedRemoteImage(url: url, targetPixelWidth: 192) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        avatarPlaceholder
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                    .tappableAvatarPreview(user?.avatarUrl)
                } else {
                    avatarPlaceholder
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(AppColors.textPrimary)
                        if user?.isOfficialAccount == true {
                            OfficialVerificationBadge()
                        }
                        if user?.hasMcMasterStudentBadge == true {
                            McMasterStudentBadge(style: .label)
                        }
                    }

                    Text("\(myPostCount) 条帖子")
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textMuted)
                }

                Spacer()
            }

            HStack(spacing: 18) {
                if let userId = user?.id {
                    NavigationLink(destination: ProfileFollowListView(userId: userId, mode: .followers)) {
                        profileMetric(
                            count: socialSummary.followerCount,
                            label: "粉丝",
                            showRedDot: profileSocialService.hasUnreadFollowers
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink(destination: ProfileFollowListView(userId: userId, mode: .following)) {
                        profileMetric(count: socialSummary.followingCount, label: "关注")
                    }
                    .buttonStyle(.plain)
                } else {
                    profileMetric(
                        count: socialSummary.followerCount,
                        label: "粉丝",
                        showRedDot: profileSocialService.hasUnreadFollowers
                    )
                    profileMetric(count: socialSummary.followingCount, label: "关注")
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                if let school = user?.school, !school.isEmpty {
                    profileDetailRow(icon: "graduationcap.fill", text: school)
                }

                let bio = user?.bio?.trimmingCharacters(in: .whitespacesAndNewlines)
                profileDetailRow(
                    icon: "text.alignleft",
                    text: bio.flatMap { $0.isEmpty ? nil : $0 } ?? "暂无个性签名",
                    lineLimit: 3
                )
            }

            HStack(spacing: 8) {
                if shouldShowGenderBadge {
                    ProfileGenderBadge(gender: user?.gender)
                }

                if let publicID = user?.publicID ?? fallbackPublicID {
                    ProfileUIDBadge(publicID: publicID) {
                        showUIDCopiedFeedback()
                    }
                }

                Spacer()

                Button(action: { showingEditProfile = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                        Text(L10n.tr("Edit Profile", "编辑资料"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(AppColors.textPrimary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Color.white)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AppColors.textMuted.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(AppColors.divider)
        }
    }

    private func profileDetailRow(icon: String, text: String, lineLimit: Int = 1) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColors.textMuted)
                .frame(width: 18, alignment: .center)

            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
        }
    }

    private func profileMetric(count: Int, label: String, showRedDot: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColors.textMuted)

            Text("\(count)")
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(AppColors.textPrimary)
                .overlay(alignment: .topTrailing) {
                    if showRedDot {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .offset(x: 6, y: -2)
                    }
                }
        }
        .frame(minWidth: 62, alignment: .leading)
    }

    // MARK: - 头像占位符
    private var avatarPlaceholder: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [AppColors.accent, AppColors.accentStrong],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 56, height: 56)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
            }
    }

    private var displayName: String {
        if let name = user?.fullName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let email = user?.email, let localPart = email.split(separator: "@").first, !localPart.isEmpty {
            return String(localPart)
        }
        return L10n.tr("New User", "新用户")
    }

    private func loadSocialSummary() async {
        guard !isLoadingSocialSummary else { return }
        guard let userId = user?.id else { return }

        isLoadingSocialSummary = true
        defer { isLoadingSocialSummary = false }

        await profileSocialService.loadSummary(userId: userId, forceRefresh: true)
    }

    private func loadMyPostCount() async {
        guard let userId = user?.id else {
            myPostCount = 0
            return
        }

        do {
            myPostCount = try await userPostsService.fetchPostCount(userId: userId)
        } catch {
            myPostCount = 0
        }
    }

    private func refreshProfile(force: Bool) async {
        guard !isRefreshingProfile else { return }
        if !force,
           let lastProfileRefreshAt,
           Date().timeIntervalSince(lastProfileRefreshAt) < 15 {
            return
        }

        isRefreshingProfile = true
        defer { isRefreshingProfile = false }

        async let socialSummaryRefresh: Void = loadSocialSummary()
        async let postCountRefresh: Void = loadMyPostCount()
        async let publicIDRefresh: Void = loadPublicIDIfNeeded()
        _ = await (socialSummaryRefresh, postCountRefresh, publicIDRefresh)
        activityRefreshGeneration &+= 1
        lastProfileRefreshAt = Date()
    }

    private func loadPublicIDIfNeeded() async {
        guard user?.publicID == nil,
              let userID = user?.id,
              let profile = try? await ProfileService.fetchProfile(userId: userID)
        else { return }
        fallbackPublicID = profile.publicID
    }

    private func showUIDCopiedFeedback() {
        ShareFeedbackPresenter.show(
            L10n.tr(
                "Cheese ID copied. Paste it into Search to find this profile.",
                "奶酪 ID 已复制，可粘贴到搜索中查找该用户"
            )
        ) {
            uidCopyFeedbackMessage = $0
        }
    }

}

enum ProfileUIDPresentation {
    static func clipboardText(for publicID: String) -> String {
        publicID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func badgeText(for publicID: String) -> String {
        L10n.tr("Cheese ID", "奶酪 ID") + ": \(clipboardText(for: publicID))"
    }
}

struct ProfileUIDBadge: View {
    let publicID: String
    let onCopied: () -> Void

    init(publicID: String, onCopied: @escaping () -> Void = {}) {
        self.publicID = publicID
        self.onCopied = onCopied
    }

    var body: some View {
        Button {
            UIPasteboard.general.string = ProfileUIDPresentation.clipboardText(
                for: publicID
            )
            onCopied()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                Text(ProfileUIDPresentation.badgeText(for: publicID))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(AppColors.textMuted)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Color(.systemGray6))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            L10n.tr("Cheese ID", "奶酪 ID")
                + " \(ProfileUIDPresentation.clipboardText(for: publicID))"
        )
        .accessibilityHint(L10n.tr("Copies Cheese ID", "点击复制奶酪 ID"))
    }
}

struct ProfileGenderBadge: View {
    let gender: String?

    private var presentation: (symbol: String, color: Color, label: String)? {
        switch gender {
        case "male":
            return ("♂", .blue, "男")
        case "female":
            return ("♀", .pink, "女")
        case "non_binary":
            return ("⚧", .purple, "非二元")
        default:
            return nil
        }
    }

    var body: some View {
        if let presentation {
            Text(presentation.symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(presentation.color)
                .frame(width: 32, height: 24)
                .background(presentation.color.opacity(0.14))
                .clipShape(Capsule())
                .accessibilityLabel("性别：\(presentation.label)")
        }
    }
}
