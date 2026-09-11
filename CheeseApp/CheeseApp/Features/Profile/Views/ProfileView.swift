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

struct ProfileScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ProfileView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.openURL) private var openURL
    let isActive: Bool
    let onOpenForum: () -> Void
    let onOpenSecondhand: (SecondhandPost.Category?) -> Void
    @State private var showingEditProfile = false
    @State private var showingAvatarEditor = false
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
    @State private var profileScrollOffset: CGFloat = 0
    @State private var showNavigationDrawer = false
    @State private var navigationDrawerOpenRequest: UInt = 0
    @State private var showCustomerSupport = false
    @State private var showSettings = false
    @StateObject private var profileSocialService = ProfileSocialService.shared
    @StateObject private var userPostsService = UserPostsService()

    private let profileScrollCoordinateSpace = "cheese-profile-scroll"
    private let profileCoverHeight: CGFloat = 350

    // 用户便捷访问
    private var user: Profile? { authService.currentUser }
    private var socialSummary: ProfileSocialSummary {
        profileSocialService.summary(for: user?.id)
    }
    private var hasProfileCover: Bool {
        guard let cover = user?.coverImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !cover.isEmpty
    }
    private var topBarTransitionProgress: CGFloat {
        return min(max((-profileScrollOffset - 220) / 58, 0), 1)
    }

    init(
        isActive: Bool = true,
        onOpenForum: @escaping () -> Void = {},
        onOpenSecondhand: @escaping (SecondhandPost.Category?) -> Void = { _ in }
    ) {
        self.isActive = isActive
        self.onOpenForum = onOpenForum
        self.onOpenSecondhand = onOpenSecondhand
    }

    var body: some View {
        GeometryReader { contentProxy in
            ZStack {
                AppColors.pageBackground
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        GeometryReader { markerProxy in
                            Color.clear.preference(
                                key: ProfileScrollOffsetPreferenceKey.self,
                                value: markerProxy.frame(
                                    in: .named(profileScrollCoordinateSpace)
                                ).minY
                            )
                        }
                        .frame(height: 0)

                        // 用户资料使用与首页信息流一致的无框内容面。
                        userInfoCard

                        ProfileActivityView(
                            isEmbedded: true,
                            externalRefreshGeneration: activityRefreshGeneration,
                            // Keep every activity page at least one viewport tall.
                            // Otherwise switching to an empty/loading tab shrinks
                            // the outer ScrollView and clamps it back to the top.
                            minimumEmbeddedPagerHeight: contentProxy.size.height,
                            onPresentShare: { payload in
                                activitySharingPost = payload
                            },
                            onPresentEditor: { post in
                                activityEditingPost = post
                            }
                        )

                        // Keep the custom tab bar clearance outside the
                        // dynamically measured activity pager. Forum media
                        // can resolve its height asynchronously; placing the
                        // clearance inside that pager lets an earlier height
                        // measurement occasionally clip the final row.
                        Color.clear
                            .frame(
                                height: CheeseTabBarLayout.contentBottomClearance
                            )
                            .accessibilityHidden(true)
                    }
                    .frame(
                        width: max(contentProxy.size.width - 32, 0),
                        alignment: .top
                    )
                    .padding(.horizontal, 16)
                }
                .coordinateSpace(name: profileScrollCoordinateSpace)
                .ignoresSafeArea(edges: .top)
                .refreshable {
                    await refreshProfile(force: true)
                }

            }
        }
        .onPreferenceChange(ProfileScrollOffsetPreferenceKey.self) { offset in
            profileScrollOffset = offset
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            profileTopBar
        }
        .overlay {
            HomeNavigationDrawerContainer(
                openRequest: navigationDrawerOpenRequest,
                onPresentationChange: { showNavigationDrawer = $0 },
                onForumTap: onOpenForum,
                onSecondhandTap: { onOpenSecondhand(nil) },
                onSecondhandCategoryTap: { onOpenSecondhand($0) },
                onSettingsTap: { showSettings = true },
                onSupportTap: { showCustomerSupport = true },
                onCourseRadarTap: { openURL(AppExternalLinks.courseRadar) }
            )
        }
        .sheet(isPresented: $showingEditProfile) {
            EditProfileView()
        }
        .fullScreenCover(isPresented: $showingAvatarEditor) {
            EditProfileView(startsWithAvatarActions: true)
        }
        .navigationDestination(item: $activityEditingPost) { post in
            EditPostSheet(post: post) { payload in
                try await userPostsService.update(payload: payload)
                activityRefreshGeneration &+= 1
            }
        }
        .navigationDestination(isPresented: $showCustomerSupport) {
            CheeseCustomerSupportView()
        }
        .navigationDestination(isPresented: $showSettings) {
            SettingsView()
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
        .cheeseTabBarHidden(showNavigationDrawer)
        .preferredColorScheme(
            hasProfileCover && topBarTransitionProgress < 0.58
                ? .dark
                : .light
        )
    }

    private var profileTopBar: some View {
        ProfileOverlayTopBar(transitionProgress: topBarTransitionProgress) {
            Button {
                navigationDrawerOpenRequest &+= 1
            } label: {
                ZStack {
                    PostToolbarIconCircle(
                        icon: "line.3.horizontal",
                        tint: hasProfileCover ? .white : AppColors.textPrimary
                    )
                    .opacity(1 - topBarTransitionProgress)

                    PostToolbarIconCircle(
                        icon: "line.3.horizontal",
                        tint: AppColors.textPrimary
                    )
                    .opacity(topBarTransitionProgress)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("Open navigation", "打开导航"))
        } trailing: {
            NavigationLink(destination: SettingsView()) {
                ZStack {
                    PostToolbarIconCircle(
                        icon: "gearshape",
                        tint: hasProfileCover ? .white : AppColors.textPrimary
                    )
                    .opacity(1 - topBarTransitionProgress)

                    PostToolbarIconCircle(
                        icon: "gearshape",
                        tint: AppColors.textPrimary
                    )
                    .opacity(topBarTransitionProgress)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 用户信息卡片
    private var userInfoCard: some View {
        ProfileHeaderSurface(
            profile: user,
            postCount: myPostCount,
            publicID: user?.publicID ?? fallbackPublicID,
            coverHeight: profileCoverHeight,
            contentBottomPadding: 32,
            onUIDCopied: showUIDCopiedFeedback
        ) {
            ownProfileAvatar
        } socialContent: {
            HStack(spacing: 18) {
                if let userId = user?.id {
                    NavigationLink(destination: ProfileFollowListView(userId: userId, mode: .followers)) {
                        ProfileHeaderMetric(
                            count: socialSummary.followerCount,
                            label: "粉丝",
                            onDarkBackground: hasProfileCover
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink(destination: ProfileFollowListView(userId: userId, mode: .following)) {
                        ProfileHeaderMetric(
                            count: socialSummary.followingCount,
                            label: "关注",
                            onDarkBackground: hasProfileCover
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    ProfileHeaderMetric(
                        count: socialSummary.followerCount,
                        label: "粉丝",
                        onDarkBackground: hasProfileCover
                    )
                    ProfileHeaderMetric(
                        count: socialSummary.followingCount,
                        label: "关注",
                        onDarkBackground: hasProfileCover
                    )
                }
                Spacer()
            }
        } actionContent: {
            Button {
                showingEditProfile = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                    Text(L10n.tr("Edit Profile", "编辑资料"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(hasProfileCover ? Color.white : AppColors.textPrimary)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(hasProfileCover ? Color.white.opacity(0.16) : Color.white)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(
                            hasProfileCover ? Color.white.opacity(0.34) : AppColors.textMuted.opacity(0.3),
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, -16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(AppColors.divider)
        }
    }

    @ViewBuilder
    private var ownProfileAvatar: some View {
        if user?.id == CheeseAIIdentity.userID {
            CheeseAIAvatarView(
                remoteURLString: user?.avatarUrl,
                size: 56
            )
            .tappableAvatarPreview(user?.avatarUrl)
        } else if user?.isOfficialAccount == true {
            OfficialAccountAvatar(size: 56)
        } else {
            Button {
                showingAvatarEditor = true
            } label: {
                Group {
                    if let avatarUrl = user?.avatarUrl,
                       let url = URL(string: avatarUrl) {
                        CachedRemoteImage(url: url, targetPixelWidth: 192) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            avatarPlaceholder
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                    } else {
                        avatarPlaceholder
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("Change avatar", "更换头像"))
        }
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

struct ProfileOverlayTopBar<LeadingContent: View, TrailingContent: View>: View {
    let transitionProgress: CGFloat
    private let leadingContent: LeadingContent
    private let trailingContent: TrailingContent

    init(
        transitionProgress: CGFloat,
        @ViewBuilder _ leadingContent: () -> LeadingContent,
        @ViewBuilder trailing trailingContent: () -> TrailingContent
    ) {
        self.transitionProgress = transitionProgress
        self.leadingContent = leadingContent()
        self.trailingContent = trailingContent()
    }

    var body: some View {
        HStack(spacing: 10) {
            leadingContent
            Spacer(minLength: 0)
            trailingContent
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(
            AppColors.pageBackground
                .opacity(transitionProgress)
                .ignoresSafeArea(edges: .top)
        )
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(AppColors.divider)
                .opacity(transitionProgress)
        }
    }
}

struct ProfileRoundedContentSurface<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 18,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 18,
                    style: .continuous
                )
                .fill(AppColors.pageBackground)
                .padding(.horizontal, -16)
            }
            .padding(.top, -14)
    }
}

struct ProfileHeaderMetric: View {
    let count: Int
    let label: String
    let onDarkBackground: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(onDarkBackground ? Color.white.opacity(0.82) : AppColors.textMuted)

            Text("\(count)")
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(onDarkBackground ? Color.white : AppColors.textPrimary)
        }
        .frame(minWidth: 62, alignment: .leading)
    }
}

struct ProfileHeaderSurface<AvatarContent: View, SocialContent: View, ActionContent: View>: View {
    let profile: Profile?
    let postCount: Int
    let publicID: String?
    let coverHeight: CGFloat
    let contentBottomPadding: CGFloat
    let onUIDCopied: () -> Void
    private let avatarContent: AvatarContent
    private let socialContent: SocialContent
    private let actionContent: ActionContent

    init(
        profile: Profile?,
        postCount: Int,
        publicID: String?,
        coverHeight: CGFloat = 350,
        contentBottomPadding: CGFloat = 32,
        onUIDCopied: @escaping () -> Void,
        @ViewBuilder _ avatarContent: () -> AvatarContent,
        @ViewBuilder socialContent: () -> SocialContent,
        @ViewBuilder actionContent: () -> ActionContent
    ) {
        self.profile = profile
        self.postCount = postCount
        self.publicID = publicID
        self.coverHeight = coverHeight
        self.contentBottomPadding = contentBottomPadding
        self.onUIDCopied = onUIDCopied
        self.avatarContent = avatarContent()
        self.socialContent = socialContent()
        self.actionContent = actionContent()
    }

    var body: some View {
        ProfileCoverHeader(
            coverURLString: profile?.coverImageUrl,
            height: coverHeight,
            contentBottomPadding: contentBottomPadding
        ) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 12) {
                    avatarContent
                        .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(displayName)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(hasCover ? Color.white : AppColors.textPrimary)
                                .singleLineEllipsized()
                            if profile?.isOfficialAccount == true {
                                OfficialVerificationBadge()
                            }
                            if profile?.hasMcMasterStudentBadge == true {
                                McMasterStudentBadge(style: .label)
                            }
                        }

                        Text("\(postCount) 条帖子")
                            .font(.system(size: 13))
                            .foregroundStyle(hasCover ? Color.white.opacity(0.78) : AppColors.textMuted)
                    }

                    Spacer()
                }

                socialContent

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(hasCover ? Color.white.opacity(0.78) : AppColors.textMuted)
                        .frame(width: 18, alignment: .center)

                    Text(bioText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(hasCover ? Color.white.opacity(0.88) : AppColors.textMuted)
                        .lineLimit(3)
                        .truncationMode(.tail)
                }

                HStack(spacing: 8) {
                    if shouldShowGenderBadge {
                        ProfileGenderBadge(gender: profile?.gender)
                    }

                    if let publicID {
                        ProfileUIDBadge(
                            publicID: publicID,
                            onDarkBackground: hasCover,
                            onCopied: onUIDCopied
                        )
                    }

                    Spacer()
                    actionContent
                }
            }
        }
    }

    private var hasCover: Bool {
        guard let value = profile?.coverImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !value.isEmpty
    }

    private var displayName: String {
        if let name = profile?.fullName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let email = profile?.email,
           let localPart = email.split(separator: "@").first,
           !localPart.isEmpty {
            return String(localPart)
        }
        return L10n.tr("New User", "新用户")
    }

    private var bioText: String {
        guard let bio = profile?.bio?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty else {
            return "暂无个性签名"
        }
        return bio
    }

    private var shouldShowGenderBadge: Bool {
        (profile?.isGenderVisible ?? true)
            && ["male", "female", "non_binary"].contains(profile?.gender ?? "")
    }
}

struct ProfileCoverHeader<IdentityContent: View>: View {
    let coverURLString: String?
    let height: CGFloat
    let contentBottomPadding: CGFloat
    private let identityContent: IdentityContent

    init(
        coverURLString: String?,
        height: CGFloat = 278,
        contentBottomPadding: CGFloat = 18,
        @ViewBuilder identityContent: () -> IdentityContent
    ) {
        self.coverURLString = coverURLString
        self.height = height
        self.contentBottomPadding = contentBottomPadding
        self.identityContent = identityContent()
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                coverBackground
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .zIndex(0)

                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.34),
                                .init(color: .black.opacity(0.16), location: 0.52),
                                .init(color: .black.opacity(0.76), location: 0.78),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .zIndex(0.5)

                LinearGradient(
                    stops: hasCover
                        ? [
                            .init(color: .black.opacity(0.04), location: 0),
                            .init(color: .black.opacity(0.12), location: 0.40),
                            .init(color: .black.opacity(0.46), location: 0.72),
                            .init(color: .black.opacity(0.72), location: 1)
                        ]
                        : [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.05), location: 1)
                        ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .zIndex(1)

                identityContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, contentBottomPadding)
                    .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
    }

    private var hasCover: Bool {
        guard let cover = coverURLString?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !cover.isEmpty
    }

    @ViewBuilder
    private var coverBackground: some View {
        if let resolvedURL = SupabasePublicImageURLResolver.url(
            fromStoredURL: coverURLString,
            purpose: .feedThumbnail
        ) {
            CachedRemoteImage(
                url: resolvedURL,
                targetPixelWidth: RemoteImagePurpose.feedThumbnail.targetPixelWidth,
                showsRetryButton: true
            ) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                defaultBackground
            }
        } else {
            defaultBackground
        }
    }

    private var defaultBackground: some View {
        LinearGradient(
            colors: [
                AppColors.accent.opacity(0.20),
                Color(uiColor: .secondarySystemBackground),
                AppColors.textMuted.opacity(0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct ProfileCoverEditorView: View {
    let userID: UUID
    let coverURLString: String?
    let onCoverUpdated: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var effectiveCoverURLString: String?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var pendingCoverCropImage: UIImage?
    @State private var showingCoverCropper = false
    @State private var isUploading = false
    @State private var showingDeleteConfirmation = false
    @State private var errorMessage: String?

    init(
        userID: UUID,
        coverURLString: String?,
        onCoverUpdated: @escaping (String?) -> Void
    ) {
        self.userID = userID
        self.coverURLString = coverURLString
        self.onCoverUpdated = onCoverUpdated
        _effectiveCoverURLString = State(initialValue: coverURLString)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            coverPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 27, weight: .regular))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                VStack(spacing: 0) {
                    PhotosPicker(
                        selection: $selectedPhotoItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        coverActionRow(
                            title: hasCover
                                ? L10n.tr("Change cover image", "更换背景图")
                                : L10n.tr("Choose cover image", "选择背景图"),
                            icon: "photo"
                        )
                    }
                    .disabled(isUploading)

                    if hasCover {
                        Divider()
                            .overlay(Color.white.opacity(0.10))
                            .padding(.leading, 22)

                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            coverActionRow(
                                title: L10n.tr("Remove cover image", "删除背景图"),
                                icon: "trash"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isUploading)
                    }
                }
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }

            if isUploading {
                ProgressView()
                    .tint(.white)
                    .padding(18)
                    .background(Color.black.opacity(0.58))
                    .clipShape(Circle())
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task { await prepareCoverCrop(with: item) }
        }
        .fullScreenCover(isPresented: $showingCoverCropper) {
            if let pendingCoverCropImage {
                CoverImageCropView(
                    image: pendingCoverCropImage,
                    aspectRatio: coverCropAspectRatio,
                    onCancel: cancelCoverCrop,
                    onConfirm: confirmCoverCrop
                )
            }
        }
        .confirmationDialog(
            L10n.tr("Remove this cover image?", "删除这张背景图？"),
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Remove", "删除"), role: .destructive) {
                Task { await deleteCover() }
            }
            Button(L10n.tr("Cancel", "取消"), role: .cancel) {}
        }
        .alert(
            L10n.tr("Unable to update cover", "背景图更新失败"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(L10n.tr("OK", "确定"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var coverPreview: some View {
        if let resolvedURL = SupabasePublicImageURLResolver.url(
            fromStoredURL: effectiveCoverURLString,
            purpose: .detail
        ) {
            CachedRemoteImage(
                url: resolvedURL,
                targetPixelWidth: RemoteImagePurpose.detail.targetPixelWidth,
                showsRetryButton: true
            ) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                ProgressView().tint(.white)
            }
        } else {
            LinearGradient(
                colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.46))
            }
            .frame(height: 300)
        }
    }

    private func coverActionRow(title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 22)
        .frame(height: 66)
        .contentShape(Rectangle())
    }

    private var hasCover: Bool {
        guard let cover = effectiveCoverURLString?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !cover.isEmpty
    }

    private var coverCropAspectRatio: CGFloat {
        // ProfileView renders the cover at full screen width and 350pt high.
        // Matching that viewport here prevents a second, unexpected crop after upload.
        max(UIScreen.main.bounds.width / 350, 1)
    }

    @MainActor
    private func prepareCoverCrop(with item: PhotosPickerItem) async {
        guard !isUploading else { return }
        isUploading = true
        errorMessage = nil
        defer {
            isUploading = false
            selectedPhotoItem = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                throw NSError(
                    domain: "ProfileCover",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: L10n.tr("Unable to read this image.", "无法读取这张图片")]
                )
            }

            pendingCoverCropImage = image
            showingCoverCropper = true
        } catch {
            errorMessage = AppErrorMessage.userMessage(for: error)
        }
    }

    @MainActor
    private func confirmCoverCrop(_ image: UIImage) {
        pendingCoverCropImage = nil
        showingCoverCropper = false
        Task { await uploadCroppedCover(image) }
    }

    @MainActor
    private func cancelCoverCrop() {
        pendingCoverCropImage = nil
        showingCoverCropper = false
    }

    @MainActor
    private func uploadCroppedCover(_ image: UIImage) async {
        guard !isUploading else { return }
        isUploading = true
        errorMessage = nil
        defer { isUploading = false }

        do {
            let newURL = try await ProfileService.replaceCoverImage(
                image,
                userId: userID,
                previousURL: effectiveCoverURLString
            )
            effectiveCoverURLString = newURL
            onCoverUpdated(newURL)
        } catch {
            errorMessage = AppErrorMessage.userMessage(for: error)
        }
    }

    @MainActor
    private func deleteCover() async {
        guard !isUploading else { return }
        isUploading = true
        errorMessage = nil
        defer { isUploading = false }

        do {
            try await ProfileService.deleteCoverImage(
                userId: userID,
                currentURL: effectiveCoverURLString
            )
            effectiveCoverURLString = nil
            onCoverUpdated(nil)
        } catch {
            errorMessage = AppErrorMessage.userMessage(for: error)
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
    let onDarkBackground: Bool
    let onCopied: () -> Void

    init(
        publicID: String,
        onDarkBackground: Bool = false,
        onCopied: @escaping () -> Void = {}
    ) {
        self.publicID = publicID
        self.onDarkBackground = onDarkBackground
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
            .foregroundStyle(onDarkBackground ? Color.white : AppColors.textMuted)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                onDarkBackground
                    ? Color.white.opacity(0.16)
                    : Color(.systemGray6)
            )
            .clipShape(Capsule())
            .overlay {
                if onDarkBackground {
                    Capsule()
                        .stroke(Color.white.opacity(0.28), lineWidth: 1)
                }
            }
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
