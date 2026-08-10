//
//  ChatRoomView.swift
//  CheeseApp
//
//  💬 单聊会话页
//

import SwiftUI

struct ChatTimelineTimeSeparator: View {
    let date: Date

    var body: some View {
        let label = ChatTimeFormatter.timelineString(from: date)

        Text(label)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(AppColors.textMuted.opacity(0.82))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
            .accessibilityLabel(label)
    }
}

struct ChatRoomHistoryView: View {
    let conversation: ChatConversationPreview

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @StateObject private var chatService = ChatService.shared

    @State private var queryText = ""
    @State private var messages: [Message] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var filteredMessages: [Message] {
        let source = messages.sorted { $0.createdAt > $1.createdAt }
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return source }
        return source.filter { message in
            if message.messageType == "image" {
                return "图片消息".localizedCaseInsensitiveContains(trimmed)
            }
            return message.content.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        ZStack {
            AppColors.pageBackground.ignoresSafeArea()

            if isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在加载聊天记录...")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        searchBar

                        if filteredMessages.isEmpty {
                            VStack(spacing: 8) {
                                Text(queryText.isEmpty ? "暂无聊天记录" : "没有匹配结果")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(AppColors.textPrimary)
                                Text(queryText.isEmpty ? "开始聊天后会显示在这里。" : "换个关键词再试试。")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppColors.textMuted)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .cheeseCardChrome(cornerRadius: 14)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(filteredMessages) { message in
                                    historyRow(message)
                                    if message.id != filteredMessages.last?.id {
                                        Divider()
                                            .padding(.leading, 68)
                                    }
                                }
                            }
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .cheeseCardChrome(cornerRadius: 14)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("聊天记录")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(AppColors.pageBackground, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: { dismiss() }) {
                    PostToolbarIconCircle(icon: "chevron.left")
                }
                .buttonStyle(.plain)
            }
        }
        .task {
            await loadMessages()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
            CheeseSearchTextField(
                text: $queryText,
                placeholder: "搜索聊天内容",
                fontSize: 14
            )
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .cheeseInputChrome(cornerRadius: 12)
    }

    @ViewBuilder
    private func historyRow(_ message: Message) -> some View {
        let isMine = message.senderId == authService.currentUser?.id
        HStack(spacing: 10) {
            if message.messageType == "image",
               let reference = message.metadata?.chatMediaReference,
               reference.belongs(to: .direct, id: message.conversationId) {
                ChatPrivateMediaImageView(
                    reference: reference,
                    width: 48,
                    height: 48
                )
            } else if message.messageType == "image" {
                ChatPrivateMediaUnavailableView(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Circle()
                    .fill((isMine ? AppColors.chatOutgoingBubble : AppColors.cardBackground))
                    .frame(width: 42, height: 42)
                    .overlay {
                        Image(systemName: isMine ? "paperplane.fill" : "person.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(isMine ? "我" : conversation.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted)
                Text(message.messageType == "image" ? "图片消息" : message.content)
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(2)
            }

            Spacer()

            Text(messageDateText(message.createdAt))
                .font(.system(size: 11))
                .foregroundStyle(AppColors.textMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func loadMessages() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            messages = try await chatService.fetchMessages(conversationId: conversation.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func messageDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

struct ChatRoomTradeRecordsPlaceholderView: View {
    let conversation: ChatConversationPreview

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                fillerCard(
                    title: "交易记录",
                    subtitle: "功能建设中，后续将展示订单、收付款与纠纷节点。"
                )
                fillerCard(
                    title: "最近往来",
                    subtitle: "当前先保留入口，避免影响聊天详情布局。"
                )
                fillerCard(
                    title: "对方",
                    subtitle: conversation.displayName
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .background(AppColors.pageBackground.ignoresSafeArea())
        .navigationTitle("交易记录")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(AppColors.pageBackground, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: { dismiss() }) {
                    PostToolbarIconCircle(icon: "chevron.left")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func fillerCard(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .cheeseCardChrome(cornerRadius: 14)
    }
}

struct ReportUserSheet: View {
    let isSubmitting: Bool
    let onSubmit: (_ reason: String, _ details: String?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reason = "骚扰辱骂"
    @State private var details = ""

    private let reasonOptions = ["骚扰辱骂", "诈骗", "不当内容", "其他"]

    var body: some View {
        NavigationStack {
            Form {
                Section("举报原因") {
                    Picker("原因", selection: $reason) {
                        ForEach(reasonOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("补充说明（可选）") {
                    TextEditor(text: $details)
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle("举报用户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(AppColors.pageBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("提交") {
                        Task {
                            await onSubmit(reason, details)
                        }
                    }
                    .disabled(isSubmitting)
                    .fontWeight(.semibold)
                }
            }
            .tint(AppColors.textPrimary)
        }
    }
}
