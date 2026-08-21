import SwiftUI

struct GroupChatDetailsView: View {
    let onLeftGroup: () -> Void
    let onClearedHistory: (Date) -> Void
    let onRenamed: (String) -> Void
    let onAnnouncementUpdated: (String?) -> Void
    let onMemberDisplayNamesUpdated: ([UUID: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: GroupChatDetailsViewModel
    @State private var showRenameSheet = false
    @State private var showNicknameSheet = false
    @State private var showAddMembersSheet = false
    @State private var showHistory = false
    @State private var showAnnouncementEditor = false
    @State private var showAnnouncementDetail = false

    init(
        group: ChatGroupPreview,
        onLeftGroup: @escaping () -> Void,
        onClearedHistory: @escaping (Date) -> Void = { _ in },
        onRenamed: @escaping (String) -> Void = { _ in },
        onAnnouncementUpdated: @escaping (String?) -> Void = { _ in },
        onMemberDisplayNamesUpdated: @escaping ([UUID: String]) -> Void = { _ in }
    ) {
        self.onLeftGroup = onLeftGroup
        self.onClearedHistory = onClearedHistory
        self.onRenamed = onRenamed
        self.onAnnouncementUpdated = onAnnouncementUpdated
        self.onMemberDisplayNamesUpdated = onMemberDisplayNamesUpdated
        _viewModel = StateObject(wrappedValue: GroupChatDetailsViewModel(group: group))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                header
                membersCard
                settingsCard
                leaveButton

                if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(AppColors.pageBackground.ignoresSafeArea())
        .cheesePageTopBar(title: "群聊详情")
        .cheeseTabBarHidden(true)
        .task {
            await viewModel.loadIfNeeded()
        }
        .alert(item: $viewModel.alertDestination) { destination in
            alert(for: destination)
        }
        .navigationDestination(item: $viewModel.profileUserID) { userID in
            UserPostsView(userId: userID)
        }
        .navigationDestination(isPresented: $showHistory) {
            GroupChatHistoryView(group: viewModel.group)
        }
        .sheet(isPresented: $showRenameSheet) {
            GroupDetailsTextEditorSheet(
                title: "修改群聊名称",
                placeholder: "输入群聊名称",
                initialValue: viewModel.groupName,
                maximumLength: 40
            ) { value in
                guard let value else { return false }
                if await viewModel.renameGroup(value) {
                    onRenamed(viewModel.groupName)
                    return true
                }
                return false
            }
        }
        .sheet(isPresented: $showNicknameSheet) {
            GroupDetailsTextEditorSheet(
                title: "我在群里的昵称",
                placeholder: "留空则使用个人昵称",
                initialValue: viewModel.myNickname ?? "",
                maximumLength: 30,
                allowsEmpty: true
            ) { value in
                if await viewModel.updateMyNickname(value) {
                    onMemberDisplayNamesUpdated(viewModel.memberDisplayNamesByID)
                    return true
                }
                return false
            }
        }
        .sheet(isPresented: $showAddMembersSheet) {
            AddGroupMembersSheet(
                existingMemberIDs: Set(viewModel.members.map(\.id)),
                onAdd: viewModel.addMembers
            )
        }
        .sheet(isPresented: $showAnnouncementEditor) {
            GroupAnnouncementEditorSheet(initialValue: viewModel.announcement ?? "") { value in
                if await viewModel.updateAnnouncement(value) {
                    onAnnouncementUpdated(viewModel.announcement)
                    return true
                }
                return false
            }
        }
        .sheet(isPresented: $showAnnouncementDetail) {
            GroupAnnouncementDetailSheet(announcement: viewModel.announcement ?? "暂无群公告")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            groupAvatar
                .frame(width: 86, height: 86)
                .clipShape(Circle())
                .tappableImagePreview(viewModel.group.avatarURL)

            Text(viewModel.groupName)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)

            Text("\(viewModel.effectiveMemberCount) 人")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textMuted)
        }
        .padding(.top, 8)
    }

    private var membersCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("群成员")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Text("\(viewModel.effectiveMemberCount)")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textMuted)
                Button {
                    showAddMembersSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加成员")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if viewModel.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("正在加载成员...")
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            } else if viewModel.members.isEmpty {
                Text("暂无成员数据")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            } else {
                ForEach(viewModel.members) { member in
                    GroupDetailMemberRow(
                        member: member,
                        canRemove: viewModel.isOwner && member.role != "owner",
                        onOpenProfile: {
                            viewModel.profileUserID = member.id
                        },
                        onRemove: {
                            viewModel.requestRemoval(of: member)
                        }
                    )

                    if member.id != viewModel.members.last?.id {
                        Divider()
                            .padding(.leading, 70)
                    }
                }
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .cheeseCardChrome(cornerRadius: 16)
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            if viewModel.isOwner {
                settingsButton(title: "群聊名称", icon: "pencil", value: viewModel.groupName) {
                    showRenameSheet = true
                }
                Divider().padding(.leading, 52)
            }

            settingsButton(
                title: "群公告",
                icon: "megaphone.fill",
                value: viewModel.announcement ?? "未设置"
            ) {
                if viewModel.isOwner {
                    showAnnouncementEditor = true
                } else {
                    showAnnouncementDetail = true
                }
            }
            Divider().padding(.leading, 52)

            settingsButton(title: "搜索聊天内容", icon: "magnifyingglass") {
                showHistory = true
            }
            Divider().padding(.leading, 52)

            settingsToggle(
                title: "消息免打扰",
                icon: "bell.slash",
                isOn: Binding(get: { viewModel.isMuted }, set: viewModel.setMuted),
                disabled: viewModel.isSavingMute
            )
            Divider().padding(.leading, 52)

            settingsToggle(
                title: "置顶聊天",
                icon: "pin.fill",
                isOn: Binding(get: { viewModel.isPinned }, set: viewModel.setPinned),
                disabled: viewModel.isSavingPin
            )
            Divider().padding(.leading, 52)

            settingsButton(
                title: "我在群里的昵称",
                icon: "person.text.rectangle",
                value: viewModel.myNickname ?? "未设置"
            ) {
                showNicknameSheet = true
            }
            Divider().padding(.leading, 52)

            settingsButton(title: "清空聊天记录", icon: "trash", destructive: true) {
                viewModel.requestClearHistory()
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .cheeseCardChrome(cornerRadius: 16)
    }

    private func settingsButton(
        title: String,
        icon: String,
        value: String? = nil,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 24)
                Text(title)
                Spacer()
                if let value {
                    Text(value).foregroundStyle(AppColors.textMuted).lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted)
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(destructive ? Color.red : AppColors.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingsToggle(
        title: String,
        icon: String,
        isOn: Binding<Bool>,
        disabled: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24)
            Text(title)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden()
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(AppColors.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .disabled(disabled || viewModel.isLeaving)
    }

    private var leaveButton: some View {
        Button(role: .destructive) {
            viewModel.requestLeave()
        } label: {
            HStack {
                Text(viewModel.isOwner ? "解散群聊" : "退出群聊")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if viewModel.isLeaving {
                    ProgressView()
                        .scaleEffect(0.9)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .cheeseCardChrome(cornerRadius: 16)
        }
        .buttonStyle(CheeseContainerButtonStyle())
        .disabled(viewModel.isLeaving || viewModel.isLoading)
        .padding(.bottom, 74)
    }

    private var groupAvatar: some View {
        Group {
            if let avatar = viewModel.group.avatarURL,
               let url = URL(string: avatar),
               !avatar.isEmpty {
                CachedRemoteImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    avatarFallback
                }
            } else {
                avatarFallback
            }
        }
    }

    private var avatarFallback: some View {
        Circle()
            .fill(AppColors.accent.opacity(0.2))
            .overlay {
                Text(String(viewModel.group.displayName.prefix(1)).uppercased())
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
            }
    }

    private func alert(for destination: GroupChatDetailsAlertDestination) -> Alert {
        switch destination {
        case .leave:
            return Alert(
                title: Text(viewModel.leaveAlertTitle),
                message: Text(viewModel.leaveAlertMessage),
                primaryButton: .cancel(Text("取消")),
                secondaryButton: .destructive(
                    Text(viewModel.isOwner ? "解散" : "退出")
                ) {
                    Task {
                        if await viewModel.leaveGroup() {
                            dismiss()
                            onLeftGroup()
                        }
                    }
                }
            )
        case .clearHistory:
            return Alert(
                title: Text("清空聊天记录？"),
                message: Text("只会清空你自己的群聊记录视图，不会解散群聊，也不会影响其他成员。"),
                primaryButton: .cancel(Text("取消")),
                secondaryButton: .destructive(Text("清空")) {
                    Task {
                        if let clearedAt = await viewModel.clearHistory() {
                            onClearedHistory(clearedAt)
                        }
                    }
                }
            )
        case .removeMember(let member):
            return Alert(
                title: Text("移出该成员？"),
                message: Text("\(member.displayName) 将被移出该群聊。"),
                primaryButton: .cancel(Text("取消")),
                secondaryButton: .destructive(Text("移出")) {
                    Task { await viewModel.removeMember(member) }
                }
            )
        }
    }
}

private struct GroupDetailMemberRow: View {
    let member: ChatGroupMemberSummary
    let canRemove: Bool
    let onOpenProfile: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpenProfile) {
                HStack(spacing: 12) {
                    avatarView
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)

                        Text(member.roleLabel)
                            .font(.system(size: 12))
                            .foregroundStyle(
                                member.role == "owner"
                                    ? AppColors.textPrimary
                                    : AppColors.textMuted
                            )
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.92))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white)
    }

    private var avatarView: some View {
        Group {
            if let avatar = member.avatarURL,
               let url = URL(string: avatar),
               !avatar.isEmpty {
                CachedRemoteImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    avatarFallback
                }
            } else {
                avatarFallback
            }
        }
    }

    private var avatarFallback: some View {
        Circle()
            .fill(AppColors.accent.opacity(0.18))
            .overlay {
                Text(String(member.displayName.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
            }
    }
}

private struct GroupDetailsTextEditorSheet: View {
    let title: String
    let placeholder: String
    let maximumLength: Int
    let allowsEmpty: Bool
    let onSave: (String?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    @State private var isSaving = false

    init(
        title: String,
        placeholder: String,
        initialValue: String,
        maximumLength: Int,
        allowsEmpty: Bool = false,
        onSave: @escaping (String?) async -> Bool
    ) {
        self.title = title
        self.placeholder = placeholder
        self.maximumLength = maximumLength
        self.allowsEmpty = allowsEmpty
        self.onSave = onSave
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextField(placeholder, text: $value)
                    .padding(12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .cheeseInputChrome(cornerRadius: 12)
                    .onChange(of: value) { _, newValue in
                        if newValue.count > maximumLength { value = String(newValue.prefix(maximumLength)) }
                    }
                Text("\(value.count)/\(maximumLength)")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textMuted)
                Spacer()
            }
            .padding(16)
            .background(AppColors.pageBackground.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        Task {
                            isSaving = true
                            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            if await onSave(normalized.isEmpty ? nil : normalized) { dismiss() }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving || (!allowsEmpty && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
    }
}

struct GroupAnnouncementDetailSheet: View {
    let announcement: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                Text(announcement)
                    .font(.system(size: 16))
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .cheeseCardChrome(cornerRadius: 16)
                    .padding(16)
            }
            .background(AppColors.pageBackground.ignoresSafeArea())
            .navigationTitle("群公告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct GroupAnnouncementEditorSheet: View {
    let onSave: (String?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    @State private var isSaving = false

    init(initialValue: String, onSave: @escaping (String?) async -> Bool) {
        _value = State(initialValue: initialValue)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $value)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 180, maxHeight: 260)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .cheeseInputChrome(cornerRadius: 14)
                    .onChange(of: value) { _, newValue in
                        if newValue.count > 1000 { value = String(newValue.prefix(1000)) }
                    }

                HStack {
                    Text("留空保存可移除公告")
                    Spacer()
                    Text("\(value.count)/1000")
                }
                .font(.system(size: 12))
                .foregroundStyle(AppColors.textMuted)

                Spacer()
            }
            .padding(16)
            .background(AppColors.pageBackground.ignoresSafeArea())
            .navigationTitle("编辑群公告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        Task {
                            isSaving = true
                            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            if await onSave(normalized.isEmpty ? nil : normalized) { dismiss() }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }
}

private struct AddGroupMembersSheet: View {
    let existingMemberIDs: Set<UUID>
    let onAdd: ([UUID]) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @StateObject private var chatService = ChatService.shared
    @State private var candidates: [MutualFollowProfile] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if candidates.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 32))
                            .foregroundStyle(AppColors.textMuted)
                        Text("暂无可添加的互关好友")
                    }
                } else {
                    List(candidates) { profile in
                        Button {
                            if selectedIDs.contains(profile.id) { selectedIDs.remove(profile.id) }
                            else { selectedIDs.insert(profile.id) }
                        } label: {
                            HStack {
                                MutualFollowSelectionRow(
                                    profile: profile,
                                    isSelected: selectedIDs.contains(profile.id)
                                )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .background(AppColors.pageBackground.ignoresSafeArea())
            .navigationTitle("添加成员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加") {
                        Task {
                            isSaving = true
                            if await onAdd(Array(selectedIDs)) { dismiss() }
                            isSaving = false
                        }
                    }
                    .disabled(selectedIDs.isEmpty || isSaving)
                }
            }
            .task {
                do {
                    candidates = try await chatService.fetchMutualFollowProfiles(limit: 200)
                        .filter { !existingMemberIDs.contains($0.id) }
                } catch {
                    errorMessage = error.localizedDescription
                }
                isLoading = false
            }
            .alert("无法加载", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}
