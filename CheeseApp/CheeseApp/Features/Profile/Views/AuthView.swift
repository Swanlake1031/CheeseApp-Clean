//
//  AuthView.swift
//  CheeseApp
//
//  🔐 登录/注册视图
//  用户认证入口，支持邮箱登录和注册
//

import SwiftUI
import UIKit

private struct AppLaunchAnnouncement: Decodable, Identifiable, Hashable {
    let id: UUID
    let announcementKey: String
    let titleEnglish: String
    let titleChinese: String
    let itemsEnglish: [String]
    let itemsChinese: [String]

    var localizedTitle: String {
        AppLanguageStore.shared.current == .chinese
            ? titleChinese
            : titleEnglish
    }

    var localizedMessage: String {
        let items = AppLanguageStore.shared.current == .chinese
            ? itemsChinese
            : itemsEnglish
        return items.map { "• \($0)" }.joined(separator: "\n\n")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case announcementKey = "announcement_key"
        case titleEnglish = "title_en"
        case titleChinese = "title_zh"
        case itemsEnglish = "items_en"
        case itemsChinese = "items_zh"
    }
}

@MainActor
private enum AppLaunchAnnouncementService {
    private static let acknowledgedKey = "acknowledged_app_launch_announcement_key"

    static func currentUnacknowledged() async throws -> AppLaunchAnnouncement? {
        let announcements: [AppLaunchAnnouncement] = try await SupabaseManager.shared
            .database("app_announcements")
            .select("id,announcement_key,title_en,title_zh,items_en,items_zh")
            .order("published_at", ascending: false)
            .limit(1)
            .execute()
            .value

        guard let announcement = announcements.first,
              UserDefaults.standard.string(forKey: acknowledgedKey)
                != announcement.announcementKey
        else { return nil }
        return announcement
    }

    static func acknowledge(_ announcement: AppLaunchAnnouncement) {
        UserDefaults.standard.set(
            announcement.announcementKey,
            forKey: acknowledgedKey
        )
    }
}

struct AuthView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject private var languageStore: AppLanguageStore
    
    @State private var isLogin = true
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var showPassword = false
    @State private var activeSocialProvider: SocialProvider?
    @State private var recentAccountPendingRemoval: RecentLoginAccount?
    @State private var launchAnnouncement: AppLaunchAnnouncement?

    private enum SocialProvider {
        case apple
        case google
    }
    
    var body: some View {
        ZStack {
            // 背景色 - 奶酪米色
            AppColors.pageBackground
                .ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    Spacer(minLength: 16)

                    languageSwitcher
                    
                    // Logo 区域
                    logoSection

                    if isLogin && !authService.recentLoginAccounts.isEmpty {
                        recentLoginSection
                    }
                    
                    // 表单区域
                    formSection
                    
                    // 主按钮
                    primaryButton
                    
                    // 分割线
                    divider
                    
                    // 社交登录
                    socialLogin
                    
                    // 切换登录/注册
                    switchModeButton
                    
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 24)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            dismissKeyboard()
        }
        .navigationBarHidden(true)
        .alert(
            "移除已保存账号？",
            isPresented: Binding(
                get: { recentAccountPendingRemoval != nil },
                set: { if !$0 { recentAccountPendingRemoval = nil } }
            ),
            presenting: recentAccountPendingRemoval
        ) { account in
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) {
                removeRecentAccount(account)
            }
        } message: { account in
            Text("将从这台设备移除 \(account.displayLabel) 的最近登录记录和本地登录凭据，不会注销线上账号。")
        }
        .alert(
            launchAnnouncement?.localizedTitle ?? "",
            isPresented: Binding(
                get: { launchAnnouncement != nil },
                set: { if !$0 { launchAnnouncement = nil } }
            ),
            presenting: launchAnnouncement
        ) { announcement in
            Button(L10n.tr("Got it", "我知道了"), role: .cancel) {
                AppLaunchAnnouncementService.acknowledge(announcement)
                launchAnnouncement = nil
            }
        } message: { announcement in
            Text(announcement.localizedMessage)
        }
        .task {
            await loadLaunchAnnouncement()
        }
    }

    private var languageSwitcher: some View {
        HStack {
            Spacer()
            Picker("Language", selection: Binding(
                get: { languageStore.current },
                set: { languageStore.setLanguage($0) }
            )) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
        }
    }

    private func loadLaunchAnnouncement() async {
        do {
            launchAnnouncement = try await AppLaunchAnnouncementService.currentUnacknowledged()
        } catch {
            // A launch notice is informational and must never block login when
            // the network or announcement endpoint is unavailable.
        }
    }
    
    // MARK: - Logo 区域
    private var logoSection: some View {
        VStack(spacing: 16) {
            // Logo
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.95, green: 0.85, blue: 0.45),
                                Color(red: 0.95, green: 0.75, blue: 0.35)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                    .shadow(color: Color(red: 0.95, green: 0.85, blue: 0.45).opacity(0.4), radius: 20, x: 0, y: 10)
                
                Text("🧀")
                    .font(.system(size: 48))
            }
            
            // 标题
            VStack(spacing: 6) {
                Text("Cheese")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
                
                Text(L10n.tr("Student Community", "学生社群"))
                    .font(.system(size: 16))
                    .foregroundStyle(AppColors.textMuted)
            }
        }
    }

    private var signUpHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("After registration, you'll complete your profile on first app entry.", "注册后首次进入 App 需要补充个人资料"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
            Text(L10n.tr("Required in profile completion: Nickname and school. Other details are optional.", "完善资料必填：昵称与学校。其他资料均为选填。"))
                .font(.system(size: 12))
                .foregroundStyle(AppColors.textMuted)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - 表单区域
    private var formSection: some View {
        VStack(spacing: 16) {
            if !isLogin {
                signUpHint
            }

            // 邮箱
            CustomTextField(
                icon: "envelope.fill",
                placeholder: L10n.tr("Email", "邮箱"),
                text: $email,
                keyboardType: .emailAddress
            )

            if !isLogin && isGmailInput {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(AppColors.link)
                    Text("检测到 Gmail 邮箱，建议使用下方 Google 登录进行注册。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColors.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            // 密码
            CustomTextField(
                icon: "lock.fill",
                placeholder: L10n.tr("Password", "密码"),
                text: $password,
                isSecure: !showPassword,
                trailingIcon: showPassword ? "eye.slash.fill" : "eye.fill",
                trailingAction: { showPassword.toggle() }
            )
            
            // 忘记密码（仅登录时显示）
            if isLogin {
                HStack {
                    Spacer()
                    Button(action: { }) {
                        Text(L10n.tr("Forgot Password?", "忘记密码？"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AppColors.link)
                    }
                }
            }
            
            // 错误提示
            if let error = authService.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .animation(.spring(response: 0.3), value: isLogin)
    }

    private var recentLoginSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近登录")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Text("最多 \(authService.maxRecentLoginCount) 个")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppColors.textMuted)
            }

            ForEach(authService.recentLoginAccounts) { account in
                HStack(spacing: 10) {
                    Button {
                        applyRecentAccount(account)
                    } label: {
                        HStack(spacing: 12) {
                            recentAccountAvatar(account)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayLabel)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AppColors.textPrimary)
                                Text(account.email)
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppColors.textMuted)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(recentAccountActionText(account))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppColors.link)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        recentAccountPendingRemoval = account
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(width: 34, height: 34)
                            .background(Color.red.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除 \(account.displayLabel)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 3)
    }
    
    // MARK: - 主按钮
    private var primaryButton: some View {
        Button(action: {
            performAuth()
        }) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                } else {
                    Text(isLogin ? L10n.tr("Sign In", "登录") : L10n.tr("Create Account", "创建账号"))
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color(red: 0.95, green: 0.85, blue: 0.45))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color(red: 0.95, green: 0.85, blue: 0.45).opacity(0.4), radius: 12, x: 0, y: 6)
        }
        .disabled(isLoading || !isFormValid)
        .opacity(isFormValid ? 1 : 0.6)
    }
    
    // MARK: - 分割线
    private var divider: some View {
        HStack(spacing: 16) {
            Rectangle()
                .fill(AppColors.divider)
                .frame(height: 1)
            
            Text(L10n.tr("or continue with", "或使用以下方式"))
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textMuted)
            
            Rectangle()
                .fill(AppColors.divider)
                .frame(height: 1)
        }
    }
    
    // MARK: - 社交登录
    private var socialLogin: some View {
        HStack(spacing: 16) {
            SocialLoginButton(
                icon: "apple.logo",
                name: L10n.tr("Apple", "苹果"),
                isLoading: activeSocialProvider == .apple,
                isDisabled: isLoading || activeSocialProvider != nil,
                action: performAppleSignIn
            )
            SocialLoginButton(
                icon: "g.circle.fill",
                name: L10n.tr("Google", "谷歌"),
                isLoading: activeSocialProvider == .google,
                isDisabled: isLoading || activeSocialProvider != nil,
                action: performGoogleSignIn
            )
        }
    }
    
    // MARK: - 切换模式按钮
    private var switchModeButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3)) {
                isLogin.toggle()
            }
        }) {
            HStack(spacing: 4) {
                Text(isLogin ? L10n.tr("Don't have an account?", "还没有账号？") : L10n.tr("Already have an account?", "已有账号？"))
                    .foregroundStyle(AppColors.textMuted)
                
                Text(isLogin ? L10n.tr("Sign Up", "注册") : L10n.tr("Sign In", "登录"))
                    .fontWeight(.semibold)
                    .foregroundStyle(AppColors.link)
            }
            .font(.system(size: 15))
        }
    }
    
    // MARK: - 辅助方法
    private var isFormValid: Bool {
        let emailValid = email.contains("@") && email.contains(".")
        let passwordValid = password.count >= 6
        return emailValid && passwordValid
    }

    private var isGmailInput: Bool {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasSuffix("@gmail.com") || normalized.hasSuffix("@googlemail.com")
    }
    
    private func performAuth() {
        isLoading = true
        Task { @MainActor in
            defer { isLoading = false }
            do {
                if isLogin {
                    try await authService.signIn(email: email, password: password)
                } else {
                    try await authService.signUp(
                        email: email,
                        password: password
                    )
                }
            } catch {
                if authService.errorMessage?.isEmpty ?? true {
                    authService.errorMessage = L10n.tr(
                        "Authentication failed. Please try again.",
                        "认证失败，请重试。"
                    )
                }
            }
        }
    }

    private func performGoogleSignIn() {
        guard activeSocialProvider == nil else { return }
        let isSignUpFlow = !isLogin
        activeSocialProvider = .google

        Task { @MainActor in
            defer { activeSocialProvider = nil }
            do {
                try await authService.signInWithGoogle()
                if isSignUpFlow, authService.currentUser?.profileCompleted != true {
                    authService.requiresProfileCompletion = true
                }
            } catch {
                if authService.errorMessage?.isEmpty ?? true {
                    authService.errorMessage = L10n.tr(
                        "Google sign-in failed. Please try again.",
                        "谷歌登录失败，请重试。"
                    )
                }
            }
        }
    }

    private func performAppleSignIn() {
        guard activeSocialProvider == nil else { return }
        let isSignUpFlow = !isLogin
        activeSocialProvider = .apple

        Task { @MainActor in
            defer { activeSocialProvider = nil }
            do {
                try await authService.signInWithApple()
                if isSignUpFlow, authService.currentUser?.profileCompleted != true {
                    authService.requiresProfileCompletion = true
                }
            } catch {
                if authService.errorMessage?.isEmpty ?? true {
                    authService.errorMessage = L10n.tr(
                        "Apple sign-in failed. Please try again.",
                        "苹果登录失败，请重试。"
                    )
                }
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    @ViewBuilder
    private func recentAccountAvatar(_ account: RecentLoginAccount) -> some View {
        if let avatar = account.avatarURL,
           let url = URL(string: avatar),
           !avatar.isEmpty {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Color.gray.opacity(0.16)
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.gray.opacity(0.16))
                .frame(width: 36, height: 36)
                .overlay(
                    Text(String(account.displayLabel.prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AppColors.textMuted)
                )
        }
    }

    private func applyRecentAccount(_ account: RecentLoginAccount) {
        isLogin = true
        password = ""
        email = account.email
        authService.errorMessage = nil
        dismissKeyboard()

        switch account.signInMethod {
        case .google:
            performGoogleSignIn()
        case .apple:
            performAppleSignIn()
        case .password:
            break
        }
    }

    private func removeRecentAccount(_ account: RecentLoginAccount) {
        authService.removeRecentLoginAccount(userId: account.id)
        if email.caseInsensitiveCompare(account.email) == .orderedSame {
            email = ""
            password = ""
        }
        recentAccountPendingRemoval = nil
    }

    private func recentAccountActionText(_ account: RecentLoginAccount) -> String {
        switch account.signInMethod {
        case .google:
            return "Google登录"
        case .apple:
            return "Apple登录"
        case .password:
            return "使用"
        }
    }
}

// MARK: - 自定义输入框
struct CustomTextField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var isSecure: Bool = false
    var trailingIcon: String? = nil
    var trailingAction: (() -> Void)? = nil
    var textInputAutocapitalization: TextInputAutocapitalization = .never
    var disableAutocorrection: Bool = true
    
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(AppColors.textMuted)
                .frame(width: 24)
            
            if isSecure {
                SecureField(placeholder, text: $text)
                    .font(.system(size: 16))
            } else {
                TextField(placeholder, text: $text)
                    .font(.system(size: 16))
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(textInputAutocapitalization)
                    .autocorrectionDisabled(disableAutocorrection)
            }
            
            if let trailingIcon = trailingIcon {
                Button(action: { trailingAction?() }) {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 16))
                        .foregroundStyle(AppColors.textMuted)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 4)
    }
}

// MARK: - 社交登录按钮
struct SocialLoginButton: View {
    let icon: String
    let name: String
    var isLoading: Bool = false
    var isDisabled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                }
                
                Text(name)
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(AppColors.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 4)
        }
        .disabled(isDisabled || isLoading)
        .opacity((isDisabled || isLoading) ? 0.55 : 1)
    }
}

// MARK: - Preview
#Preview {
    AuthView()
        .environmentObject(AuthService.shared)
}
