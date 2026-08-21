//
//  FeedMediaLayout.swift
//  CheeseApp
//
//  One deterministic feed-media model: fixed height, source-ratio width, and
//  one minimum-width exception that can crop only the vertical axis.
//


import CoreGraphics
import SwiftUI
import UIKit

enum FeedMediaRenderMode: Equatable {
    case fit
    case centerVerticalCrop(sourceAspectRatio: CGFloat)
}

enum FeedMediaImageKey: Hashable {
    case remote(URL)
    case asset(String)
    case placeholder
}

enum FeedMediaAspectRatioState {
    static func reconciling(
        _ existing: [FeedMediaImageKey: CGFloat],
        currentKeys: [FeedMediaImageKey],
        cachedRatio: (FeedMediaImageKey) -> CGFloat?
    ) -> [FeedMediaImageKey: CGFloat] {
        let currentKeySet = Set(currentKeys)
        var reconciled = existing.filter { currentKeySet.contains($0.key) }

        for key in currentKeys where reconciled[key] == nil {
            if let ratio = cachedRatio(key) {
                reconciled[key] = ratio
            }
        }

        return reconciled
    }
}

enum FeedMediaHorizontalPlacement: Equatable {
    case leading

    var alignment: Alignment {
        switch self {
        case .leading: .leading
        }
    }
}

enum FeedMediaPlaceholderStyle: Equatable {
    case neutralGray
}

enum FeedMediaStyle {
    static let cornerRadius: CGFloat = 12
    static let itemSpacing: CGFloat = 7
    static let contentInset: CGFloat = 0
    static let minimumMediaWidth: CGFloat = 100
    static let fallbackAspectRatio: CGFloat = 1
    static let horizontalPlacement: FeedMediaHorizontalPlacement = .leading
    static let placeholderStyle: FeedMediaPlaceholderStyle = .neutralGray

    static var horizontalAlignment: Alignment {
        horizontalPlacement.alignment
    }

    static var placeholderBackground: Color {
        switch placeholderStyle {
        case .neutralGray: Color.gray.opacity(0.16)
        }
    }
}

enum FeedMediaScrollGesturePolicy {
    static let overflowTolerance: CGFloat = 1

    static func shouldCaptureHorizontalDrag(
        contentWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> Bool {
        guard contentWidth.isFinite,
              viewportWidth.isFinite,
              contentWidth > 0,
              viewportWidth > 0
        else {
            return false
        }

        return contentWidth > viewportWidth + overflowTolerance
    }
}

struct FeedMediaMetrics: Equatable {
    let mediaHeight: CGFloat
    let minimumMediaWidth: CGFloat
    let spacing: CGFloat

    init(
        mediaHeight: CGFloat,
        minimumMediaWidth: CGFloat = FeedMediaStyle.minimumMediaWidth,
        spacing: CGFloat = FeedMediaStyle.itemSpacing
    ) {
        self.mediaHeight = mediaHeight
        self.minimumMediaWidth = minimumMediaWidth
        self.spacing = spacing
    }

    static let forum = FeedMediaMetrics(mediaHeight: 190)
    static let secondhand = FeedMediaMetrics(mediaHeight: 210)
}

struct FeedMediaItemLayout: Equatable {
    let width: CGFloat
    let height: CGFloat
    let renderMode: FeedMediaRenderMode
}

struct FeedMediaLayoutEngine {
    func sourceAspectRatio(width: CGFloat, height: CGFloat) -> CGFloat? {
        guard width.isFinite,
              height.isFinite,
              width > 0,
              height > 0
        else { return nil }

        let ratio = width / height
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }

    func itemLayout(
        sourceWidth: CGFloat,
        sourceHeight: CGFloat,
        metrics: FeedMediaMetrics
    ) -> FeedMediaItemLayout {
        itemLayout(
            sourceAspectRatio: sourceAspectRatio(
                width: sourceWidth,
                height: sourceHeight
            ),
            metrics: metrics
        )
    }

    func itemLayout(
        sourceAspectRatio: CGFloat?,
        metrics: FeedMediaMetrics
    ) -> FeedMediaItemLayout {
        let mediaHeight = max(metrics.mediaHeight, 1)
        let minimumMediaWidth = max(metrics.minimumMediaWidth, 1)
        let ratio = validAspectRatio(sourceAspectRatio)
            ?? FeedMediaStyle.fallbackAspectRatio
        let naturalWidth = mediaHeight * ratio

        if naturalWidth >= minimumMediaWidth {
            return FeedMediaItemLayout(
                width: naturalWidth,
                height: mediaHeight,
                renderMode: .fit
            )
        }

        return FeedMediaItemLayout(
            width: minimumMediaWidth,
            height: mediaHeight,
            renderMode: .centerVerticalCrop(sourceAspectRatio: ratio)
        )
    }

    private func validAspectRatio(_ ratio: CGFloat?) -> CGFloat? {
        guard let ratio, ratio.isFinite, ratio > 0 else { return nil }
        return ratio
    }
}

/// Shared by Forum, recommended/following, and Secondhand. Single and multiple
/// images deliberately use the same horizontal strip and sizing calculation.
struct FeedMediaStrip: View {
    let images: [ImageSource]
    let metrics: FeedMediaMetrics
    var targetPixelWidth: Int = 1_024
    var allowsImagePreview = true

    private let engine = FeedMediaLayoutEngine()
    @State private var aspectRatios: [FeedMediaImageKey: CGFloat] = [:]
    @State private var viewportWidth: CGFloat = 0

    private var displayedImages: [ImageSource] {
        images.isEmpty ? [.placeholder] : images
    }

    private var remoteURLStrings: [String] {
        images.compactMap(\.remoteURL).map(\.absoluteString)
    }

    private var contentWidth: CGFloat {
        let widths = displayedImages.indices.map { index in
            let image = displayedImages[index]
            return engine.itemLayout(
                sourceAspectRatio: aspectRatios[image.feedMediaKey],
                metrics: metrics
            ).width
        }
        let gaps = CGFloat(max(widths.count - 1, 0)) * metrics.spacing
        return widths.reduce(0, +) + gaps
    }

    private var capturesHorizontalDrag: Bool {
        FeedMediaScrollGesturePolicy.shouldCaptureHorizontalDrag(
            contentWidth: contentWidth,
            viewportWidth: viewportWidth
        )
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: metrics.spacing) {
                ForEach(
                    Array(displayedImages.enumerated()),
                    id: \.offset
                ) { index, image in
                    let imageKey = image.feedMediaKey
                    let layout = engine.itemLayout(
                        sourceAspectRatio: aspectRatios[imageKey],
                        metrics: metrics
                    )

                    previewableItem(
                        image: image,
                        imageKey: imageKey,
                        index: index,
                        layout: layout
                    )
                    .frame(width: layout.width, height: layout.height)
                    .feedMediaPresentation()
                }
            }
            .background {
                if capturesHorizontalDrag {
                    HorizontalScrollGestureFence()
                }
            }
        }
        .contentMargins(
            .horizontal,
            FeedMediaStyle.contentInset,
            for: .scrollContent
        )
        .scrollDisabled(!capturesHorizontalDrag)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, alignment: FeedMediaStyle.horizontalAlignment)
        .frame(height: metrics.mediaHeight)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard abs(viewportWidth - width) > 0.5 else { return }
            viewportWidth = width
        }
        .task(id: imageIdentity) {
            hydrateKnownAspectRatios()
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var imageIdentity: [FeedMediaImageKey] {
        displayedImages.map(\.feedMediaKey)
    }

    @ViewBuilder
    private func previewableItem(
        image: ImageSource,
        imageKey: FeedMediaImageKey,
        index: Int,
        layout: FeedMediaItemLayout
    ) -> some View {
        let item = FeedMediaItem(
            source: image,
            targetPixelWidth: targetPixelWidth,
            renderMode: layout.renderMode,
            onImageSize: { updateAspectRatio(for: imageKey, size: $0) }
        )

        if allowsImagePreview,
           remoteURLStrings.count == images.count,
           image.remoteURL != nil {
            item.tappableImagePreview(remoteURLStrings, initialIndex: index)
        } else {
            item
        }
    }

    private func hydrateKnownAspectRatios() {
        let currentKeys = displayedImages.map(\.feedMediaKey)
        let known = FeedMediaAspectRatioState.reconciling(
            aspectRatios,
            currentKeys: currentKeys
        ) { key in
            switch key {
            case .remote(let url):
                return RemoteImageCache.shared.aspectRatio(for: url)
            case .asset(let name):
                guard let size = UIImage(named: name)?.size else { return nil }
                return engine.sourceAspectRatio(width: size.width, height: size.height)
            case .placeholder:
                return nil
            }
        }

        guard known != aspectRatios else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            aspectRatios = known
        }
    }

    private func updateAspectRatio(for key: FeedMediaImageKey, size: CGSize) {
        guard let ratio = engine.sourceAspectRatio(
            width: size.width,
            height: size.height
        ), aspectRatios[key] != ratio else { return }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            aspectRatios[key] = ratio
        }
    }
}

struct FeedMediaItem: View {
    let source: ImageSource
    var targetPixelWidth: Int = 1_024
    var renderMode: FeedMediaRenderMode = .fit
    var onImageSize: (CGSize) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            Group {
                switch source {
                case .asset(let name):
                    renderedImage(
                        Image(name),
                        containerWidth: proxy.size.width
                    )
                    .onAppear {
                        if let size = UIImage(named: name)?.size {
                            onImageSize(size)
                        }
                    }
                case .url(let url):
                    CachedRemoteImage(
                        url: url,
                        targetPixelWidth: targetPixelWidth,
                        onImageLoaded: onImageSize
                    ) { image in
                        renderedImage(
                            image,
                            containerWidth: proxy.size.width
                        )
                    } placeholder: {
                        FeedMediaPlaceholder()
                    }
                case .placeholder:
                    FeedMediaPlaceholder()
                }
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .center
            )
            .clipped()
        }
        .accessibilityLabel(L10n.tr("Post image", "帖子图片"))
        .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder
    private func renderedImage(
        _ image: Image,
        containerWidth: CGFloat
    ) -> some View {
        switch renderMode {
        case .fit:
            image
                .resizable()
                .scaledToFit()
        case .centerVerticalCrop(let sourceAspectRatio):
            let safeRatio = max(sourceAspectRatio, 0.000_001)
            image
                .resizable()
                .scaledToFit()
                .frame(
                    width: containerWidth,
                    height: containerWidth / safeRatio
                )
        }
    }
}

struct FeedMediaPlaceholder: View {
    var body: some View {
        Rectangle().fill(FeedMediaStyle.placeholderBackground)
    }
}

private struct FeedMediaPresentationModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .clipShape(
                RoundedRectangle(
                    cornerRadius: FeedMediaStyle.cornerRadius,
                    style: .continuous
                )
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: FeedMediaStyle.cornerRadius,
                    style: .continuous
                )
            )
    }
}

extension View {
    func feedMediaPresentation() -> some View {
        modifier(FeedMediaPresentationModifier())
    }
}

private extension ImageSource {
    var feedMediaKey: FeedMediaImageKey {
        switch self {
        case .url(let url): .remote(url)
        case .asset(let name): .asset(name)
        case .placeholder: .placeholder
        }
    }

    var remoteURL: URL? {
        guard case .url(let url) = self else { return nil }
        return url
    }

    var assetSize: CGSize? {
        guard case .asset(let name) = self else { return nil }
        return UIImage(named: name)?.size
    }
}
