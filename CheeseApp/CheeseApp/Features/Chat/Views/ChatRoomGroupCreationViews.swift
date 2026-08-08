import SwiftUI

struct ChatRoomCreateGroupSheet: View {
    let baseConversation: ChatConversationPreview
    let onCreated: (ChatGroupPreview) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @StateObject private var chatService = ChatService.shared

    @State private var groupName = ""
    @State private var candidates: [MutualFollowProfile] = []
    @State private var selectedMemberIDs: Set<UUID> = []
    @State private var isLoading = false
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var hintMessage: String?

    private var canCreate: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && selectedMemberIDs.count >= 2
        && !isCreating
    }

    private var defaultGroupName: String {
        let myName = authService.currentUser?.fullName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !myName.isEmpty {
            return "\(myName)的群组"
        }
        return "我的群组"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.pageBackground.ignoresSafeArea()

                if isLoading {
                    ProgressView()
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("群组名称")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AppColors.textPrimary)

                            TextField("例如：本周探店小队", text: $groupName)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .cheeseInputChrome(cornerRadius: 12)

                            HStack {
                                Text("选择成员（至少 2 位互关好友）")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AppColors.textPrimary)
                                Spacer()
                                Text("\(selectedMemberIDs.count)/2")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AppColors.textMuted)
                            }

                            if let hintMessage, !hintMessage.isEmpty {
                                Text(hintMessage)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AppColors.textMuted)
                            }

                            if candidates.isEmpty {
                                VStack(spacing: 8) {
                                    Text("暂无可邀请成员")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(AppColors.textPrimary)
                                    Text("先互相关注，再建立群组。")
                                        .font(.system(size: 12))
                                        .foregroundStyle(AppColors.textMuted)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 26)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .cheeseCardChrome(cornerRadius: 14)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(candidates) { profile in
                                        Button {
                                            toggleSelection(profile.id)
                                        } label: {
                                            MutualFollowSelectionRow(
                                                profile: profile,
                                                isSelected: selectedMemberIDs.contains(profile.id)
                                            )
                                        }
                                        .buttonStyle(.plain)

                                        if profile.id != candidates.last?.id {
                                            Divider()
                                                .padding(.leading, 68)
                                        }
                                    }
                                }
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .cheeseCardChrome(cornerRadius: 14)
                            }

                            if let errorMessage, !errorMessage.isEmpty {
                                Text(errorMessage)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 22)
                    }
                }
            }
            .navigationTitle("建立群组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(AppColors.pageBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await createGroup() }
                    } label: {
                        if isCreating {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Text("创建")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!canCreate)
                }
            }
            .tint(AppColors.textPrimary)
        }
        .task {
            await loadCandidates()
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedMemberIDs.contains(id) {
            selectedMemberIDs.remove(id)
        } else {
            selectedMemberIDs.insert(id)
        }
    }

    private func loadCandidates() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let loaded = try await chatService.fetchMutualFollowProfiles(limit: 200)
            candidates = loaded
            errorMessage = nil

            if groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                groupName = defaultGroupName
            }

            let otherUserId = baseConversation.otherUserId
            if loaded.contains(where: { $0.id == otherUserId }) {
                selectedMemberIDs.insert(otherUserId)
                hintMessage = "已默认选中当前聊天对象，可再选择至少 1 位互关好友。"
            } else {
                hintMessage = "当前聊天对象不是互关好友，无法直接拉入群。"
            }
        } catch {
            candidates = []
            errorMessage = error.localizedDescription
        }
    }

    private func createGroup() async {
        guard canCreate else { return }
        isCreating = true
        defer { isCreating = false }

        do {
            let group = try await chatService.createChatGroup(
                name: groupName,
                memberIds: Array(selectedMemberIDs)
            )
            onCreated(group)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
