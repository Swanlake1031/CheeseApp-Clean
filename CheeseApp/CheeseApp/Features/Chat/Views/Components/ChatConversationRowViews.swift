import SwiftUI

struct SwipeableConversationNavigationRow: View {
    private enum SwipeDragAxis {
        case none
        case horizontal
        case vertical
    }

    let conversation: ChatConversationPreview
    @Binding var activeSwipeConversationId: UUID?
    @Binding var isAnyRowHorizontallyDragging: Bool
    let onOpenConversation: () -> Void
    let onOpenProfile: () -> Void
    let onDelete: () -> Void

    @State private var restingOffset: CGFloat = 0
    @State private var dragTranslation: CGFloat = 0
    @State private var dragAxis: SwipeDragAxis = .none

    private let deleteActionWidth: CGFloat = 168
    private let swipeOpenThreshold: CGFloat = 62
    private let swipeCloseDistance: CGFloat = 56
    private var maxReveal: CGFloat { deleteActionWidth }
    private var currentOffset: CGFloat {
        let raw = restingOffset + dragTranslation
        return min(0, max(-maxReveal, raw))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            swipeActionButton(
                title: "确认删除",
                color: Color(red: 0.92, green: 0.23, blue: 0.29),
                width: deleteActionWidth,
                action: {
                    onDelete()
                }
            )
            .frame(width: maxReveal)
            .frame(maxHeight: .infinity)

            ChatRow(
                conversation: conversation,
                onAvatarTap: onOpenProfile
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if currentOffset < -1 {
                    closeActions(resetActive: true)
                    return
                }
                onOpenConversation()
            }
            .offset(x: currentOffset)
            .simultaneousGesture(dragGesture)
        }
        .clipped()
        .animation(.spring(response: 0.22, dampingFraction: 0.88), value: currentOffset)
        .onChange(of: activeSwipeConversationId) { _, newValue in
            guard newValue != conversation.id else { return }
            guard restingOffset != 0 || dragTranslation != 0 else { return }
            closeActions(resetActive: false)
        }
        .onDisappear {
            if dragAxis == .horizontal {
                isAnyRowHorizontallyDragging = false
            }
            dragAxis = .none
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = abs(value.translation.height)

                if dragAxis == .none {
                    guard max(horizontalDistance, verticalDistance) >= 6 else { return }
                    dragAxis = horizontalDistance > verticalDistance ? .horizontal : .vertical
                }

                guard dragAxis == .horizontal else {
                    dragTranslation = 0
                    isAnyRowHorizontallyDragging = false
                    return
                }

                if activeSwipeConversationId != conversation.id {
                    activeSwipeConversationId = conversation.id
                }
                isAnyRowHorizontallyDragging = true
                dragTranslation = value.translation.width
            }
            .onEnded { value in
                defer {
                    dragAxis = .none
                    isAnyRowHorizontallyDragging = false
                }

                guard dragAxis == .horizontal else {
                    dragTranslation = 0
                    return
                }
                let endOffset = min(0, max(-maxReveal, restingOffset + value.translation.width))
                let isCurrentlyOpen = restingOffset < -1
                let shouldOpen: Bool
                if isCurrentlyOpen {
                    let closeCutoff = -(maxReveal - swipeCloseDistance)
                    shouldOpen = endOffset < closeCutoff
                } else {
                    shouldOpen = endOffset < -swipeOpenThreshold
                }
                withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                    restingOffset = shouldOpen ? -maxReveal : 0
                    dragTranslation = 0
                    activeSwipeConversationId = shouldOpen ? conversation.id : nil
                }
            }
    }

    private func closeActions(resetActive: Bool) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            restingOffset = 0
            dragTranslation = 0
            if resetActive, activeSwipeConversationId == conversation.id {
                activeSwipeConversationId = nil
            }
        }
    }
    private func swipeActionButton(
        title: String,
        color: Color,
        width: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .background(color)
        }
        .buttonStyle(.plain)
    }
}

struct ChatRow: View {
    let conversation: ChatConversationPreview
    let onAvatarTap: (() -> Void)?
    @StateObject private var chatService = ChatService.shared

    private var displayName: String {
        chatService.displayName(for: conversation)
    }

    var body: some View {
        HStack(spacing: 14) {
            avatarView

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(displayName)
                        .font(.system(size: 16, weight: .semibold))

                    Spacer()

                    HStack(spacing: 6) {
                        Text(formatTime(conversation.lastMessageAt))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if conversation.isMuted {
                            Image(systemName: "bell.slash.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppColors.textMuted.opacity(0.9))
                        }
                    }
                }

                Text(conversation.lastMessagePreview?.isEmpty == false ? conversation.lastMessagePreview! : "还没有消息")
                    .font(.system(size: 14))
                    .foregroundStyle(conversation.unreadCount > 0 ? .primary : .secondary)
                    .lineLimit(1)
            }

            if conversation.unreadCount > 0 {
                Text("\(conversation.unreadCount)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppColors.accent)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white)
    }

    private var avatarView: some View {
        Group {
            if let onAvatarTap {
                Button(action: onAvatarTap) {
                    avatarImage
                }
                .buttonStyle(.plain)
            } else {
                avatarImage
            }
        }
    }

    private var avatarImage: some View {
        Group {
            if let avatar = conversation.otherUserAvatar,
               let url = URL(string: avatar),
               !avatar.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        avatarFallback
                    }
                }
            } else {
                avatarFallback
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(Circle())
    }

    private var avatarFallback: some View {
        Circle()
            .fill(Color.gray.opacity(0.15))
            .overlay {
                Text(String(displayName.prefix(1)).uppercased())
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.gray)
            }
    }

    private func formatTime(_ date: Date) -> String {
        ChatListTimeFormatter.string(from: date)
    }
}

enum ChatListTimeFormatter {
    private static let todayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let sameYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM/dd"
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    static func string(from date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return todayFormatter.string(from: date)
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return sameYearFormatter.string(from: date)
        }
        return fullDateFormatter.string(from: date)
    }
}
