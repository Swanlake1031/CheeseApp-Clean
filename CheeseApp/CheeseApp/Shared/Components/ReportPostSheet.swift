import SwiftUI

struct ReportPostSheet: View {
    let postId: UUID
    let postKind: PostKind

    var body: some View {
        ReportFormSheet(
            heading: L10n.tr(
                "Report \(postKind.displayName) Post",
                "举报\(postKind.displayName)帖子"
            ),
            submit: { reason, details in
                try await CommunityService.shared.submitPostReport(
                    postId: postId,
                    reason: reason,
                    details: details
                )
            }
        )
    }
}

struct ReportMessageSheet: View {
    let target: ChatMessageReportTarget

    var body: some View {
        ReportFormSheet(
            heading: L10n.tr("Report Message", "举报消息"),
            submit: { reason, details in
                try await CommunityService.shared.submitMessageReport(
                    target: target,
                    reason: reason,
                    details: details
                )
            }
        )
    }
}

private struct ReportFormSheet: View {
    let heading: String
    let submit: (ReportReason, String?) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var reason: ReportReason = .inappropriate
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var isDetailsFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.pageBackground
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(heading)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(AppColors.textPrimary)

                        Text(L10n.tr(
                            "Help us keep the community safe. Reports are reviewed by moderation.",
                            "帮助我们维护社区安全，举报内容将由审核团队处理。"
                        ))
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.textMuted)

                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.tr("Reason", "原因"))
                                .font(.system(size: 14, weight: .semibold))

                            ForEach(ReportReason.allCases) { option in
                                Button {
                                    reason = option
                                } label: {
                                    HStack {
                                        Text(option.title)
                                            .font(.system(size: 14))
                                            .foregroundStyle(AppColors.textPrimary)
                                        Spacer()
                                        Image(systemName: reason == option ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(reason == option ? AppColors.link : AppColors.textMuted)
                                    }
                                    .padding(12)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.tr("Details (optional)", "补充说明（选填）"))
                                .font(.system(size: 14, weight: .semibold))

                            TextEditor(text: $details)
                                .frame(minHeight: 120)
                                .padding(8)
                                .focused($isDetailsFocused)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.black.opacity(0.72), lineWidth: 1)
                                }
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                        }

                        Button {
                            Task { await submitReport() }
                        } label: {
                            HStack {
                                if isSubmitting {
                                    ProgressView()
                                        .tint(.black)
                                }
                                Text(L10n.tr("Submit Report", "提交举报"))
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(AppColors.accent)
                            .foregroundStyle(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(isSubmitting)

                        Spacer(minLength: 24)
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isDetailsFocused = false
                        }
                }
            }
            .navigationTitle(L10n.tr("Report", "举报"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.tr("Cancel", "取消")) {
                        dismiss()
                    }
                    .foregroundStyle(AppColors.textPrimary)
                }
            }
        }
    }

    private func submitReport() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await submit(reason, details)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
