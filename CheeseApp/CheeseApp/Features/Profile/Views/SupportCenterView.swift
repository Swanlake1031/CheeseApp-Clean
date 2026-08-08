import SwiftUI

struct SupportCenterView: View {
    var body: some View {
        List {
            Section(L10n.tr("Support", "支援")) {
                NavigationLink {
                    FeedbackFormView()
                } label: {
                    Label(L10n.tr("Send Feedback", "提交回馈"), systemImage: "bubble.left.and.exclamationmark.bubble.right.fill")
                }

                Link(destination: URL(string: "mailto:support@cheeseapp.dev")!) {
                    Label(L10n.tr("Email Support", "Email 客服"), systemImage: "envelope.fill")
                }
            }

            Section(L10n.tr("Notes", "说明")) {
                Text(L10n.tr("For urgent safety issues, use the Report button on posts.", "若有紧急安全问题，请在贴文使用检举功能。"))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.pageBackground)
        .cheesePageTopBar(title: L10n.tr("Help & Support", "帮助与支援"))
        .tint(AppColors.textPrimary)
    }
}

struct FeedbackFormView: View {
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var category: FeedbackCategory = .other
    @State private var message = ""
    @State private var contactEmail = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.tr("Tell us what we should improve.", "告诉我们你希望改进的地方。"))
                        .font(.system(size: 15))
                        .foregroundStyle(AppColors.textMuted)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("Category", "分类"))
                            .font(.system(size: 14, weight: .semibold))
                        Picker(L10n.tr("Category", "分类"), selection: $category) {
                            ForEach(FeedbackCategory.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("Message", "内容"))
                            .font(.system(size: 14, weight: .semibold))
                        TextEditor(text: $message)
                            .frame(minHeight: 160)
                            .padding(8)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("Contact Email (optional)", "联络 Email（选填）"))
                            .font(.system(size: 14, weight: .semibold))
                        TextField(L10n.tr("you@example.com", "you@example.com"), text: $contactEmail)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .padding(12)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            if isSubmitting {
                                ProgressView()
                                    .tint(.black)
                            }
                            Text(L10n.tr("Submit Feedback", "送出回馈"))
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppColors.accent)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(isSubmitting || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer(minLength: 24)
                }
                .padding(16)
            }
        }
        .cheesePageTopBar(title: L10n.tr("Feedback", "回馈"))
        .tint(AppColors.textPrimary)
        .onAppear {
            if contactEmail.isEmpty {
                contactEmail = authService.currentUser?.email ?? ""
            }
        }
    }

    private func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await CommunityService.shared.submitFeedback(
                category: category,
                message: message,
                contactEmail: contactEmail
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
