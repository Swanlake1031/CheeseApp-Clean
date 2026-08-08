import SwiftUI

struct CreateChatGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @StateObject private var chatService = ChatService.shared

    @State private var groupName = ""
    @State private var candidates: [MutualFollowProfile] = []
    @State private var selectedMemberIDs: Set<UUID> = []
    @State private var isLoading = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    let onCreated: (ChatGroupPreview) -> Void

    private var canCreate: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedMemberIDs.count >= 1 && !isCreating
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
                AppColors.pageBackground
                    .ignoresSafeArea()

                if isLoading {
                    ProgressView()
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("群聊名称")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AppColors.textPrimary)

                            TextField("例如：周末探店局", text: $groupName)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .cheeseInputChrome(cornerRadius: 12)

                            Text("选择成员（至少 1 位互关好友）")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AppColors.textPrimary)

                            if candidates.isEmpty {
                                VStack(spacing: 8) {
                                    Text("暂无可拉群成员")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(AppColors.textPrimary)
                                    Text("先和其他用户互相关注，且双方未互相拉黑。")
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
            .navigationTitle("创建群聊")
            .navigationBarTitleDisplayMode(.inline)
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
            // The mutual-follow RPC reads through profile_public_view, whose
            // visibility policy already excludes either-direction blocks.
            // Avoid issuing one redundant block-relation request per candidate.
            let availableProfiles = try await chatService.fetchMutualFollowProfiles(limit: 200)
            candidates = availableProfiles
            let availableIDs = Set(availableProfiles.map(\.id))
            selectedMemberIDs = selectedMemberIDs.intersection(availableIDs)
            if groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                groupName = defaultGroupName
            }
            errorMessage = nil
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
