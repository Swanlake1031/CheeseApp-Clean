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
