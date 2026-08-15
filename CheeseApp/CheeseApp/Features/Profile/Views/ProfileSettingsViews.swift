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

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject private var languageStore: AppLanguageStore

    @AppStorage("settings_push_notifications") private var pushNotifications = true
    @AppStorage("settings_haptic_feedback") private var hapticFeedback = true

    @State private var defaultAnonymousPosting = false
    @State private var isSavingAnonymousPreference = false
    @State private var settingsError: String?
    @State private var showSignOutConfirm = false
    @State private var showEditProfile = false
    @State private var isLoadingAccountIdentities = false
    @State private var accountIdentityStatuses: AccountIdentityStatuses?
    @State private var isBindingGoogle = false
    @State private var isBindingApple = false
    @State private var showAccountSwitcher = false
    @State private var showDeleteAccountConfirm = false
    @State private var isDeletingAccount = false

    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    settingsHeader(title: L10n.tr("Account", "帐号"))
                    settingsCard {
                        Button(action: { showEditProfile = true }) {
                            settingsRow(
                                icon: "person.crop.circle",
                                title: L10n.tr("Edit Profile", "编辑个人资料"),
                                subtitle: L10n.tr("Update your nickname, school and bio", "更新你的昵称、学校与个性签名")
                            )
                        }
                        .buttonStyle(.plain)

                        Divider().overlay(AppColors.divider)

                        NavigationLink(destination: McMasterVerificationView()) {
                            settingsRow(
                                icon: "graduationcap.fill",
                                title: "麦马学生认证",
                                subtitle: authService.currentUser?.hasMcMasterStudentBadge == true
                                    ? "已通过 @mcmaster.ca 邮箱认证"
                                    : "使用 @mcmaster.ca 邮箱获取学生徽章",
                                tint: authService.currentUser?.hasMcMasterStudentBadge == true
                                    ? Color(red: 122 / 255, green: 0, blue: 60 / 255)
                                    : AppColors.link
                            )
                        }
                        .buttonStyle(.plain)

                        Divider().overlay(AppColors.divider)

                        settingsRow(
                            icon: "g.circle.fill",
                            title: isGoogleBound ? "Google 已绑定" : "Google 未绑定",
                            subtitle: googleBindingSubtitle,
                            tint: isGoogleBound ? Color.green : AppColors.textMuted,
                            showChevron: false
                        )

                        if !isGoogleBound {
                            Divider().overlay(AppColors.divider)

                            Button(action: {
                                Task { await bindGoogleAccount() }
                            }) {
                                settingsRow(
                                    icon: isGoogleBindingDisabledByRule ? "lock.fill" : "link.badge.plus",
                                    title: isGoogleBindingDisabledByRule
                                        ? "绑定 Google（已禁用）"
                                        : (isBindingGoogle ? "绑定中..." : "绑定 Google"),
                                    subtitle: googleBindingActionSubtitle,
                                    tint: isGoogleBindingDisabledByRule ? AppColors.textMuted : AppColors.link,
                                    showChevron: false
                                )
                            }
                            .buttonStyle(.plain)
                            .opacity(isGoogleBindingDisabledByRule ? 0.68 : 1)
                            .disabled(isBindingGoogle || isLoadingAccountIdentities || isGoogleBindingDisabledByRule)
                        }

                        Divider().overlay(AppColors.divider)

                        settingsRow(
                            icon: "apple.logo",
                            title: isAppleBound ? "Apple 已绑定" : "Apple 未绑定",
                            subtitle: appleBindingSubtitle,
                            tint: isAppleBound ? Color.green : AppColors.textMuted,
                            showChevron: false
                        )

                        if !isAppleBound {
                            Divider().overlay(AppColors.divider)

                            Button(action: {
                                Task { await bindAppleAccount() }
                            }) {
                                settingsRow(
                                    icon: isAppleBindingDisabledByRule ? "lock.fill" : "link.badge.plus",
                                    title: isAppleBindingDisabledByRule
                                        ? "绑定 Apple（已禁用）"
                                        : (isBindingApple ? "绑定中..." : "绑定 Apple"),
                                    subtitle: appleBindingActionSubtitle,
                                    tint: isAppleBindingDisabledByRule ? AppColors.textMuted : AppColors.link,
                                    showChevron: false
                                )
                            }
                            .buttonStyle(.plain)
                            .opacity(isAppleBindingDisabledByRule ? 0.68 : 1)
                            .disabled(isBindingApple || isLoadingAccountIdentities || isAppleBindingDisabledByRule)
                        }

                        Divider().overlay(AppColors.divider)

                        Button(action: { showAccountSwitcher = true }) {
                            settingsRow(
                                icon: "person.2.fill",
                                title: "切换账号",
                                subtitle: "最多同时保留 \(authService.maxSavedAccountCount) 个账号（当前 \(authService.savedAccounts.count)/\(authService.maxSavedAccountCount)）"
                            )
                        }
                        .buttonStyle(.plain)

                        Divider().overlay(AppColors.divider)

                        Button(action: { showSignOutConfirm = true }) {
                            settingsRow(
                                icon: "rectangle.portrait.and.arrow.right",
                                title: L10n.tr("Sign Out", "登出"),
                                subtitle: L10n.tr("Sign out on this device", "登出目前装置"),
                                tint: .red,
                                showChevron: false
                            )
                        }
                        .buttonStyle(.plain)

                        Divider().overlay(AppColors.divider)

                        Button(action: { showDeleteAccountConfirm = true }) {
                            settingsRow(
                                icon: "trash.fill",
                                title: isDeletingAccount ? "注销中..." : "注销账号",
                                subtitle: "清空账号数据，聊天内将显示“已注销”",
                                tint: .red,
                                showChevron: false
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeletingAccount)
                    }

                    settingsHeader(title: L10n.tr("Notifications", "通知"))
                    settingsCard {
                        settingsToggleRow(
                            icon: "bell.badge.fill",
                            title: L10n.tr("Push Notifications", "推播通知"),
                            subtitle: L10n.tr("Includes messages, group messages, post comments and likes", "包含私信、群聊、评论和点赞"),
                            isOn: $pushNotifications
                        )
                        .onChange(of: pushNotifications) { _, enabled in
                            Task {
                                await EngagementNotificationService.shared.updatePushSetting(enabled: enabled)
                            }
                        }
                    }

                    settingsHeader(title: L10n.tr("Interaction", "互动"))
                    settingsCard {
                        settingsToggleRow(
                            icon: "iphone.radiowaves.left.and.right",
                            title: L10n.tr("Haptic Feedback", "触感回馈"),
                            subtitle: L10n.tr("Vibration feedback for likes, tabs and key actions", "点赞、切页和关键操作会有震动反馈"),
                            isOn: $hapticFeedback
                        )
                    }

                    settingsHeader(title: L10n.tr("Privacy", "隐私"))
                    settingsCard {
                        settingsToggleRow(
                            icon: "person.crop.circle.badge.questionmark",
                            title: L10n.tr("Default Anonymous Posting", "默认匿名发文"),
                            subtitle: L10n.tr("New forum posts default to anonymous", "新发布论坛帖子时默认匿名"),
                            isOn: $defaultAnonymousPosting,
                            disabled: isSavingAnonymousPreference
                        )
                        .onChange(of: defaultAnonymousPosting) { _, newValue in
                            Task { await updateAnonymousPosting(enabled: newValue) }
                        }

                        Divider().overlay(AppColors.divider)

                        settingsLanguageRow()

                        Divider().overlay(AppColors.divider)

                        NavigationLink(destination: BlockedUsersView()) {
                            settingsRow(
                                icon: "hand.raised.fill",
                                title: L10n.tr("Blocked Users", "黑名单管理"),
                                subtitle: L10n.tr("View and unblock users", "查看并解除拉黑用户")
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    settingsHeader(title: L10n.tr("Data & Storage", "数据与存储"))
                    settingsCard {
                        Button(action: clearCache) {
                            settingsRow(
                                icon: "trash",
                                title: L10n.tr("Clear Image Cache", "清除图片快取"),
                                subtitle: L10n.tr("Free up local storage", "释放本地存储空间")
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    settingsHeader(title: L10n.tr("Support", "支持"))
                    settingsCard {
                        NavigationLink(destination: SupportCenterView()) {
                            settingsRow(
                                icon: "questionmark.circle",
                                title: L10n.tr("Help & Support", "帮助与支持"),
                                subtitle: L10n.tr("Report issues and feedback", "问题反馈与功能建议")
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    settingsHeader(title: L10n.tr("Rules & Legal", "规范与法律"))
                    settingsCard {
                        NavigationLink(destination: LegalDocumentView(document: .communityRules)) {
                            settingsRow(
                                icon: LegalDocument.communityRules.icon,
                                title: LegalDocument.communityRules.title,
                                subtitle: L10n.tr("Safety, conduct and moderation", "安全、互动与内容管理规范")
                            )
                        }
                        .buttonStyle(.plain)

                        Divider().overlay(AppColors.divider)

                        NavigationLink(destination: LegalDocumentView(document: .privacyPolicy)) {
                            settingsRow(
                                icon: LegalDocument.privacyPolicy.icon,
                                title: LegalDocument.privacyPolicy.title,
                                subtitle: L10n.tr("How your information is handled", "了解你的资料如何被处理")
                            )
                        }
                        .buttonStyle(.plain)

                        Divider().overlay(AppColors.divider)

                        NavigationLink(destination: LegalDocumentView(document: .userAgreement)) {
                            settingsRow(
                                icon: LegalDocument.userAgreement.icon,
                                title: LegalDocument.userAgreement.title,
                                subtitle: L10n.tr("Terms for using Cheese", "使用 Cheese 的权利与责任")
                            )
                        }
                        .buttonStyle(.plain)

                        Divider().overlay(AppColors.divider)

                        NavigationLink(destination: LegalDocumentView(document: .acknowledgements)) {
                            settingsRow(
                                icon: LegalDocument.acknowledgements.icon,
                                title: LegalDocument.acknowledgements.title,
                                subtitle: L10n.tr("Community, inspiration and open source", "社群、设计参考与开源专案")
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    settingsHeader(title: L10n.tr("About", "关于"))
                    settingsCard {
                        settingsRow(
                            icon: "app.badge",
                            title: L10n.tr("Version", "版本"),
                            subtitle: appVersionText,
                            showChevron: false
                        )
                    }

                    if let settingsError {
                        Text(settingsError)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .cheesePageTopBar(title: L10n.tr("Settings", "设定"))
        .alert(L10n.tr("Sign out?", "确定登出？"), isPresented: $showSignOutConfirm) {
            Button(L10n.tr("Cancel", "取消"), role: .cancel) {}
            Button(L10n.tr("Sign Out", "登出"), role: .destructive) {
                Task {
                    do {
                        try await authService.signOut()
                        dismiss()
                    } catch {
                        settingsError = error.localizedDescription
                    }
                }
            }
        } message: {
            Text(L10n.tr("You can sign back in anytime.", "你可以随时重新登入。"))
        }
        .alert("确认注销账号？", isPresented: $showDeleteAccountConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认注销", role: .destructive) {
                Task { await deactivateAccount() }
            }
        } message: {
            Text("该操作不可恢复：将删除你的帖子和公开内容，聊天里会显示“已注销”。")
        }
        .onAppear {
            defaultAnonymousPosting = authService.currentUser?.isAnonymousDefault ?? false
            authService.reloadSavedAccounts()
            Task {
                await EngagementNotificationService.shared.updatePushSetting(enabled: pushNotifications)
                await loadAccountIdentityStatuses()
            }
        }
        .sheet(isPresented: $showEditProfile) {
            EditProfileView()
        }
        .sheet(isPresented: $showAccountSwitcher) {
            AccountSwitcherView()
                .environmentObject(authService)
        }
        .onOpenURL { _ in
            Task {
                await loadAccountIdentityStatuses(forceRefresh: true)
                authService.reloadSavedAccounts()
            }
        }
        .tint(AppColors.link)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(16)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .cheeseCardChrome(cornerRadius: 16)
    }

    private func settingsHeader(title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(AppColors.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private func settingsRow(
        icon: String,
        title: String,
        subtitle: String,
        tint: Color = AppColors.link,
        showChevron: Bool = true
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textMuted)
            }

            Spacer()

            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppColors.textMuted)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func settingsToggleRow(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        tint: Color = AppColors.link,
        disabled: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textMuted)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(AppColors.link)
                .disabled(disabled)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(disabled ? 0.68 : 1)
    }

    private func settingsLanguageRow() -> some View {
        HStack(spacing: 12) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColors.link)
                .frame(width: 28, height: 28)
                .background(AppColors.link.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("Language", "语言"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text(L10n.tr("Switch app language", "切换应用显示语言"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textMuted)
            }

            Spacer(minLength: 12)

            Picker("Language", selection: Binding(
                get: { languageStore.current },
                set: { languageStore.setLanguage($0) }
            )) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    private func clearCache() {
        URLCache.shared.removeAllCachedResponses()
    }

    private func updateAnonymousPosting(enabled: Bool) async {
        guard let userId = authService.currentUser?.id else { return }
        isSavingAnonymousPreference = true
        defer { isSavingAnonymousPreference = false }

        do {
            try await ProfileService.updateAnonymousPostingDefault(userId: userId, enabled: enabled)

            await authService.fetchUserProfile(userId: userId)
            settingsError = nil
        } catch {
            settingsError = error.localizedDescription
            defaultAnonymousPosting = authService.currentUser?.isAnonymousDefault ?? false
        }
    }

    private var googleBindingSubtitle: String {
        if isLoadingAccountIdentities && accountIdentitySnapshot == nil {
            return "正在检查绑定状态..."
        }
        if isGoogleBound {
            if let email = googleBindingEmail, !email.isEmpty {
                return email
            }
            return "已绑定 Google 账号"
        }
        if isGoogleBindingDisabledByRule {
            return "当前账号已绑定 Apple，手动绑定已关闭"
        }
        return "当前账号未绑定 Google"
    }

    private var appleBindingSubtitle: String {
        if isLoadingAccountIdentities && accountIdentitySnapshot == nil {
            return "正在检查绑定状态..."
        }
        if isAppleBound {
            if let email = appleBindingEmail, !email.isEmpty {
                return email
            }
            return "已绑定 Apple 账号"
        }
        if isAppleBindingDisabledByRule {
            return "当前账号已绑定 Google，手动绑定已关闭"
        }
        return "当前账号未绑定 Apple"
    }

    private var isGoogleBindingDisabledByRule: Bool {
        !isGoogleBound && isAppleBound
    }

    private var isAppleBindingDisabledByRule: Bool {
        !isAppleBound && isGoogleBound
    }

    private var accountIdentitySnapshot: AccountIdentityStatuses? {
        accountIdentityStatuses ?? authService.cachedAccountIdentityStatuses()
    }

    private var isGoogleBound: Bool {
        accountIdentitySnapshot?.google.isLinked == true
    }

    private var googleBindingEmail: String? {
        accountIdentitySnapshot?.google.email
    }

    private var isAppleBound: Bool {
        accountIdentitySnapshot?.apple.isLinked == true
    }

    private var appleBindingEmail: String? {
        accountIdentitySnapshot?.apple.email
    }

    private var googleBindingActionSubtitle: String {
        isGoogleBindingDisabledByRule
            ? "当前项目已关闭跨平台手动绑定"
            : "绑定后可用 Google 账号登录"
    }

    private var appleBindingActionSubtitle: String {
        isAppleBindingDisabledByRule
            ? "当前项目已关闭跨平台手动绑定"
            : "绑定后可用 Apple 账号登录"
    }

    @MainActor
    private func bindGoogleAccount() async {
        guard !isBindingGoogle else { return }
        guard !isGoogleBindingDisabledByRule else {
            settingsError = "当前账号已使用 Apple 登录，跨平台手动绑定已关闭。"
            return
        }
        isBindingGoogle = true
        defer { isBindingGoogle = false }

        do {
            try await authService.linkAccountIdentity(.google)
            await loadAccountIdentityStatuses(forceRefresh: true)
            settingsError = nil
        } catch {
            settingsError = error.localizedDescription
        }
    }

    @MainActor
    private func bindAppleAccount() async {
        guard !isBindingApple else { return }
        guard !isAppleBindingDisabledByRule else {
            settingsError = "当前账号已使用 Google 登录，跨平台手动绑定已关闭。"
            return
        }
        isBindingApple = true
        defer { isBindingApple = false }

        do {
            try await authService.linkAccountIdentity(.apple)
            await loadAccountIdentityStatuses(forceRefresh: true)
            settingsError = nil
        } catch {
            settingsError = error.localizedDescription
        }
    }

    @MainActor
    private func loadAccountIdentityStatuses(forceRefresh: Bool = false) async {
        guard !isLoadingAccountIdentities else { return }
        isLoadingAccountIdentities = true
        defer { isLoadingAccountIdentities = false }

        do {
            accountIdentityStatuses = try await authService.accountIdentityStatuses(forceRefresh: forceRefresh)
        } catch {
            // Keep the current session snapshot visible. A transient refresh failure
            // must not replace correct provider state or reflow the settings screen.
        }
    }

    @MainActor
    private func deactivateAccount() async {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        defer { isDeletingAccount = false }

        do {
            try await authService.deactivateCurrentAccount()
            dismiss()
        } catch {
            settingsError = error.localizedDescription
        }
    }
}

struct McMasterVerificationView: View {
    @EnvironmentObject private var authService: AuthService

    @State private var localPart = ""
    @State private var code = ""
    @State private var status: McMasterVerificationStatus?
    @State private var codeWasSent = false
    @State private var isLoading = true
    @State private var isSending = false
    @State private var isVerifying = false
    @State private var isUnlinking = false
    @State private var showingUnlinkConfirmation = false
    @State private var cooldownSeconds = 0
    @State private var message: String?
    @State private var isError = false
    @State private var countdownTask: Task<Void, Never>?

    private let maroon = Color(red: 122 / 255, green: 0, blue: 60 / 255)
    private let gold = Color(red: 253 / 255, green: 191 / 255, blue: 87 / 255)

    private var isVerified: Bool {
        status?.verified == true || authService.currentUser?.hasMcMasterStudentBadge == true
    }

    private var normalizedLocalPart: String {
        var value = localPart.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix("@mcmaster.ca") {
            value.removeLast("@mcmaster.ca".count)
        }
        return value
    }

    private var email: String {
        "\(normalizedLocalPart)@mcmaster.ca"
    }

    private var hasValidLocalPart: Bool {
        !normalizedLocalPart.isEmpty
            && normalizedLocalPart.range(
                of: "^[a-z0-9._%+-]+$",
                options: .regularExpression
            ) != nil
    }

    var body: some View {
        ZStack {
            AppColors.pageBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    verificationHeader

                    if isLoading {
                        ProgressView()
                            .tint(maroon)
                            .padding(.top, 28)
                    } else if isVerified {
                        verifiedCard
                    } else {
                        verificationForm
                    }

                    if let message {
                        Text(message)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isError ? Color.red : Color.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }

                    Text("认证邮箱只用于确认麦马学生身份，不会显示在个人主页或帖子中。其他用户只能看到认证徽章。")
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
        }
        .cheesePageTopBar(title: "麦马学生认证")
        .task { await loadStatus() }
        .onDisappear { countdownTask?.cancel() }
        .alert("解除麦马学生认证？", isPresented: $showingUnlinkConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认解除绑定", role: .destructive) {
                Task { await unlinkVerification() }
            }
        } message: {
            Text("解除后学生徽章会立即消失，这个麦马邮箱也可以重新绑定其他账号。以后仍可再次完成认证。")
        }
    }

    private var verificationHeader: some View {
        VStack(spacing: 10) {
            McMasterStudentBadge(style: .label)
                .scaleEffect(1.18)

            Text("验证 McMaster 邮箱")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)

            Text("验证码会发送到你的 @mcmaster.ca 邮箱，通过后获得“麦马学生”徽章。")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var verifiedCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(maroon)

            Text("认证完成")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)

            if let maskedEmail = status?.maskedEmail {
                Text(maskedEmail)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppColors.textMuted)
            }

            Text("你的个人主页、论坛帖子和二手发布昵称旁会显示麦马学生徽章。")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textMuted)
                .multilineTextAlignment(.center)

            Divider()
                .overlay(AppColors.divider)
                .padding(.top, 4)

            Button {
                showingUnlinkConfirmation = true
            } label: {
                HStack(spacing: 8) {
                    if isUnlinking {
                        ProgressView()
                            .tint(.red)
                    } else {
                        Image(systemName: "link.badge.minus")
                    }
                    Text("解除绑定")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isUnlinking)
            .opacity(isUnlinking ? 0.55 : 1)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .cheeseCardChrome(cornerRadius: 18)
    }

    private var verificationForm: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("麦马邮箱")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)

                HStack(spacing: 4) {
                    TextField("MacID", text: $localPart)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.send)
                        .onSubmit { Task { await sendCode() } }

                    Text("@mcmaster.ca")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppColors.textMuted)
                        .fixedSize()
                }
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(AppColors.pageBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppColors.textPrimary, lineWidth: 1)
                }
            }

            Button {
                Task { await sendCode() }
            } label: {
                HStack(spacing: 8) {
                    if isSending { ProgressView().tint(.white) }
                    Text(sendButtonTitle)
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(maroon)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isSending || cooldownSeconds > 0 || !hasValidLocalPart)
            .opacity(isSending || cooldownSeconds > 0 || !hasValidLocalPart ? 0.55 : 1)

            if codeWasSent {
                Divider().overlay(AppColors.divider)

                VStack(alignment: .leading, spacing: 8) {
                    Text("6 位验证码")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)

                    TextField("000000", text: $code)
                        .keyboardType(.numberPad)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .onChange(of: code) { _, value in
                            code = String(value.filter(\.isNumber).prefix(6))
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 50)
                        .background(AppColors.pageBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppColors.textPrimary, lineWidth: 1)
                        }
                }

                Button {
                    Task { await verifyCode() }
                } label: {
                    HStack(spacing: 8) {
                        if isVerifying { ProgressView().tint(AppColors.textPrimary) }
                        Text("完成认证")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(gold)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isVerifying || code.count != 6)
                .opacity(isVerifying || code.count != 6 ? 0.55 : 1)
            }
        }
        .padding(16)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .cheeseCardChrome(cornerRadius: 18)
    }

    private var sendButtonTitle: String {
        if cooldownSeconds > 0 { return "\(cooldownSeconds) 秒后可重发" }
        return codeWasSent ? "重新发送验证码" : "发送验证码"
    }

    @MainActor
    private func loadStatus() async {
        isLoading = true
        defer { isLoading = false }
        do {
            status = try await McMasterVerificationService.status()
            message = nil
        } catch {
            show(error.localizedDescription, asError: true)
        }
    }

    @MainActor
    private func sendCode() async {
        guard !isSending, cooldownSeconds == 0 else { return }
        guard hasValidLocalPart else {
            show("请输入有效的 McMaster MacID。", asError: true)
            return
        }
        dismissKeyboard()
        isSending = true
        defer { isSending = false }

        do {
            let result = try await McMasterVerificationService.sendCode(to: email)
            if result.verified == true {
                await loadStatus()
                if let userID = authService.currentUser?.id {
                    await authService.fetchUserProfile(userId: userID)
                }
                return
            }
            codeWasSent = result.sent == true
            code = ""
            startCooldown(seconds: result.retryAfterSeconds ?? 60)
            show("邮件服务器已接收验证码邮件，请检查麦马邮箱。", asError: false)
        } catch {
            show(error.localizedDescription, asError: true)
        }
    }

    @MainActor
    private func verifyCode() async {
        guard !isVerifying, code.count == 6 else { return }
        dismissKeyboard()
        isVerifying = true
        defer { isVerifying = false }

        do {
            status = try await McMasterVerificationService.verify(email: email, code: code)
            if let userID = authService.currentUser?.id {
                await authService.fetchUserProfile(userId: userID)
            }
            show("麦马学生认证成功。", asError: false)
        } catch {
            show(error.localizedDescription, asError: true)
        }
    }

    @MainActor
    private func unlinkVerification() async {
        guard !isUnlinking else { return }
        isUnlinking = true
        defer { isUnlinking = false }

        do {
            status = try await McMasterVerificationService.unlink()
            codeWasSent = false
            code = ""
            localPart = ""
            if var profile = authService.currentUser {
                profile.isMcMasterVerified = false
                authService.currentUser = profile
            }
            if let userID = authService.currentUser?.id {
                await authService.fetchUserProfile(userId: userID)
            }
            show("麦马学生认证已解除绑定。", asError: false)
        } catch {
            show(error.localizedDescription, asError: true)
        }
    }

    @MainActor
    private func startCooldown(seconds: Int) {
        countdownTask?.cancel()
        cooldownSeconds = max(0, seconds)
        countdownTask = Task {
            while !Task.isCancelled && cooldownSeconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                cooldownSeconds -= 1
            }
        }
    }

    @MainActor
    private func show(_ text: String, asError: Bool) {
        message = text
        isError = asError
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}
