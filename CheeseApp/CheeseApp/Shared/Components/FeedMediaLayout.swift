//
//  FeedMediaLayout.swift
//  CheeseApp
//
//  Source-aware media sizing for forum feed thumbnails. Layout calculation is
//  intentionally independent from SwiftUI rendering so the edge cases remain
//  deterministic and unit-testable.
//


import CoreGraphics
import SwiftUI
import UIKit

struct FeedMediaMetrics: Equatable {
    let minimumDisplayAspectRatio: CGFloat
    let maximumDisplayAspectRatio: CGFloat
    let fallbackAspectRatio: CGFloat
    let singleImageMaxWidth: CGFloat
    let singleImageMaxHeight: CGFloat
    let multiImageRowHeight: CGFloat
    let multiImageMaxWidth: CGFloat
    let spacing: CGFloat
    let cornerRadius: CGFloat

    static let forum = FeedMediaMetrics(
        minimumDisplayAspectRatio: 0.65,
        maximumDisplayAspectRatio: 1.70,
        fallbackAspectRatio: 1.0,
        singleImageMaxWidth: 520,
        singleImageMaxHeight: 360,
        multiImageRowHeight: 190,
        multiImageMaxWidth: 320,
        spacing: 7,
        cornerRadius: 12
    )
}

struct FeedMediaItemLayout: Equatable {
    let width: CGFloat
    let height: CGFloat
    let displayAspectRatio: CGFloat
    let requiresCrop: Bool
}

struct FeedMediaLayoutEngine {
    let metrics: FeedMediaMetrics

    init(metrics: FeedMediaMetrics = .forum) {
        self.metrics = metrics
    }

    func sourceAspectRatio(width: CGFloat, height: CGFloat) -> CGFloat? {
        guard width.isFinite,
              height.isFinite,
              width > 0,
              height > 0
        else { return nil }

        let ratio = width / height
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }

    func constrainedAspectRatio(_ sourceAspectRatio: CGFloat?) -> CGFloat {
        let sourceRatio = validAspectRatio(sourceAspectRatio)
            ?? metrics.fallbackAspectRatio
        return min(
            max(sourceRatio, metrics.minimumDisplayAspectRatio),
            metrics.maximumDisplayAspectRatio
        )
    }

    func singleImageLayout(
        sourceAspectRatio: CGFloat?,
        availableWidth: CGFloat
    ) -> FeedMediaItemLayout {
        let safeAvailableWidth = max(availableWidth, 1)
        let sourceRatio = validAspectRatio(sourceAspectRatio)
        let displayRatio = constrainedAspectRatio(sourceRatio)
        let maximumWidth = min(safeAvailableWidth, metrics.singleImageMaxWidth)

        let size: CGSize
        if displayRatio < 1 {
            let height = min(
                metrics.singleImageMaxHeight,
                maximumWidth / displayRatio
            )
            size = CGSize(width: height * displayRatio, height: height)
        } else {
            let width = min(
                maximumWidth,
                metrics.singleImageMaxHeight * displayRatio
            )
            size = CGSize(width: width, height: width / displayRatio)
        }

        return FeedMediaItemLayout(
            width: size.width,
            height: size.height,
            displayAspectRatio: displayRatio,
            requiresCrop: sourceRatio.map { abs($0 - displayRatio) > 0.001 } ?? false
        )
    }

    func multiImageItemLayout(
        sourceAspectRatio: CGFloat?
    ) -> FeedMediaItemLayout {
        let sourceRatio = validAspectRatio(sourceAspectRatio)
        let displayRatio = constrainedAspectRatio(sourceRatio)
        let naturalWidth = metrics.multiImageRowHeight * displayRatio
        let width = min(naturalWidth, metrics.multiImageMaxWidth)
        let frameRatio = width / metrics.multiImageRowHeight

        return FeedMediaItemLayout(
            width: width,
            height: metrics.multiImageRowHeight,
            displayAspectRatio: frameRatio,
            requiresCrop: sourceRatio.map { abs($0 - frameRatio) > 0.001 } ?? false
        )
    }

    private func validAspectRatio(_ ratio: CGFloat?) -> CGFloat? {
        guard let ratio, ratio.isFinite, ratio > 0 else { return nil }
        return ratio
    }
}

/// Forum-only source-aware feed media. Secondhand continues to use its existing
/// fixed-height carousel until that product surface is changed independently.
struct ForumFeedMediaView: View {
    let images: [ImageSource]

    private let engine = FeedMediaLayoutEngine()
    @State private var aspectRatios: [Int: CGFloat] = [:]

    private var remoteURLStrings: [String] {
        images.compactMap(\.remoteURL).map(\.absoluteString)
    }

    var body: some View {
        Group {
            if images.count == 1, let image = images.first {
                AdaptiveSingleFeedImageLayout(
                    engine: engine,
                    sourceAspectRatio: aspectRatios[0]
                ) {
                    previewableMediaTile(image: image, index: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if images.count > 1 {
                HorizontalFeedMediaStrip(
                    images: images,
                    aspectRatios: aspectRatios,
                    engine: engine,
                    onImageSize: updateAspectRatio
                )
            }
        }
        .task(id: imageIdentity) {
            hydrateKnownAspectRatios()
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var imageIdentity: [String] {
        images.enumerated().map { index, image in
            image.remoteURL?.absoluteString ?? "local-\(index)"
        }
    }

    @ViewBuilder
    private func previewableMediaTile(image: ImageSource, index: Int) -> some View {
        let tile = FeedMediaTile(
            source: image,
            cornerRadius: engine.metrics.cornerRadius,
            onImageSize: { updateAspectRatio(index: index, size: $0) }
        )

        if remoteURLStrings.count == images.count, image.remoteURL != nil {
            tile.tappableImagePreview(remoteURLStrings, initialIndex: index)
        } else {
            tile
        }
    }

    private func hydrateKnownAspectRatios() {
        var known = aspectRatios

        for (index, image) in images.enumerated() {
            if let url = image.remoteURL,
               let ratio = RemoteImageCache.shared.aspectRatio(for: url) {
                known[index] = ratio
            } else if let assetSize = image.assetSize,
                      let ratio = engine.sourceAspectRatio(
                        width: assetSize.width,
                        height: assetSize.height
                      ) {
                known[index] = ratio
            }
        }

        guard known != aspectRatios else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            aspectRatios = known
        }
    }

    private func updateAspectRatio(index: Int, size: CGSize) {
        guard let ratio = engine.sourceAspectRatio(
            width: size.width,
            height: size.height
        ), aspectRatios[index] != ratio else { return }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            aspectRatios[index] = ratio
        }
    }
}

private struct AdaptiveSingleFeedImageLayout: Layout {
    let engine: FeedMediaLayoutEngine
    let sourceAspectRatio: CGFloat?

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let availableWidth = proposal.width ?? engine.metrics.singleImageMaxWidth
        let layout = engine.singleImageLayout(
            sourceAspectRatio: sourceAspectRatio,
            availableWidth: availableWidth
        )
        return CGSize(width: layout.width, height: layout.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

private struct HorizontalFeedMediaStrip: View {
    let images: [ImageSource]
    let aspectRatios: [Int: CGFloat]
    let engine: FeedMediaLayoutEngine
    let onImageSize: (Int, CGSize) -> Void

    private var remoteURLStrings: [String] {
        images.compactMap(\.remoteURL).map(\.absoluteString)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: engine.metrics.spacing) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    let layout = engine.multiImageItemLayout(
                        sourceAspectRatio: aspectRatios[index]
                    )

                    previewableTile(image: image, index: index)
                        .frame(width: layout.width, height: layout.height)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .frame(height: engine.metrics.multiImageRowHeight)
    }

    @ViewBuilder
    private func previewableTile(image: ImageSource, index: Int) -> some View {
        let tile = FeedMediaTile(
            source: image,
            cornerRadius: engine.metrics.cornerRadius,
            onImageSize: { onImageSize(index, $0) }
        )

        if remoteURLStrings.count == images.count, image.remoteURL != nil {
            tile.tappableImagePreview(remoteURLStrings, initialIndex: index)
        } else {
            tile
        }
    }
}

private struct FeedMediaTile: View {
    let source: ImageSource
    let cornerRadius: CGFloat
    let onImageSize: (CGSize) -> Void

    var body: some View {
        Group {
            switch source {
            case .asset(let name):
                Image(name)
                    .resizable()
                    .scaledToFill()
                    .onAppear {
                        if let size = UIImage(named: name)?.size {
                            onImageSize(size)
                        }
                    }
            case .url(let url):
                CachedRemoteImage(
                    url: url,
                    targetPixelWidth: 1_024,
                    onImageLoaded: onImageSize
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(Color.gray.opacity(0.16))
                }
            case .placeholder:
                Rectangle().fill(Color.gray.opacity(0.16))
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel(L10n.tr("Post image", "帖子图片"))
        .accessibilityAddTraits(.isImage)
    }
}

private extension ImageSource {
    var remoteURL: URL? {
        guard case .url(let url) = self else { return nil }
        return url
    }

    var assetSize: CGSize? {
        guard case .asset(let name) = self else { return nil }
        return UIImage(named: name)?.size
    }
}
