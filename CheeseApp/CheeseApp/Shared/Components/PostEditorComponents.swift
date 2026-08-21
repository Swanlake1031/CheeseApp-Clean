import SwiftUI
import UIKit

/// Keeps one horizontal drag owned by the nearest inner scroll view for its
/// entire lifetime, including edge bounce and deceleration. This prevents a
/// nested strip from handing residual velocity to an outer paging scroll view.
struct HorizontalScrollGestureFence: UIViewRepresentable {
    func makeUIView(context: Context) -> HorizontalScrollGestureFenceView {
        let view = HorizontalScrollGestureFenceView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: HorizontalScrollGestureFenceView, context: Context) {
        uiView.scheduleInstallation()
    }
}

final class HorizontalScrollGestureFenceView: UIView {
    private weak var configuredInnerScrollView: UIScrollView?
    private weak var configuredOuterScrollView: UIScrollView?
    private var lockedOuterContentOffset: CGPoint?
    private var outerScrollWasEnabled = true
    private var earliestUnlockTime: CFTimeInterval = 0
    private var lockDisplayLink: CADisplayLink?
    private var installationScheduled = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            removeGestureFence()
            return
        }
        scheduleInstallation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard configuredInnerScrollView == nil
                || configuredOuterScrollView == nil
        else {
            return
        }
        scheduleInstallation()
    }

    func scheduleInstallation() {
        guard !installationScheduled else { return }
        installationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.installationScheduled = false
            self.installGestureFenceIfNeeded()
        }
    }

    private func installGestureFenceIfNeeded() {
        guard let innerScrollView = nearestAncestorScrollView(from: superview),
              let outerScrollView = nearestHorizontalScrollView(
                from: innerScrollView.superview
              )
        else {
            return
        }

        guard configuredInnerScrollView !== innerScrollView
                || configuredOuterScrollView !== outerScrollView
        else {
            return
        }

        removeGestureFence()
        innerScrollView.panGestureRecognizer.addTarget(
            self,
            action: #selector(handleInnerScrollPan(_:))
        )
        configuredInnerScrollView = innerScrollView
        configuredOuterScrollView = outerScrollView
    }

    @objc private func handleInnerScrollPan(_ gesture: UIPanGestureRecognizer) {
        guard let outerScrollView = configuredOuterScrollView else { return }

        switch gesture.state {
        case .began, .changed:
            lockOuterScrollView(outerScrollView)
        case .ended, .cancelled, .failed:
            earliestUnlockTime = CACurrentMediaTime() + 0.12
            startLockDisplayLinkIfNeeded()
        default:
            break
        }
    }

    private func lockOuterScrollView(_ scrollView: UIScrollView) {
        if lockedOuterContentOffset == nil {
            lockedOuterContentOffset = settledContentOffset(for: scrollView)
            outerScrollWasEnabled = scrollView.isScrollEnabled
        }

        scrollView.layer.removeAllAnimations()
        scrollView.isScrollEnabled = false
        enforceLockedOuterOffset()
        startLockDisplayLinkIfNeeded()
    }

    private func startLockDisplayLinkIfNeeded() {
        guard lockDisplayLink == nil else { return }
        let displayLink = CADisplayLink(
            target: self,
            selector: #selector(handleLockDisplayLink)
        )
        displayLink.add(to: .main, forMode: .common)
        lockDisplayLink = displayLink
    }

    @objc private func handleLockDisplayLink() {
        enforceLockedOuterOffset()

        guard CACurrentMediaTime() >= earliestUnlockTime,
              let innerScrollView = configuredInnerScrollView,
              !innerScrollView.isDragging,
              !innerScrollView.isDecelerating,
              innerScrollView.panGestureRecognizer.state == .possible
        else {
            return
        }

        unlockOuterScrollView()
    }

    private func enforceLockedOuterOffset() {
        guard let outerScrollView = configuredOuterScrollView,
              let lockedOuterContentOffset
        else {
            return
        }

        outerScrollView.layer.removeAllAnimations()
        if outerScrollView.contentOffset != lockedOuterContentOffset {
            outerScrollView.setContentOffset(lockedOuterContentOffset, animated: false)
        }
    }

    private func settledContentOffset(for scrollView: UIScrollView) -> CGPoint {
        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return scrollView.contentOffset }

        let leadingInset = scrollView.adjustedContentInset.left
        let pageIndex = round((scrollView.contentOffset.x + leadingInset) / pageWidth)
        return CGPoint(
            x: pageIndex * pageWidth - leadingInset,
            y: scrollView.contentOffset.y
        )
    }

    private func unlockOuterScrollView() {
        lockDisplayLink?.invalidate()
        lockDisplayLink = nil
        enforceLockedOuterOffset()
        configuredOuterScrollView?.isScrollEnabled = outerScrollWasEnabled
        configuredOuterScrollView?.panGestureRecognizer.isEnabled = outerScrollWasEnabled
        lockedOuterContentOffset = nil
        earliestUnlockTime = 0
    }

    private func removeGestureFence() {
        configuredInnerScrollView?.panGestureRecognizer.removeTarget(
            self,
            action: #selector(handleInnerScrollPan(_:))
        )
        unlockOuterScrollView()
        configuredInnerScrollView = nil
        configuredOuterScrollView = nil
    }

    private func nearestAncestorScrollView(from view: UIView?) -> UIScrollView? {
        var currentView = view
        while let view = currentView {
            if let scrollView = view as? UIScrollView {
                return scrollView
            }
            currentView = view.superview
        }
        return nil
    }

    private func nearestHorizontalScrollView(from view: UIView?) -> UIScrollView? {
        var currentView = view
        while let view = currentView {
            if let scrollView = view as? UIScrollView,
               scrollView.alwaysBounceHorizontal
                    || scrollView.contentSize.width > scrollView.bounds.width + 1 {
                return scrollView
            }
            currentView = view.superview
        }
        return nil
    }
}

struct ExpandableCategoryPicker<Option: Hashable>: View {
    @Binding var selection: Option?

    let options: [Option]
    let recommendedTitle: String
    let accessibilityTitle: String
    let title: (Option) -> String
    let icon: (Option) -> String

    @State private var isExpanded = false
    @State private var isShowingExpandedPanel = false

    private let gridColumns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 3
    )

    private var expandedPanelHeight: CGFloat {
        let itemCount = options.count + 1
        let rowCount = max((itemCount + 2) / 3, 1)
        let gridHeight = CGFloat(rowCount * 40 + max(rowCount - 1, 0) * 8)
        return 24 + 36 + 12 + gridHeight
    }

    var body: some View {
        VStack(spacing: 10) {
            if isShowingExpandedPanel {
                ZStack(alignment: .top) {
                    expandedPanel
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(
                            height: isExpanded ? expandedPanelHeight : 0,
                            alignment: .top
                        )
                        .clipped()
                }
                .frame(
                    height: isExpanded ? expandedPanelHeight : 42,
                    alignment: .top
                )
                .clipped()
            } else {
                collapsedBar
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
    }

    private var collapsedBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    categoryButton(
                        title: recommendedTitle,
                        icon: "sparkles",
                        option: nil
                    )

                    ForEach(options, id: \.self) { option in
                        categoryButton(
                            title: title(option),
                            icon: icon(option),
                            option: option
                        )
                    }
                }
                .padding(.vertical, 2)
                .background(HorizontalScrollGestureFence())
            }
            .contentMargins(.horizontal, 1, for: .scrollContent)
            .scrollBounceBehavior(.always, axes: .horizontal)

            expansionButton(isExpanded: false)
        }
    }

    private var expandedPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(L10n.tr("All categories", "全部分类"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)

                Text(L10n.tr("Tap to choose", "点击选择分类"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppColors.textMuted)

                Spacer()

                expansionButton(isExpanded: true)
            }

            LazyVGrid(columns: gridColumns, spacing: 8) {
                compactCategoryButton(
                    title: recommendedTitle,
                    option: nil
                )

                ForEach(options, id: \.self) { option in
                    compactCategoryButton(
                        title: title(option),
                        option: option
                    )
                }
            }
        }
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .cheeseCardChrome(cornerRadius: 14)
    }

    private func expansionButton(isExpanded: Bool) -> some View {
        Button {
            setExpanded(!isExpanded)
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isExpanded
                ? L10n.tr("Collapse categories", "收起分类")
                : L10n.tr("Expand categories", "展开分类")
        )
    }

    private func categoryButton(
        title: String,
        icon: String,
        option: Option?
    ) -> some View {
        let isSelected = selection == option
        return Button {
            // Category filtering replaces the feed below this control. Do not
            // pass an animation transaction to every card: media deliberately
            // opts out of animations, which otherwise makes images move ahead
            // of their text content during a filter change.
            selection = option
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.black : AppColors.textMuted)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(isSelected ? AppColors.accent : Color.white)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.black.opacity(isSelected ? 0.04 : 0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func compactCategoryButton(
        title: String,
        option: Option?
    ) -> some View {
        let isSelected = selection == option
        return Button {
            selection = option
            setExpanded(false)
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.black : AppColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(isSelected ? AppColors.accent : AppColors.pageBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func setExpanded(_ expanded: Bool) {
        // Expand and collapse in a single layout pass so the feed below moves
        // as one unit instead of allowing media and text to settle separately.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isShowingExpandedPanel = expanded
            isExpanded = expanded
        }
    }
}

struct PostFormSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
    }
}

struct PostFormTextField: View {
    let icon: String
    let iconColor: Color
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .frame(width: 24)
            CheeseSystemTextField(
                text: $text,
                placeholder: placeholder,
                keyboardType: keyboardType
            )
            .frame(height: 24)
        }
        .padding()
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .cheeseInputChrome(cornerRadius: 12)
    }
}

struct PostInlineLoadingStatus: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PostInlineHighlightStatus: View {
    let message: String
    let color: Color

    init(message: String, color: Color = .secondary) {
        self.message = message
        self.color = color
    }

    var body: some View {
        Text(message)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum PostCurrencyPriceFieldEmphasis {
    case primary
    case secondary
}

private struct PostCurrencyPriceFieldChrome: ViewModifier {
    let emphasis: PostCurrencyPriceFieldEmphasis

    @ViewBuilder
    func body(content: Content) -> some View {
        switch emphasis {
        case .primary:
            content.cheeseInputChrome(cornerRadius: 12)
        case .secondary:
            content.overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 0.7)
            }
        }
    }
}

struct PostCurrencyPriceField: View {
    let label: String
    let placeholder: String
    let iconColor: Color
    let emphasis: PostCurrencyPriceFieldEmphasis
    @Binding var text: String

    init(
        label: String,
        placeholder: String,
        iconColor: Color = .secondary,
        emphasis: PostCurrencyPriceFieldEmphasis = .primary,
        text: Binding<String>
    ) {
        self.label = label
        self.placeholder = placeholder
        self.iconColor = iconColor
        self.emphasis = emphasis
        self._text = text
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline.weight(emphasis == .primary ? .semibold : .medium))
                .foregroundColor(emphasis == .primary ? iconColor : AppColors.textMuted)
                .frame(width: 36, alignment: .leading)
            Text("CAD")
                .font(.subheadline.weight(emphasis == .primary ? .semibold : .regular))
                .foregroundColor(.secondary.opacity(emphasis == .primary ? 1 : 0.72))
            CheeseSystemTextField(
                text: $text,
                placeholder: placeholder,
                keyboardType: .decimalPad
            )
            .frame(height: 24)
        }
        .padding()
        .background(
            emphasis == .primary
                ? Color.white
                : Color(uiColor: .secondarySystemBackground).opacity(0.72)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .modifier(PostCurrencyPriceFieldChrome(emphasis: emphasis))
    }
}

struct PostChipButton: View {
    let title: String
    let isSelected: Bool
    let selectedColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(isSelected ? selectedColor : Color.white)
                .foregroundColor(isSelected ? .white : .primary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(
                            isSelected ? selectedColor : Color(.systemGray5),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

struct PostImageSection: View {
    @Binding var selectedImages: [UIImage]
    let existingImageCount: Int

    init(
        selectedImages: Binding<[UIImage]>,
        existingImageCount: Int = 0
    ) {
        self._selectedImages = selectedImages
        self.existingImageCount = existingImageCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ImagePicker(
                selectedImages: $selectedImages,
                maxCount: 6,
                existingImageCount: existingImageCount
            )

            if !selectedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(selectedImages.enumerated()), id: \.offset) { _, image in
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 78, height: 78)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .cheeseInputChrome(cornerRadius: 12)
    }
}

struct PostTextEditorCard: View {
    @Binding var text: String
    let placeholder: String?
    let minHeight: CGFloat
    let font: Font
    let isFirstResponder: Binding<Bool>?

    init(
        text: Binding<String>,
        placeholder: String? = nil,
        minHeight: CGFloat = 100,
        font: Font = .system(size: 17),
        isFirstResponder: Binding<Bool>? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
        self.font = font
        self.isFirstResponder = isFirstResponder
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CheeseSystemTextEditor(
                text: $text,
                fontSize: 17,
                isFirstResponder: isFirstResponder
            )
                .frame(minHeight: minHeight)
                .padding(12)

            if let placeholder,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundColor(.gray.opacity(0.5))
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .cheeseInputChrome(cornerRadius: 12)
    }
}

struct PostCounterCard: View {
    let title: String
    @Binding var value: Int
    let icon: String
    let minimum: Int
    let accentColor: Color

    init(
        title: String,
        value: Binding<Int>,
        icon: String,
        minimum: Int = 0,
        accentColor: Color
    ) {
        self.title = title
        self._value = value
        self.icon = icon
        self.minimum = minimum
        self.accentColor = accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.secondary)
                Text(title)
                    .foregroundColor(.secondary)
            }
            .font(.subheadline)

            HStack {
                Button {
                    if value > minimum {
                        value -= 1
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .foregroundColor(value > minimum ? accentColor : .gray)
                }

                Text("\(value)")
                    .font(.title3.weight(.semibold))
                    .frame(width: 40)

                Button {
                    value += 1
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(accentColor)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .cheeseCardChrome(cornerRadius: 14)
    }
}

struct PostDecimalCounterCard: View {
    let title: String
    @Binding var value: Double
    let icon: String
    let minimum: Double
    let step: Double
    let decimals: Int
    let accentColor: Color

    init(
        title: String,
        value: Binding<Double>,
        icon: String,
        minimum: Double = 0,
        step: Double = 0.5,
        decimals: Int = 1,
        accentColor: Color
    ) {
        self.title = title
        self._value = value
        self.icon = icon
        self.minimum = minimum
        self.step = step
        self.decimals = decimals
        self.accentColor = accentColor
    }

    private var formattedValue: String {
        String(format: "%.\(decimals)f", value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.secondary)
                Text(title)
                    .foregroundColor(.secondary)
            }
            .font(.subheadline)

            HStack {
                Button {
                    value = max(value - step, minimum)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .foregroundColor(value > minimum ? accentColor : .gray)
                }

                Text(formattedValue)
                    .font(.title3.weight(.semibold))
                    .frame(width: 44)

                Button {
                    value += step
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(accentColor)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .cheeseCardChrome(cornerRadius: 14)
    }
}

struct PostDateFieldCard: View {
    let icon: String
    let title: String
    let iconColor: Color
    @Binding var date: Date
    let displayedComponents: DatePickerComponents
    let minimumDate: Date?

    init(
        icon: String,
        title: String,
        iconColor: Color = .secondary,
        date: Binding<Date>,
        displayedComponents: DatePickerComponents = .date,
        minimumDate: Date? = nil
    ) {
        self.icon = icon
        self.title = title
        self.iconColor = iconColor
        self._date = date
        self.displayedComponents = displayedComponents
        self.minimumDate = minimumDate
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(iconColor)
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            if let minimumDate {
                DatePicker(
                    "",
                    selection: $date,
                    in: minimumDate...,
                    displayedComponents: displayedComponents
                )
                .labelsHidden()
            } else {
                DatePicker(
                    "",
                    selection: $date,
                    displayedComponents: displayedComponents
                )
                .labelsHidden()
            }
        }
        .padding()
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .cheeseInputChrome(cornerRadius: 14)
    }
}

struct PostTokenEditorSection: View {
    let title: String
    let items: [String]
    @Binding var newItem: String
    let itemPrefix: String
    let placeholder: String
    let addButtonColor: Color
    let selectedBackgroundColor: Color
    let selectedForegroundColor: Color
    let suggestionsTitle: String?
    let suggestions: [String]
    let onAddDraft: () -> Void
    let onSelectSuggestion: ((String) -> Void)?
    let onRemoveItem: (Int) -> Void

    init(
        title: String,
        items: [String],
        newItem: Binding<String>,
        itemPrefix: String = "",
        placeholder: String,
        addButtonColor: Color,
        selectedBackgroundColor: Color,
        selectedForegroundColor: Color,
        suggestionsTitle: String? = nil,
        suggestions: [String] = [],
        onAddDraft: @escaping () -> Void,
        onSelectSuggestion: ((String) -> Void)? = nil,
        onRemoveItem: @escaping (Int) -> Void
    ) {
        self.title = title
        self.items = items
        self._newItem = newItem
        self.itemPrefix = itemPrefix
        self.placeholder = placeholder
        self.addButtonColor = addButtonColor
        self.selectedBackgroundColor = selectedBackgroundColor
        self.selectedForegroundColor = selectedForegroundColor
        self.suggestionsTitle = suggestionsTitle
        self.suggestions = suggestions
        self.onAddDraft = onAddDraft
        self.onSelectSuggestion = onSelectSuggestion
        self.onRemoveItem = onRemoveItem
    }

    private var availableSuggestions: [String] {
        suggestions.filter { !items.contains($0) }
    }

    var body: some View {
        PostFormSection(title: title) {
            VStack(alignment: .leading, spacing: 12) {
                if !items.isEmpty {
                    PostFlowLayout(spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(spacing: 4) {
                                Text("\(itemPrefix)\(item)")
                                Button {
                                    onRemoveItem(index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                }
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedBackgroundColor)
                            .foregroundColor(selectedForegroundColor)
                            .clipShape(Capsule())
                        }
                    }
                }

                if let suggestionsTitle, !availableSuggestions.isEmpty {
                    Text(suggestionsTitle)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    PostFlowLayout(spacing: 8) {
                        ForEach(Array(availableSuggestions.enumerated()), id: \.offset) { _, item in
                            Button {
                                onSelectSuggestion?(item)
                            } label: {
                                Text("\(itemPrefix)\(item)")
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.white)
                                    .foregroundColor(.secondary)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack {
                    TextField(placeholder, text: $newItem)
                    Button(action: onAddDraft) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(addButtonColor)
                    }
                    .disabled(newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .cheeseInputChrome(cornerRadius: 12)
            }
        }
    }
}

struct PostFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangeSubviews(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalHeight = currentY + lineHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}
