import SwiftUI

struct CourseRatingSummaryView: View {
    let aggregate: CourseRatingAggregate
    let isLoading: Bool

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                metric(
                    label: L10n.tr("Fun", "好玩"),
                    value: aggregate.funRating
                )
                metric(
                    label: L10n.tr("Useful", "有用"),
                    value: aggregate.usefulRating
                )
                metric(
                    label: L10n.tr("Easy A", "好拿分"),
                    value: aggregate.easyARating
                )
                metric(
                    label: L10n.tr("Professor", "教授评分"),
                    value: aggregate.professorRating
                )
            }
        }
    }

    private func metric(label: String, value: Double?) -> some View {
        metric(
            label: label,
            text: value.map {
                "\($0.formatted(.number.precision(.fractionLength(1))))/5"
            } ?? "—/5"
        )
    }

    private func metric(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CourseReviewSection: View {
    @ObservedObject var state: CourseReviewViewModel
    let onEditOwnReview: () -> Void
    @State private var showingReviewActions = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("Student reviews", "学生评价"))
                .font(.system(size: 18, weight: .bold))

            switch state.loadState {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            case let .failed(message):
                loadFailure(message: message)
            case .loaded:
                reviewsContent
            }
        }
        .confirmationDialog(
            L10n.tr("Review actions", "评价操作"),
            isPresented: $showingReviewActions,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Edit review", "编辑评价")) {
                onEditOwnReview()
            }

            Button(L10n.tr("Delete review", "删除评价"), role: .destructive) {
                showDeleteConfirmation = true
            }
        }
        .alert(
            L10n.tr("Delete your review?", "删除你的评价？"),
            isPresented: $showDeleteConfirmation
        ) {
            Button(L10n.tr("Cancel", "取消"), role: .cancel) {}
            Button(L10n.tr("Delete review", "删除评价"), role: .destructive) {
                Task { await state.deleteOwnReview() }
            }
        }
    }

    private func loadFailure(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                L10n.tr("Unable to load reviews", "课程评价加载失败"),
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 15, weight: .semibold))

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Button(L10n.tr("Reload", "重新加载")) {
                Task { await state.load() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .cheeseCardChrome(cornerRadius: 8)
    }

    @ViewBuilder
    private var reviewsContent: some View {
        if state.visibleReviews.isEmpty {
            Text(
                state.snapshot.reviews.isEmpty
                    ? L10n.tr("No student reviews yet.", "暂时还没有学生评价。")
                    : L10n.tr(
                        "No reviews for this professor yet.",
                        "这位教授暂时还没有评价。"
                    )
            )
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color(uiColor: .systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .cheeseCardChrome(cornerRadius: 8)
        } else {
            ForEach(state.visibleReviews) { review in
                reviewCard(review)
            }
        }
    }

    private func reviewCard(_ review: CourseReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(L10n.tr("Professor", "教授"))：\(review.professorName)")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)

                Spacer()

                if review.isMine {
                    HStack(spacing: 8) {
                        Text(L10n.tr("Your review", "你的评价"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppColors.accent)
                            .clipShape(Capsule())

                        Button {
                            showingReviewActions = true
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .accessibilityLabel(L10n.tr("Review actions", "评价操作"))
                    }
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ],
                alignment: .leading,
                spacing: 10
            ) {
                reviewMetric(
                    label: L10n.tr("Overall", "总评分"),
                    value: review.overallRating
                )
                reviewMetric(
                    label: L10n.tr("Fun", "好玩"),
                    value: review.funRating
                )
                reviewMetric(
                    label: L10n.tr("Useful", "有用"),
                    value: review.usefulRating
                )
                reviewMetric(
                    label: L10n.tr("Easy A", "好拿分"),
                    value: review.easyARating
                )
                reviewMetric(
                    label: L10n.tr("Professor", "教授"),
                    value: review.professorRating
                )
            }

            if let reviewText = review.reviewText {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("Short review", "文字短评"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(reviewText)
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Text(review.termTitle)
                Spacer()
                Text(review.updatedAt.formatted(date: .abbreviated, time: .omitted))
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .cheeseCardChrome(cornerRadius: 8)
    }

    private func reviewMetric(label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)/5")
                .font(.system(size: 14, weight: .bold))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

struct CourseReviewEditorSheet: View {
    @ObservedObject var state: CourseReviewViewModel
    let onDismiss: () -> Void

    @State private var showDeleteConfirmation = false
    @State private var showingAcademicTermPicker = false
    @State private var showingProfessorPicker = false
    @FocusState private var isReviewTextFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                reviewForm
                    .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(CoursePageBackground())
            .navigationTitle(
                state.snapshot.ownReview == nil
                    ? L10n.tr("Review this course", "添加课程评价")
                    : L10n.tr("Edit your review", "修改课程评价")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isReviewTextFocused = false
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.tr("Close", "关闭"))
                }
            }
        }
        .confirmationDialog(
            L10n.tr("Delete your review?", "删除你的评价？"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Delete review", "删除评价"), role: .destructive) {
                Task {
                    await state.deleteOwnReview()
                    if state.snapshot.ownReview == nil {
                        onDismiss()
                    }
                }
            }
        }
    }

    private var reviewForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            academicTermPicker
            professorPicker

            StarRatingInput(
                title: L10n.tr("Overall", "总评分"),
                explanation: L10n.tr("1 Poor · 5 Excellent", "1 很差 · 5 很好"),
                value: $state.draft.overallRating
            )

            StarRatingInput(
                title: L10n.tr("Fun", "好玩"),
                explanation: L10n.tr("1 Not fun · 5 Very fun", "1 不好玩 · 5 很好玩"),
                value: $state.draft.funRating
            )

            StarRatingInput(
                title: L10n.tr("Useful", "有用"),
                explanation: L10n.tr("1 Not useful · 5 Very useful", "1 没用 · 5 很有用"),
                value: $state.draft.usefulRating
            )

            StarRatingInput(
                title: L10n.tr("Easy A", "好拿分"),
                explanation: L10n.tr("1 Very hard · 5 Easy A", "1 很难拿高分 · 5 很好拿高分"),
                value: $state.draft.easyARating
            )

            StarRatingInput(
                title: L10n.tr("Professor rating", "教授评分"),
                explanation: L10n.tr("1 Poor · 5 Excellent", "1 很差 · 5 很好"),
                value: $state.draft.professorRating
            )

            reviewTextEditor

            if let errorMessage = state.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(errorMessage)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if state.snapshot.professors.isEmpty
                        || state.snapshot.academicTerms.isEmpty {
                        Button(L10n.tr("Retry", "重试")) {
                            Task { await state.load() }
                        }
                        .fontWeight(.semibold)
                    } else {
                        Button {
                            state.clearError()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(L10n.tr("Dismiss error", "关闭错误提示"))
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button {
                    isReviewTextFocused = false
                    HapticEngine.impact(.light)
                    Task {
                        if await state.submit() {
                            HapticEngine.impact(.medium)
                            onDismiss()
                        }
                    }
                } label: {
                    HStack {
                        if state.isSubmitting {
                            ProgressView()
                                .tint(.black)
                        }
                        Text(
                            state.isSubmitting
                                ? L10n.tr("Submitting...", "提交中...")
                                : state.snapshot.ownReview == nil
                                    ? L10n.tr("Submit review", "提交评价")
                                    : L10n.tr("Update review", "更新评价")
                        )
                        .font(.system(size: 15, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CourseActionButtonStyle())
                .foregroundStyle(.black)
                .background(
                    state.canSubmit
                        ? AppColors.accent
                        : Color.secondary.opacity(0.2)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(!state.canSubmit)

                if state.snapshot.ownReview != nil {
                    Button(role: .destructive) {
                        isReviewTextFocused = false
                        showDeleteConfirmation = true
                    } label: {
                        Label(
                            L10n.tr("Delete review", "删除评价"),
                            systemImage: "trash"
                        )
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CourseActionButtonStyle())
                    .foregroundStyle(.red)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .disabled(state.isSubmitting)
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .disabled(state.isSubmitting)
    }

    private var academicTermPicker: some View {
        Button {
            isReviewTextFocused = false
            showingAcademicTermPicker = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("Year and term", "年份与学期"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(selectedDraftAcademicTermTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(13)
            .frame(minHeight: 52)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.snapshot.academicTerms.isEmpty || state.isSubmitting)
        .confirmationDialog(
            L10n.tr("Select year and term", "选择年份与学期"),
            isPresented: $showingAcademicTermPicker,
            titleVisibility: .visible
        ) {
            ForEach(state.snapshot.academicTerms) { academicTerm in
                Button(academicTerm.title) {
                    state.draft.academicTermID = academicTerm.id
                }
            }
        }
    }

    private var professorPicker: some View {
        Button {
            isReviewTextFocused = false
            showingProfessorPicker = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("Professor", "选择教授"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(selectedDraftProfessorName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(13)
            .frame(minHeight: 52)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.snapshot.professors.isEmpty || state.isSubmitting)
        .confirmationDialog(
            L10n.tr("Select professor", "选择教授"),
            isPresented: $showingProfessorPicker,
            titleVisibility: .visible
        ) {
            ForEach(state.snapshot.professors) { professor in
                Button(professor.name) {
                    state.draft.professorID = professor.id
                }
            }
        }
    }

    private var reviewTextEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("Short review (optional)", "文字短评（选填）"))
                .font(.system(size: 14, weight: .semibold))

            TextEditor(text: $state.draft.reviewText)
                .font(.system(size: 14))
                .frame(minHeight: 110)
                .focused($isReviewTextFocused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onChange(of: state.draft.reviewText) { _, newValue in
                    if newValue.count > CourseReviewDraft.maximumTextLength {
                        state.draft.reviewText = String(
                            newValue.prefix(CourseReviewDraft.maximumTextLength)
                        )
                    }
                }

            Text("\(state.draft.remainingTextCount)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var selectedDraftProfessorName: String {
        guard let professorID = state.draft.professorID,
              let professor = state.snapshot.professors.first(where: {
                  $0.id == professorID
              }) else {
            return L10n.tr("Required", "必填")
        }
        return professor.name
    }

    private var selectedDraftAcademicTermTitle: String {
        guard let academicTermID = state.draft.academicTermID,
              let academicTerm = state.snapshot.academicTerms.first(where: {
                  $0.id == academicTermID
              }) else {
            return L10n.tr("Required", "必填")
        }
        return academicTerm.title
    }

}

struct CourseActionButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.98

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct StarRatingInput: View {
    let title: String
    let explanation: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { rating in
                    Button {
                        value = rating
                    } label: {
                        Image(systemName: rating <= value ? "star.fill" : "star")
                            .font(.system(size: 24))
                            .foregroundStyle(
                                rating <= value ? AppColors.accentStrong : .secondary
                            )
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(rating)")
                }
            }

            Text(explanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
