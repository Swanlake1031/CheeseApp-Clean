//
//  ProfileView.swift
//  CheeseApp
//
//  👤 个人中心视图
//  展示真实用户信息、我的发布、设置等
//

import SwiftUI
import PhotosUI

struct AccountSwitcherView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @State private var switchingAccountId: UUID?
    @State private var errorMessage: String?

    private var currentUserId: UUID? {
        authService.currentUser?.id
    }

    private var accountLimitReached: Bool {
        authService.savedAccounts.count >= authService.maxSavedAccountCount
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.pageBackground
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        NavigationLink {
                            AddAccountView()
                                .environmentObject(authService)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(AppColors.link)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("添加新账号")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(AppColors.textPrimary)
                                    Text(accountLimitReached
                                        ? "已达到上限，请先移除一个账号"
                                        : "进入独立页面登录，不会打乱当前账号")
                                        .font(.system(size: 12))
                                        .foregroundStyle(accountLimitReached ? .red : AppColors.textMuted)
                                }
                                Spacer()
                            }
                            .padding(14)
                            .background(AppColors.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(switchingAccountId != nil || accountLimitReached)
                        .opacity((switchingAccountId != nil || accountLimitReached) ? 0.65 : 1)

                        if accountLimitReached {
                            Text("你已保存 \(authService.maxSavedAccountCount) 个账号。请先手动移除一个账号，再添加新账号。")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        ForEach(authService.savedAccounts) { account in
                            accountRow(account)
                        }

                        if authService.savedAccounts.isEmpty {
                            Text("暂无可切换账号，请先添加账号。")
                                .font(.system(size: 14))
                                .foregroundStyle(AppColors.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        }

                        if let errorMessage, !errorMessage.isEmpty {
                            Text(errorMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("切换账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(AppColors.pageBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ account: SavedAuthAccount) -> some View {
        let isCurrent = account.id == currentUserId
        let isSwitching = switchingAccountId == account.id

        VStack(spacing: 10) {
            HStack(spacing: 12) {
                avatar(for: account)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(account.displayLabel)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                        if isCurrent {
                            Text("当前")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.16))
                                .foregroundStyle(Color.green)
                                .clipShape(Capsule())
                        }
                    }
                    Text(account.email)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textMuted)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    Task { await switchAccount(account.id) }
                } label: {
                    Text(isCurrent ? "已在使用" : (isSwitching ? "切换中..." : "切换"))
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isCurrent ? Color.gray.opacity(0.15) : AppColors.link.opacity(0.15))
                        .foregroundStyle(isCurrent ? AppColors.textMuted : AppColors.link)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .disabled(isCurrent || isSwitching || switchingAccountId != nil)

                if isCurrent {
                    Text("当前账号不可移除")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.gray.opacity(0.12))
                        .foregroundStyle(AppColors.textMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Button {
                        authService.removeSavedAccount(userId: account.id)
                    } label: {
                        Text("从本机移除")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.12))
                            .foregroundStyle(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .disabled(switchingAccountId != nil)
                }
            }
        }
        .padding(14)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func avatar(for account: SavedAuthAccount) -> some View {
        if let avatar = account.avatarURL,
           let url = URL(string: avatar),
           !avatar.isEmpty {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.gray.opacity(0.16)
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.gray.opacity(0.18))
                .frame(width: 44, height: 44)
                .overlay(
                    Text(String(account.displayLabel.prefix(1)).uppercased())
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppColors.textMuted)
                )
        }
    }

    @MainActor
    private func switchAccount(_ userId: UUID) async {
        guard switchingAccountId == nil else { return }
        switchingAccountId = userId
        errorMessage = nil
        defer { switchingAccountId = nil }

        do {
            try await authService.switchToAccount(userId: userId)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var isLoading = false
    @State private var activeSocialProvider: SocialProvider?
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private enum SocialProvider {
        case apple
        case google
    }

    private var accountLimitReached: Bool {
        authService.savedAccounts.count >= authService.maxSavedAccountCount
    }

    @MainActor
    private func addByEmail() async {
        guard !accountLimitReached else {
            errorMessage = "已达到 \(authService.maxSavedAccountCount) 个账号上限，请先移除一个账号再添加。"
            successMessage = nil
            return
        }
        if isGmailInput {
            errorMessage = "检测到 Gmail 邮箱，请使用下方 Google 登录添加账号。"
            successMessage = nil
            return
        }
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { isLoading = false }

        do {
            let addedId = try await authService.addAccount(email: email, password: password)
            if addedId == authService.currentUser?.id {
                finishAddAccountFlow(message: "该账号已是当前登录账号。")
            } else {
                finishAddAccountFlow(message: "账号已添加成功。")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func addByGoogle() async {
        guard !accountLimitReached else {
            errorMessage = "已达到 \(authService.maxSavedAccountCount) 个账号上限，请先移除一个账号再添加。"
            successMessage = nil
            return
        }
        guard activeSocialProvider == nil else { return }
        activeSocialProvider = .google
        errorMessage = nil
        successMessage = nil
        defer { activeSocialProvider = nil }

        do {
            _ = try await authService.addAccountWithGoogle()
            finishAddAccountFlow(message: "Google 账号已添加成功。")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func addByApple() async {
        guard !accountLimitReached else {
            errorMessage = "已达到 \(authService.maxSavedAccountCount) 个账号上限，请先移除一个账号再添加。"
            successMessage = nil
            return
        }
        guard activeSocialProvider == nil else { return }
        activeSocialProvider = .apple
        errorMessage = nil
        successMessage = nil
        defer { activeSocialProvider = nil }

        do {
            _ = try await authService.addAccountWithApple()
            finishAddAccountFlow(message: "Apple 账号已添加成功。")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func finishAddAccountFlow(message: String) {
        successMessage = message
        dismiss()
    }

    private var canSubmitEmail: Bool {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalizedEmail.isEmpty && normalizedEmail.contains("@") && password.count >= 6
    }

    private var isGmailInput: Bool {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasSuffix("@gmail.com") || normalized.hasSuffix("@googlemail.com")
    }

    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    if accountLimitReached {
                        Text("你已保存 \(authService.maxSavedAccountCount) 个账号，请先返回上一页移除一个账号，再继续添加。")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("邮箱登录添加")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)

                        CustomTextField(
                            icon: "envelope.fill",
                            placeholder: "邮箱",
                            text: $email,
                            keyboardType: .emailAddress
                        )

                        if isGmailInput {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(AppColors.link)
                                Text("检测到 Gmail 邮箱，请使用下方 Google 登录添加账号。")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AppColors.textMuted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        CustomTextField(
                            icon: "lock.fill",
                            placeholder: "密码",
                            text: $password,
                            isSecure: !showPassword,
                            trailingIcon: showPassword ? "eye.slash.fill" : "eye.fill",
                            trailingAction: { showPassword.toggle() }
                        )

                        Button {
                            Task { await addByEmail() }
                        } label: {
                            HStack(spacing: 8) {
                                if isLoading {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                } else {
                                    Image(systemName: "plus.circle.fill")
                                }
                                Text(isLoading ? "添加中..." : "添加账号")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(AppColors.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSubmitEmail || isLoading || activeSocialProvider != nil || isGmailInput || accountLimitReached)
                        .opacity((!canSubmitEmail || isLoading || activeSocialProvider != nil || isGmailInput || accountLimitReached) ? 0.6 : 1)
                    }
                    .padding(16)
                    .background(AppColors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .cheeseCardChrome(cornerRadius: 16)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("社交账号添加")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)

                        HStack(spacing: 10) {
                            SocialLoginButton(
                                icon: "apple.logo",
                                name: "Apple",
                                isLoading: activeSocialProvider == .apple,
                                isDisabled: isLoading || activeSocialProvider != nil || accountLimitReached,
                                action: { Task { await addByApple() } }
                            )
                            SocialLoginButton(
                                icon: "g.circle.fill",
                                name: "Google",
                                isLoading: activeSocialProvider == .google,
                                isDisabled: isLoading || activeSocialProvider != nil || accountLimitReached,
                                action: { Task { await addByGoogle() } }
                            )
                        }
                    }
                    .padding(16)
                    .background(AppColors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .cheeseCardChrome(cornerRadius: 16)

                    Text("提示：添加账号不会退出当前账号，最多同时保存 \(authService.maxSavedAccountCount) 个账号。")
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)

                    if let successMessage, !successMessage.isEmpty {
                        Text(successMessage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
        }
        .cheesePageTopBar(title: "添加账号") {
            Button("完成") {
                dismiss()
            }
            .fontWeight(.semibold)
            .foregroundStyle(AppColors.textPrimary)
        }
    }
}
