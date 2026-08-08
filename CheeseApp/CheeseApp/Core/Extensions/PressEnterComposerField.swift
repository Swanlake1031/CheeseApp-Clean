//
//  PressEnterComposerField.swift
//  CheeseApp
//
//  Chat composer text view bridge.
//

import SwiftUI
import UIKit

/// Native text view shared by editable product surfaces. Paste remains
/// available at an empty insertion point; every selection-dependent action is
/// still delegated to UIKit so Cut/Copy/Select follow the actual selection.
final class CheeseEditableTextView: UITextView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let hasText = !text.isEmpty
        let hasSelection = selectedRange.length > 0

        switch action {
        case #selector(paste(_:)):
            return isEditable
        case #selector(copy(_:)):
            return isSelectable && hasSelection
        case #selector(cut(_:)):
            return isEditable && isSelectable && hasSelection
        case #selector(select(_:)):
            return isSelectable && hasText && !hasSelection
        case #selector(selectAll(_:)):
            return isSelectable && hasText
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }
}

final class CheeseEditableTextField: UITextField {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let hasText = !(text ?? "").isEmpty
        let hasSelection = selectedTextRange.map {
            offset(from: $0.start, to: $0.end) > 0
        } ?? false

        switch action {
        case #selector(paste(_:)):
            return isEnabled
        case #selector(copy(_:)):
            return isEnabled && hasSelection
        case #selector(cut(_:)):
            return isEnabled && hasSelection
        case #selector(select(_:)):
            return isEnabled && hasText && !hasSelection
        case #selector(selectAll(_:)):
            return isEnabled && hasText
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }
}

private extension UITextView {
    func configureCheeseEditing(fontSize: CGFloat) {
        backgroundColor = .clear
        font = .systemFont(ofSize: fontSize)
        textColor = UIColor.label
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        isEditable = true
        isSelectable = true
        isUserInteractionEnabled = true
        allowsEditingTextAttributes = false
        smartInsertDeleteType = .yes
    }
}

/// Shared native single-line field for post titles and structured form values.
/// Keeping these fields on UIKit gives them the same edit-menu behavior as the
/// multiline composer instead of relying on SwiftUI's private text responder.
struct CheeseSystemTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 17
    var fontWeight: UIFont.Weight = .regular
    var keyboardType: UIKeyboardType = .default
    var isFirstResponder: Binding<Bool>?

    func makeUIView(context: Context) -> UITextField {
        let textField = CheeseEditableTextField()
        textField.delegate = context.coordinator
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        textField.borderStyle = .none
        textField.backgroundColor = .clear
        textField.textColor = .label
        textField.tintColor = .systemBlue
        textField.clearButtonMode = .never
        textField.autocorrectionType = .yes
        textField.spellCheckingType = .yes
        textField.smartInsertDeleteType = .yes
        textField.text = text
        configure(textField)
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.parent = self
        if textField.text != text {
            textField.text = text
        }
        configure(textField)

        guard let isFirstResponder else { return }
        if isFirstResponder.wrappedValue {
            if !textField.isFirstResponder {
                DispatchQueue.main.async { [weak textField] in
                    guard let textField, textField.window != nil else { return }
                    textField.becomeFirstResponder()
                }
            }
        } else if textField.isFirstResponder {
            textField.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func configure(_ textField: UITextField) {
        textField.placeholder = placeholder
        textField.font = .systemFont(ofSize: fontSize, weight: fontWeight)
        textField.keyboardType = keyboardType
        textField.isEnabled = true
        textField.isUserInteractionEnabled = true
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CheeseSystemTextField

        init(parent: CheeseSystemTextField) {
            self.parent = parent
        }

        @objc func textDidChange(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if parent.isFirstResponder?.wrappedValue == false {
                parent.isFirstResponder?.wrappedValue = true
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFirstResponder?.wrappedValue == true {
                parent.isFirstResponder?.wrappedValue = false
            }
        }
    }
}

/// Shared UIKit-backed search field. SwiftUI's private search responders can
/// lose the standard edit menu when embedded in custom gesture surfaces, so
/// every product search entry uses this field to keep Paste/Cut/Copy native.
struct CheeseSearchTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 15
    var fontWeight: UIFont.Weight = .regular
    var textColor: UIColor = .label
    var placeholderColor: UIColor = .placeholderText
    var isFirstResponder: Binding<Bool>?
    var onSubmit: () -> Void = {}

    func makeUIView(context: Context) -> UITextField {
        let textField = CheeseEditableTextField()
        textField.delegate = context.coordinator
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        textField.borderStyle = .none
        textField.backgroundColor = .clear
        textField.tintColor = .systemBlue
        textField.clearButtonMode = .never
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartInsertDeleteType = .yes
        textField.returnKeyType = .search
        textField.adjustsFontSizeToFitWidth = false
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.text = text
        configure(textField)
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.parent = self
        if textField.text != text {
            textField.text = text
        }
        configure(textField)

        guard let isFirstResponder else { return }
        if isFirstResponder.wrappedValue {
            if !textField.isFirstResponder {
                DispatchQueue.main.async { [weak textField] in
                    guard let textField, textField.window != nil else { return }
                    textField.becomeFirstResponder()
                }
            }
        } else if textField.isFirstResponder {
            textField.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextField,
        context: Context
    ) -> CGSize? {
        guard let proposedWidth = proposal.width else { return nil }
        return CGSize(
            width: max(proposedWidth, 0),
            height: max(uiView.intrinsicContentSize.height, 22)
        )
    }

    private func configure(_ textField: UITextField) {
        textField.font = .systemFont(ofSize: fontSize, weight: fontWeight)
        textField.textColor = textColor
        textField.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: placeholderColor]
        )
        textField.isEnabled = true
        textField.isUserInteractionEnabled = true
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CheeseSearchTextField

        init(parent: CheeseSearchTextField) {
            self.parent = parent
        }

        @objc func textDidChange(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if parent.isFirstResponder?.wrappedValue == false {
                parent.isFirstResponder?.wrappedValue = true
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFirstResponder?.wrappedValue == true {
                parent.isFirstResponder?.wrappedValue = false
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

struct PressEnterComposerField: UIViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var submitDelay: TimeInterval = 0.4

    func makeUIView(context: Context) -> UITextView {
        let textView = CheeseEditableTextView()
        textView.delegate = context.coordinator
        textView.text = text
        textView.configureCheeseEditing(fontSize: 15)
        // Keep a single-line chat draft visually centered inside the 42pt
        // composer while still allowing pasted multiline text to grow upward.
        textView.textContainerInset = UIEdgeInsets(
            top: 10,
            left: 0,
            bottom: 8,
            right: 0
        )
        textView.isScrollEnabled = true
        textView.returnKeyType = .send
        textView.enablesReturnKeyAutomatically = true
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        textView.isEditable = true
        textView.isSelectable = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var parent: PressEnterComposerField
        private var lastSubmitAt = Date.distantPast

        init(parent: PressEnterComposerField) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            guard replacement == "\n" else { return true }

            let now = Date()
            guard now.timeIntervalSince(lastSubmitAt) >= parent.submitDelay else {
                return false
            }
            lastSubmitAt = now
            parent.onSubmit()
            return false
        }
    }
}

/// A multiline editor that can reliably become first responder while it is
/// being attached to a presented sheet. SwiftUI's `FocusState` can be consumed
/// before the sheet owns a window, leaving the composer visible without the
/// keyboard; this bridge waits for the actual UIKit attachment instead.
struct AutoFocusTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFirstResponder: Bool
    var fontSize: CGFloat = 18
    var fontWeight: UIFont.Weight = .regular
    var maximumLength: Int?
    var dynamicHeight: Binding<CGFloat>?
    var minimumHeight: CGFloat = 0
    var maximumHeight: CGFloat = .greatestFiniteMagnitude

    func makeUIView(context: Context) -> UITextView {
        let textView = CheeseEditableTextView()
        textView.delegate = context.coordinator
        textView.text = text
        textView.configureCheeseEditing(fontSize: fontSize)
        textView.isScrollEnabled = dynamicHeight == nil
        textView.keyboardDismissMode = .interactive
        textView.returnKeyType = .default
        textView.alwaysBounceHorizontal = false
        textView.showsHorizontalScrollIndicator = false
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.lineBreakMode = .byWordWrapping
        DispatchQueue.main.async { [weak textView, weak coordinator = context.coordinator] in
            guard let textView else { return }
            coordinator?.refreshDynamicHeight(for: textView)
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

        if textView.text != text {
            textView.text = text
        }
        textView.font = .systemFont(ofSize: fontSize, weight: fontWeight)
        textView.isEditable = true
        textView.isSelectable = true
        updateDynamicHeight(for: textView)

        if isFirstResponder {
            context.coordinator.ensureFirstResponder(textView)
        } else {
            context.coordinator.cancelFocusRequest()
            if textView.isFirstResponder {
                textView.resignFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let height = proposal.height
            ?? dynamicHeight?.wrappedValue
            ?? max(minimumHeight, uiView.contentSize.height)
        return CGSize(width: width, height: height)
    }

    private func updateDynamicHeight(for textView: UITextView) {
        guard let dynamicHeight, textView.bounds.width > 0 else { return }

        let fittingHeight = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        ).height
        let resolvedHeight = min(max(fittingHeight, minimumHeight), maximumHeight)
        textView.isScrollEnabled = fittingHeight > maximumHeight + 0.5

        guard abs(dynamicHeight.wrappedValue - resolvedHeight) > 0.5 else { return }
        DispatchQueue.main.async {
            dynamicHeight.wrappedValue = resolvedHeight
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AutoFocusTextEditor
        private var focusRequestGeneration = 0
        private var focusRequestPending = false

        init(parent: AutoFocusTextEditor) {
            self.parent = parent
        }

        func refreshDynamicHeight(for textView: UITextView) {
            parent.updateDynamicHeight(for: textView)
        }

        func ensureFirstResponder(_ textView: UITextView) {
            guard !textView.isFirstResponder, !focusRequestPending else { return }

            focusRequestPending = true
            focusRequestGeneration += 1
            // Sheet attachment can span several animation frames. Keep retrying
            // briefly, but focus on the first frame where the text view has a window.
            attemptFocus(textView, generation: focusRequestGeneration, attemptsRemaining: 40)
        }

        func cancelFocusRequest() {
            focusRequestGeneration += 1
            focusRequestPending = false
        }

        private func attemptFocus(
            _ textView: UITextView,
            generation: Int,
            attemptsRemaining: Int
        ) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                guard generation == self.focusRequestGeneration, self.parent.isFirstResponder else {
                    self.focusRequestPending = false
                    return
                }

                if textView.window != nil,
                   (textView.isFirstResponder || textView.becomeFirstResponder()) {
                    self.focusRequestPending = false
                } else if attemptsRemaining > 0 {
                    // Being in a window does not mean the sheet's transition has
                    // finished. UIKit may reject first-responder activation for a
                    // few frames, so only stop after it explicitly succeeds.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self, weak textView] in
                        guard let self, let textView else { return }
                        self.attemptFocus(
                            textView,
                            generation: generation,
                            attemptsRemaining: attemptsRemaining - 1
                        )
                    }
                } else {
                    self.focusRequestPending = false
                }
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            focusRequestPending = false
            if !parent.isFirstResponder {
                parent.isFirstResponder = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFirstResponder {
                parent.isFirstResponder = false
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            if let maximumLength = parent.maximumLength,
               textView.text.count > maximumLength {
                let limited = String(textView.text.prefix(maximumLength))
                textView.text = limited
                textView.selectedRange = NSRange(
                    location: limited.utf16.count,
                    length: 0
                )
            }
            parent.text = textView.text
            refreshDynamicHeight(for: textView)
        }
    }
}

/// Shared multiline editor for create/edit post forms. It deliberately uses the
/// same native text view as comments so selection and standard edit actions do
/// not vary by feature.
struct CheeseSystemTextEditor: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 17
    var isFirstResponder: Binding<Bool>?

    func makeUIView(context: Context) -> UITextView {
        let textView = CheeseEditableTextView()
        textView.delegate = context.coordinator
        textView.text = text
        textView.configureCheeseEditing(fontSize: fontSize)
        textView.isScrollEnabled = true
        textView.keyboardDismissMode = .interactive
        textView.returnKeyType = .default
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text {
            let selection = textView.selectedRange
            textView.text = text
            let safeLocation = min(selection.location, textView.text.utf16.count)
            textView.selectedRange = NSRange(location: safeLocation, length: 0)
        }
        textView.font = .systemFont(ofSize: fontSize)
        textView.isEditable = true
        textView.isSelectable = true

        guard let isFirstResponder else { return }
        if isFirstResponder.wrappedValue {
            if !textView.isFirstResponder {
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, textView.window != nil else { return }
                    textView.becomeFirstResponder()
                }
            }
        } else if textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CheeseSystemTextEditor

        init(parent: CheeseSystemTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if parent.isFirstResponder?.wrappedValue == false {
                parent.isFirstResponder?.wrappedValue = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFirstResponder?.wrappedValue == true {
                parent.isFirstResponder?.wrappedValue = false
            }
        }
    }
}
