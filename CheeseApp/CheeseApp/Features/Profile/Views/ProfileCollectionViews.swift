//
//  ProfileView.swift
//  CheeseApp
//
//  👤 个人中心视图
//  展示真实用户信息、我的发布、设置等
//

import SwiftUI
import PhotosUI

struct BlockedUsersView: View {
    @StateObject private var chatService = ChatService.shared
    @State private var blockedUsers: [BlockedUserSummary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var pendingUnblockUser: BlockedUserSummary?
    @State private var isApplying = false

    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else if blockedUsers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("暂无拉黑用户")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                }
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(blockedUsers) { user in
                            HStack(spacing: 12) {
                                avatarView(urlString: user.avatarURL, fallbackText: user.displayName)
                                    .frame(width: 44, height: 44)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(user.displayName)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(AppColors.textPrimary)

                                    Text("拉黑于 \(formatBlockedDate(user.blockedAt))")
                                        .font(.system(size: 12))
                                        .foregroundStyle(AppColors.textMuted)
                                }

                                Spacer()

                                Button("解除") {
                                    pendingUnblockUser = user
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AppColors.link)
                                .disabled(isApplying)
                            }
                            .padding(14)
                            .background(AppColors.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .refreshable {
                    await loadBlockedUsers()
                }
            }

            if let errorMessage {
                VStack {
                    Spacer()
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.bottom, 16)
                }
                .padding(.horizontal, 16)
            }
        }
        .cheesePageTopBar(title: "黑名单管理")
        .task {
            await loadBlockedUsers()
        }
        .alert(
            "解除拉黑？",
            isPresented: Binding(
                get: { pendingUnblockUser != nil },
                set: { if !$0 { pendingUnblockUser = nil } }
            ),
            presenting: pendingUnblockUser
        ) { user in
            Button("取消", role: .cancel) {
                pendingUnblockUser = nil
            }
            Button("解除", role: .destructive) {
                Task { await unblock(user) }
            }
        } message: { user in
            Text("解除后，\(user.displayName) 可再次私信并访问你的主页。")
        }
    }

    @MainActor
    private func loadBlockedUsers() async {
        isLoading = true
        defer { isLoading = false }
        do {
            blockedUsers = try await chatService.fetchBlockedUsers()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func unblock(_ user: BlockedUserSummary) async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        do {
            try await chatService.setUserBlocked(user.id, blocked: false)
            blockedUsers.removeAll { $0.id == user.id }
            pendingUnblockUser = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func avatarView(urlString: String?, fallbackText: String) -> some View {
        Group {
            if let urlString, let url = URL(string: urlString), !urlString.isEmpty {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    avatarFallback(fallbackText)
                }
            } else {
                avatarFallback(fallbackText)
            }
        }
        .clipShape(Circle())
        .tappableAvatarPreview(urlString)
    }

    private func avatarFallback(_ text: String) -> some View {
        Circle()
            .fill(AppColors.accent.opacity(0.2))
            .overlay {
                Text(String(text.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
            }
    }

    private func formatBlockedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - Preview
#Preview {
    ProfileView()
        .environmentObject(AuthService.shared)
}
