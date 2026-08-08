//
//  ImagePreview+View.swift
//  CheeseApp
//
//  Remote image preview and gallery presentation.
//

import SwiftUI
import UIKit

enum ImagePreviewDismissalPolicy {
    static func shouldDismiss(
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) -> Bool {
        hypot(translation.width, translation.height) > 135
            || hypot(
                predictedEndTranslation.width,
                predictedEndTranslation.height
            ) > 230
    }

    static func adjustedTranslation(_ translation: CGSize) -> CGSize {
        CGSize(width: translation.width * 0.92, height: translation.height)
    }
}

// MARK: - Image Preview

private struct TapToPreviewImageModifier: ViewModifier {
    let urlString: String?
    @State private var showingPreview = false

    private var imageURL: URL? {
        guard let urlString, !urlString.isEmpty else { return nil }
        return URL(string: urlString)
    }

    func body(content: Content) -> some View {
        Button {
            guard imageURL != nil else { return }
            showingPreview = true
        } label: {
            content
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(imageURL == nil)
        .fullScreenCover(isPresented: $showingPreview) {
            if let imageURL {
                RemoteImagePreviewView(imageURL: imageURL)
                    .presentationBackground(.clear)
            }
        }
    }
}

private struct TapToPreviewImageGalleryModifier: ViewModifier {
    let urlStrings: [String]
    let selectedURLString: String
    @State private var showingPreview = false

    private var imageURLs: [URL] {
        urlStrings.compactMap(URL.init(string:))
    }

    private var initialIndex: Int {
        imageURLs.firstIndex { $0.absoluteString == selectedURLString } ?? 0
    }

    func body(content: Content) -> some View {
        Button {
            guard !imageURLs.isEmpty else { return }
            showingPreview = true
        } label: {
            content
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(imageURLs.isEmpty)
        .fullScreenCover(isPresented: $showingPreview) {
            if imageURLs.count == 1, let imageURL = imageURLs.first {
                RemoteImagePreviewView(imageURL: imageURL)
                    .presentationBackground(.clear)
            } else {
                RemoteImageGalleryPreviewView(
                    imageURLs: imageURLs,
                    initialIndex: initialIndex
                )
                .presentationBackground(.clear)
            }
        }
    }
}

private struct RemoteImageGalleryPreviewView: View {
    let imageURLs: [URL]
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var dismissDragOffset: CGSize = .zero
    @State private var dismissOverlayOpacity: Double = 1
    @State private var isDismissingInteractively = false
    @State private var zoomedImageIndices: Set<Int> = []

    init(imageURLs: [URL], initialIndex: Int) {
        self.imageURLs = imageURLs
        _currentIndex = State(
            initialValue: min(max(initialIndex, 0), max(imageURLs.count - 1, 0))
        )
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(imageURLs.enumerated()), id: \.offset) { index, imageURL in
                    ZoomableImageScrollView(
                        isZoomed: Binding(
                            get: { zoomedImageIndices.contains(index) },
                            set: { isZoomed in
                                if isZoomed {
                                    zoomedImageIndices.insert(index)
                                } else {
                                    zoomedImageIndices.remove(index)
                                }
                            }
                        ),
                        onSingleTap: { dismiss() }
                    ) {
                        CachedRemoteImage(url: imageURL) { image in
                            image
                                .resizable()
                                .scaledToFit()
                        } placeholder: {
                            ProgressView()
                                .tint(.white)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .scaleEffect(dismissScale)
            .rotationEffect(.degrees(dismissRotationDegrees))
            .offset(dismissDragOffset)
            .simultaneousGesture(galleryDismissGesture)

            VStack {
                HStack {
                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.95))
                    }
                    .buttonStyle(.plain)
                    .opacity(chromeOpacity)
                    .offset(y: chromeVerticalOffset)
                    .padding(18)
                }

                Spacer()

                if imageURLs.count > 1 {
                    HStack(spacing: 7) {
                        ForEach(imageURLs.indices, id: \.self) { index in
                            Circle()
                                .fill(
                                    index == currentIndex
                                        ? Color.white
                                        : Color.white.opacity(0.38)
                                )
                                .frame(
                                    width: index == currentIndex ? 8 : 6,
                                    height: index == currentIndex ? 8 : 6
                                )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.55))
                    .clipShape(Capsule())
                    .opacity(chromeOpacity)
                    .offset(y: chromeVerticalOffset)
                    .padding(.bottom, 24)
                    .accessibilityLabel(
                        L10n.tr(
                            "Photo \(currentIndex + 1) of \(imageURLs.count)",
                            "第 \(currentIndex + 1) 张，共 \(imageURLs.count) 张"
                        )
                    )
                }
            }
        }
    }

    /// Keeps horizontal paging available while adding the free-form dismissal
    /// used by the single-photo viewer. At the horizontal edges an outward drag
    /// dismisses; elsewhere horizontal drags continue to change pages.
    private var galleryDismissGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !isDismissingInteractively else { return }
                guard !isCurrentImageZoomed else { return }
                guard dismissDragOffset != .zero || canBeginDismissDrag(value.translation) else {
                    return
                }
                dismissDragOffset = dismissTranslation(for: value.translation)
            }
            .onEnded { value in
                guard dismissDragOffset != .zero else { return }

                if ImagePreviewDismissalPolicy.shouldDismiss(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation
                ) {
                    dismissPreviewInteractively(using: value)
                } else {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
                        dismissDragOffset = .zero
                        dismissOverlayOpacity = 1
                    }
                }
            }
    }

    private func canBeginDismissDrag(_ translation: CGSize) -> Bool {
        guard !isCurrentImageZoomed else { return false }
        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)

        // Vertical and diagonal movement dismiss from every page. A strongly
        // horizontal gesture remains reserved for paging unless it pulls beyond
        // the first or last image.
        if vertical >= horizontal * 0.55 {
            return true
        }
        if currentIndex == 0, translation.width > 0 {
            return true
        }
        if currentIndex == imageURLs.count - 1, translation.width < 0 {
            return true
        }
        return false
    }

    private var isCurrentImageZoomed: Bool {
        zoomedImageIndices.contains(currentIndex)
    }

    private func dismissTranslation(for translation: CGSize) -> CGSize {
        ImagePreviewDismissalPolicy.adjustedTranslation(translation)
    }

    private var dismissProgress: CGFloat {
        min(max(hypot(dismissDragOffset.width, dismissDragOffset.height) / 320, 0), 1)
    }

    private var dismissScale: CGFloat {
        max(0.9, 1 - dismissProgress * 0.1)
    }

    private var dismissRotationDegrees: Double {
        let normalized = max(min(dismissDragOffset.width / 240, 1), -1)
        return Double(normalized) * 3.4
    }

    private var backgroundOpacity: Double {
        let minOpacity = 0.05
        let value = 1 - Double(dismissProgress) * 0.95
        return max(0, max(minOpacity, min(1, value)) * dismissOverlayOpacity)
    }

    private var chromeOpacity: Double {
        max(0, max(0.18, 1 - Double(dismissProgress) * 1.25) * dismissOverlayOpacity)
    }

    private var chromeVerticalOffset: CGFloat {
        dismissDragOffset.height > 0 ? min(dismissDragOffset.height * 0.18, 20) : 0
    }

    private func dismissPreviewInteractively(using value: DragGesture.Value) {
        guard !isDismissingInteractively else { return }
        isDismissingInteractively = true

        let projected = dismissTranslation(for: value.predictedEndTranslation)
        withAnimation(.easeOut(duration: 0.16)) {
            dismissDragOffset = CGSize(
                width: projected.width * 1.08,
                height: projected.height * 1.18
            )
            dismissOverlayOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            dismiss()
        }
    }
}

// MARK: - Inline Post Gallery

/// Shared detail-page carousel for forum and marketplace posts.
struct PostImageCarousel<Placeholder: View>: View {
    let urlStrings: [String]
    let height: CGFloat
    let cornerRadius: CGFloat
    private let placeholder: () -> Placeholder

    @State private var currentIndex = 0
    @State private var previewInitialIndex = 0
    @State private var showingPreview = false

    init(
        urlStrings: [String],
        height: CGFloat,
        cornerRadius: CGFloat = 12,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.urlStrings = urlStrings
        self.height = height
        self.cornerRadius = cornerRadius
        self.placeholder = placeholder
    }

    private var imageItems: [(urlString: String, url: URL)] {
        urlStrings.compactMap { value in
            guard let url = URL(string: value) else { return nil }
            return (value, url)
        }
    }

    var body: some View {
        let items = imageItems

        ZStack(alignment: .bottom) {
            if items.isEmpty {
                placeholder()
            } else {
                TabView(selection: $currentIndex) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        Button {
                            previewInitialIndex = index
                            showingPreview = true
                        } label: {
                            CachedRemoteImage(url: item.url) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                placeholder()
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: height)
                            .clipped()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                if items.count > 1 {
                    HStack(spacing: 7) {
                        ForEach(items.indices, id: \.self) { index in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    currentIndex = index
                                }
                            } label: {
                                Circle()
                                    .fill(
                                        index == currentIndex
                                            ? Color.white
                                            : Color.white.opacity(0.48)
                                    )
                                    .frame(
                                        width: index == currentIndex ? 8 : 6,
                                        height: index == currentIndex ? 8 : 6
                                    )
                                    .frame(width: 14, height: 18)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                L10n.tr("Show photo \(index + 1)", "查看第 \(index + 1) 张图片")
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.46))
                    .clipShape(Capsule())
                    .padding(.bottom, 10)
                    .accessibilityValue(
                        L10n.tr(
                            "Photo \(currentIndex + 1) of \(items.count)",
                            "第 \(currentIndex + 1) 张，共 \(items.count) 张"
                        )
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // Keep presentation state on the stable carousel rather than a remote
        // image phase. This prevents the first tap from being dismissed when a
        // placeholder is replaced by the downloaded image.
        .fullScreenCover(isPresented: $showingPreview) {
            let urls = imageItems.map { $0.url }
            if urls.count == 1, let imageURL = urls.first {
                RemoteImagePreviewView(imageURL: imageURL)
                    .presentationBackground(.clear)
            } else if !urls.isEmpty {
                RemoteImageGalleryPreviewView(
                    imageURLs: urls,
                    initialIndex: previewInitialIndex
                )
                .presentationBackground(.clear)
            }
        }
        .onChange(of: items.count) { _, count in
            currentIndex = min(currentIndex, max(count - 1, 0))
            previewInitialIndex = min(previewInitialIndex, max(count - 1, 0))
            if count == 0 {
                showingPreview = false
            }
        }
    }
}

private struct RemoteImagePreviewView: View {
    let imageURL: URL

    var body: some View {
        InteractiveImagePreviewView {
            CachedRemoteImage(url: imageURL) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                ProgressView()
                    .tint(.white)
            }
        }
    }
}

struct LocalImagePreviewView: View {
    let image: UIImage

    var body: some View {
        InteractiveImagePreviewView {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        }
    }
}

private struct InteractiveImagePreviewView<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    private let content: () -> Content

    @State private var isImageZoomed = false
    @State private var dismissDragOffset: CGSize = .zero
    @State private var dismissOverlayOpacity: Double = 1
    @State private var isDismissingInteractively = false

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()
                .onTapGesture(perform: dismissPreviewImmediately)

            ZoomableImageScrollView(
                isZoomed: $isImageZoomed,
                onSingleTap: dismissPreviewImmediately
            ) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 16)
            }
                .scaleEffect(dismissScale)
                .rotationEffect(.degrees(dismissRotationDegrees))
                .offset(dismissDragOffset)
                .simultaneousGesture(dismissGesture)
                .onChange(of: isImageZoomed) { _, isZoomed in
                    guard isZoomed else { return }
                    dismissDragOffset = .zero
                    dismissOverlayOpacity = 1
                }

            VStack {
                HStack {
                    Spacer()

                    Button(action: dismissPreviewImmediately) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.95))
                    }
                    .buttonStyle(.plain)
                    .opacity(chromeOpacity)
                    .offset(y: chromeVerticalOffset)
                    .padding(18)
                }

                Spacer()
            }
        }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !isDismissingInteractively else { return }
                guard !isImageZoomed else { return }
                dismissDragOffset = ImagePreviewDismissalPolicy.adjustedTranslation(
                    value.translation
                )
            }
            .onEnded { value in
                guard !isImageZoomed else { return }
                if ImagePreviewDismissalPolicy.shouldDismiss(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation
                ) {
                    dismissPreviewInteractively(using: value)
                } else {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
                        dismissDragOffset = .zero
                        dismissOverlayOpacity = 1
                    }
                }
            }
    }

    private var dismissProgress: CGFloat {
        guard !isImageZoomed else { return 0 }
        let distance = hypot(dismissDragOffset.width, dismissDragOffset.height)
        return min(max(distance / 320, 0), 1)
    }

    private var dismissScale: CGFloat {
        guard !isImageZoomed else { return 1 }
        return max(0.9, 1 - dismissProgress * 0.1)
    }

    private var dismissRotationDegrees: Double {
        guard !isImageZoomed else { return 0 }
        let normalized = max(min(dismissDragOffset.width / 240, 1), -1)
        return Double(normalized) * 3.4
    }

    private var backgroundOpacity: Double {
        let minOpacity = 0.05
        let value = 1 - Double(dismissProgress) * 0.95
        return max(0, max(minOpacity, min(1, value)) * dismissOverlayOpacity)
    }

    private var chromeOpacity: Double {
        max(0, max(0.18, 1 - Double(dismissProgress) * 1.25) * dismissOverlayOpacity)
    }

    private var chromeVerticalOffset: CGFloat {
        dismissDragOffset.height > 0 ? min(dismissDragOffset.height * 0.18, 20) : 0
    }

    private func dismissPreviewImmediately() {
        dismiss()
    }

    private func dismissPreviewInteractively(using value: DragGesture.Value) {
        guard !isDismissingInteractively else { return }
        isDismissingInteractively = true

        let projected = ImagePreviewDismissalPolicy.adjustedTranslation(
            value.predictedEndTranslation
        )
        withAnimation(.easeOut(duration: 0.16)) {
            dismissDragOffset = CGSize(
                width: projected.width * 1.08,
                height: projected.height * 1.18
            )
            dismissOverlayOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            dismiss()
        }
    }
}

/// Uses the system scroll view for native pinch zooming and panning. Its pan
/// recognizer is active only while zoomed, leaving gallery paging and the
/// full-screen dismissal gesture available at the normal 1× scale.
private struct ZoomableImageScrollView<Content: View>: UIViewRepresentable {
    @Binding var isZoomed: Bool
    private let onSingleTap: () -> Void
    private let content: () -> Content

    init(
        isZoomed: Binding<Bool>,
        onSingleTap: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _isZoomed = isZoomed
        self.onSingleTap = onSingleTap
        self.content = content
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isZoomed: $isZoomed, onSingleTap: onSingleTap)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .clear
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.isEnabled = false

        let hostingController = UIHostingController(rootView: content())
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor
            ),
            hostingController.view.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor
            ),
            hostingController.view.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor
            ),
            hostingController.view.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor
            ),
            hostingController.view.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor
            ),
            hostingController.view.heightAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.heightAnchor
            )
        ])

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        context.coordinator.hostingController = hostingController
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.isZoomed = $isZoomed
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.hostingController?.rootView = content()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var isZoomed: Binding<Bool>
        var onSingleTap: () -> Void
        var hostingController: UIHostingController<Content>?
        weak var scrollView: UIScrollView?

        init(isZoomed: Binding<Bool>, onSingleTap: @escaping () -> Void) {
            self.isZoomed = isZoomed
            self.onSingleTap = onSingleTap
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostingController?.view
        }

        func scrollViewWillBeginZooming(
            _ scrollView: UIScrollView,
            with view: UIView?
        ) {
            publishZoomState(true)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            scrollView.panGestureRecognizer.isEnabled = zoomed
            publishZoomState(zoomed)
            centerZoomedContent(in: scrollView)
        }

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onSingleTap()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView, let hostedView = hostingController?.view else { return }

            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let targetScale = min(2.5, scrollView.maximumZoomScale)
            let location = recognizer.location(in: hostedView)
            let zoomSize = CGSize(
                width: scrollView.bounds.width / targetScale,
                height: scrollView.bounds.height / targetScale
            )
            let zoomRect = CGRect(
                x: location.x - zoomSize.width / 2,
                y: location.y - zoomSize.height / 2,
                width: zoomSize.width,
                height: zoomSize.height
            )
            scrollView.zoom(to: zoomRect, animated: true)
        }

        private func publishZoomState(_ value: Bool) {
            guard isZoomed.wrappedValue != value else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isZoomed.wrappedValue != value else { return }
                self.isZoomed.wrappedValue = value
            }
        }

        private func centerZoomedContent(in scrollView: UIScrollView) {
            let horizontalInset = max(
                (scrollView.bounds.width - scrollView.contentSize.width) / 2,
                0
            )
            let verticalInset = max(
                (scrollView.bounds.height - scrollView.contentSize.height) / 2,
                0
            )
            scrollView.contentInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset,
                right: horizontalInset
            )
        }
    }
}

extension View {
    func tappableImagePreview(_ urlString: String?) -> some View {
        modifier(
            TapToPreviewImageModifier(urlString: urlString)
        )
    }

    func tappableImagePreview(_ urlStrings: [String], selected urlString: String) -> some View {
        modifier(
            TapToPreviewImageGalleryModifier(
                urlStrings: urlStrings,
                selectedURLString: urlString
            )
        )
    }
}
