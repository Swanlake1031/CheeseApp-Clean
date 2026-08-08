import SwiftUI

enum ChatInboxSheetDestination: String, Identifiable {
    case createGroup
    case addFollow

    var id: String { rawValue }
}
struct ChatInboxSearchField: View {
    let placeholder: String
    @Binding var text: String
    var focus: Binding<Bool>?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppColors.textMuted)

            inputField

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(AppColors.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .cheeseInputChrome(cornerRadius: 14)
    }

    @ViewBuilder
    private var inputField: some View {
        CheeseSearchTextField(
            text: $text,
            placeholder: placeholder,
            fontSize: 14,
            isFirstResponder: focus
        )
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 22)
    }
}

struct MessageRequestsView: View {
    @StateObject private var chatService = ChatService.shared
    @State private var rowActionErrorMessage: String?
    @State private var activeSwipeConversationId: UUID?
    @State private var isSwipeHorizontallyDragging = false
    @State private var activeRoute: ChatInboxRoute?

    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()

            if chatService.messageRequests.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text("没有待处理的陌生人消息")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Text("你回复后，对话会自动回到主消息列表。")
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textMuted)
                }
                .padding(.horizontal, 20)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(chatService.messageRequests) { conversation in
                            ConversationSwipeActionRow(
                                conversation: conversation,
                                activeSwipeConversationId: $activeSwipeConversationId,
                                isAnyRowHorizontallyDragging: $isSwipeHorizontallyDragging,
                                rowActionErrorMessage: $rowActionErrorMessage,
                                onOpenConversation: {
                                    activeRoute = .conversation(conversation)
                                },
                                onOpenProfile: {
                                    activeRoute = .profile(conversation.otherUserId)
                                }
                            )

                            if conversation.id != chatService.messageRequests.last?.id {
                                Divider()
                                    .padding(.leading, 84)
                            }
                        }
                    }
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 4)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 100)
                }
                .scrollDisabled(isSwipeHorizontallyDragging)
            }
        }
        .overlay(alignment: .top) {
            if let rowActionErrorMessage, !rowActionErrorMessage.isEmpty {
                InlineErrorBanner(text: rowActionErrorMessage)
                    .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $activeRoute) { route in
            switch route {
            case .systemMessages:
                EmptyView()
            case .conversation(let conversation):
                ChatRoomView(conversation: currentConversationRoute(conversation))
            case .profile(let userID):
                UserPostsView(userId: userID)
            case .messageRequests, .group:
                EmptyView()
            }
        }
        .task {
            if !chatService.hasResolvedInitialConversationLoad {
                await chatService.refreshConversations()
            }
        }
        .refreshable {
            await chatService.refreshConversations()
        }
        .cheesePageTopBar(title: "陌生人消息")
    }

    private func currentConversationRoute(_ fallback: ChatConversationPreview) -> ChatConversationPreview {
        chatService.messageRequests.first(where: { $0.id == fallback.id })
        ?? chatService.conversations.first(where: { $0.id == fallback.id })
        ?? fallback
    }
}

struct InlineErrorBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer()
        }
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .cheeseCardChrome(cornerRadius: 12)
    }
}

struct ConversationSwipeActionRow: View {
    let conversation: ChatConversationPreview
    @Binding var activeSwipeConversationId: UUID?
    @Binding var isAnyRowHorizontallyDragging: Bool
    @Binding var rowActionErrorMessage: String?
    let onOpenConversation: () -> Void
    let onOpenProfile: () -> Void
    @StateObject private var chatService = ChatService.shared

    var body: some View {
        SwipeableConversationNavigationRow(
            conversation: conversation,
            activeSwipeConversationId: $activeSwipeConversationId,
            isAnyRowHorizontallyDragging: $isAnyRowHorizontallyDragging,
            onOpenConversation: onOpenConversation,
            onOpenProfile: onOpenProfile,
            onDelete: {
                Task {
                    do {
                        try await chatService.deleteConversation(conversationId: conversation.id)
                        rowActionErrorMessage = nil
                    } catch {
                        rowActionErrorMessage = error.localizedDescription
                    }
                }
            }
        )
    }
}
