import SwiftUI
import UIKit

enum CheeseAIIdentity {
    static let userID = UUID(
        uuidString: "e5983890-95ad-4b6c-814b-863bfde4e4fc"
    )!

    /// The retained account is historical data while optional Gemini is
    /// unavailable.  Keep its identifier so old records remain decodable,
    /// while preventing it from becoming a profile, mention, or other
    /// user-facing discovery surface in the launch release.
    static func isVisibleOnUserFacingSurface(_ candidateID: UUID) -> Bool {
        ReleaseCapabilities.optionalGemini || candidateID != userID
    }
}

struct AnonymousAvatarView: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(AppColors.accentStrong)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

struct CheeseAIAvatarView: View {
    let remoteURLString: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let remoteURLString,
               !remoteURLString.isEmpty,
               let url = URL(string: remoteURLString) {
                CachedRemoteImage(url: url, targetPixelWidth: 192) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    bundledAvatar
                }
            } else {
                bundledAvatar
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var bundledAvatar: some View {
        Image("CheeseAIAvatar")
            .resizable()
            .scaledToFill()
    }
}

struct AvatarCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onConfirm: (UIImage) -> Void

    private let previewImage: UIImage
    @State private var zoom: CGFloat = 1.08
    @State private var offset: CGSize = .zero
    @State private var dragOriginOffset: CGSize?
    @State private var magnificationOriginZoom: CGFloat?

    private let minimumZoom: CGFloat = 1.08
    private let maximumZoom: CGFloat = 4

    init(
        image: UIImage,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (UIImage) -> Void
    ) {
        self.image = image
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        previewImage = image.preparingThumbnail(
            of: CGSize(width: 1_600, height: 1_600)
        ) ?? image
    }

    var body: some View {
        GeometryReader { proxy in
            let canvasWidth = max(proxy.size.width - 32, 200)
            let canvasHeight = min(canvasWidth * 1.28, max(proxy.size.height - 190, 280))
            let cropSide = max(min(canvasWidth - 16, canvasHeight - 24), 160)

            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    cropCanvas(
                        canvasSize: CGSize(width: canvasWidth, height: canvasHeight),
                        cropSide: cropSide,
                        zoom: zoom,
                        offset: offset
                    )

                    Text("拖动照片调整位置，双指缩放")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .padding(.top, 18)

                    Spacer()

                    footer(
                        cropSide: cropSide,
                        zoom: zoom,
                        offset: offset
                    )
                    .padding(.bottom, max(proxy.safeAreaInsets.bottom, 18))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func footer(cropSide: CGFloat, zoom: CGFloat, offset: CGSize) -> some View {
        HStack {
            Button(action: onCancel) {
                Text("取消")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 64, minHeight: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                let croppedImage = AvatarCropRenderer.render(
                    image: image,
                    cropSide: cropSide,
                    zoom: min(max(zoom, minimumZoom), maximumZoom),
                    offset: AvatarCropGeometry.constrainedOffset(
                        offset,
                        imageSize: image.size,
                        cropSide: cropSide,
                        zoom: min(max(zoom, minimumZoom), maximumZoom)
                    )
                )
                onConfirm(croppedImage)
            } label: {
                Text("保存")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(minWidth: 92, minHeight: 48)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(AppColors.accent, in: Capsule())
        }
        .padding(.horizontal, 24)
    }

    private func cropCanvas(
        canvasSize: CGSize,
        cropSide: CGFloat,
        zoom: CGFloat,
        offset: CGSize
    ) -> some View {
        let imageSize = AvatarCropGeometry.renderedImageSize(
            imageSize: previewImage.size,
            cropSide: cropSide,
            zoom: 1
        )

        return ZStack {
            Color.black

            Image(uiImage: previewImage)
                .resizable()
                .frame(width: imageSize.width, height: imageSize.height)
                .scaleEffect(zoom)
                .offset(offset)

            Rectangle()
                .fill(.black.opacity(0.52))
                .overlay {
                    Circle()
                        .fill(.black)
                        .frame(width: cropSide, height: cropSide)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .allowsHitTesting(false)

            Circle()
                .stroke(.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: cropSide, height: cropSide)
                .allowsHitTesting(false)
        }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .clipped()
            .overlay {
                Rectangle()
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(side: cropSide, zoom: zoom))
            .simultaneousGesture(magnificationGesture(side: cropSide))
    }

    private func dragGesture(side: CGFloat, zoom: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOriginOffset == nil {
                    dragOriginOffset = offset
                }
                guard let dragOriginOffset else { return }

                offset = AvatarCropGeometry.constrainedOffset(
                    CGSize(
                        width: dragOriginOffset.width + value.translation.width,
                        height: dragOriginOffset.height + value.translation.height
                    ),
                    imageSize: image.size,
                    cropSide: side,
                    zoom: zoom
                )
            }
            .onEnded { value in
                let origin = dragOriginOffset ?? offset
                offset = AvatarCropGeometry.constrainedOffset(
                    CGSize(
                        width: origin.width + value.translation.width,
                        height: origin.height + value.translation.height
                    ),
                    imageSize: image.size,
                    cropSide: side,
                    zoom: zoom
                )
                dragOriginOffset = nil
            }
    }

    private func magnificationGesture(side: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if magnificationOriginZoom == nil {
                    magnificationOriginZoom = zoom
                }
                guard let magnificationOriginZoom else { return }

                let nextZoom = min(
                    max(magnificationOriginZoom * value, minimumZoom),
                    maximumZoom
                )
                zoom = nextZoom
                offset = AvatarCropGeometry.constrainedOffset(
                    offset,
                    imageSize: image.size,
                    cropSide: side,
                    zoom: nextZoom
                )
            }
            .onEnded { value in
                let origin = magnificationOriginZoom ?? zoom
                let settledZoom = min(max(origin * value, minimumZoom), maximumZoom)
                zoom = settledZoom
                offset = AvatarCropGeometry.constrainedOffset(
                    offset,
                    imageSize: image.size,
                    cropSide: side,
                    zoom: settledZoom
                )
                magnificationOriginZoom = nil
            }
    }
}

struct CoverImageCropView: View {
    let image: UIImage
    let aspectRatio: CGFloat
    let onCancel: () -> Void
    let onConfirm: (UIImage) -> Void

    private let previewImage: UIImage
    @State private var zoom: CGFloat = 1.02
    @State private var offset: CGSize = .zero
    @State private var dragOriginOffset: CGSize?
    @State private var magnificationOriginZoom: CGFloat?

    private let minimumZoom: CGFloat = 1.02
    private let maximumZoom: CGFloat = 4

    init(
        image: UIImage,
        aspectRatio: CGFloat,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (UIImage) -> Void
    ) {
        self.image = image
        self.aspectRatio = max(aspectRatio, 0.5)
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        previewImage = image.preparingThumbnail(
            of: CGSize(width: 1_600, height: 1_600)
        ) ?? image
    }

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(proxy.size.width - 32, 240)
            let availableHeight = max(proxy.size.height - 230, 220)
            let widthForHeight = availableHeight * aspectRatio
            let cropWidth = min(availableWidth, widthForHeight)
            let cropSize = CGSize(
                width: cropWidth,
                height: cropWidth / aspectRatio
            )

            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    cropCanvas(cropSize: cropSize)

                    Text("拖动照片调整位置，双指缩放")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .padding(.top, 18)

                    Spacer()

                    footer(cropSize: cropSize)
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom, 18))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func cropCanvas(cropSize: CGSize) -> some View {
        let renderedSize = CoverCropGeometry.renderedImageSize(
            imageSize: previewImage.size,
            cropSize: cropSize,
            zoom: 1
        )

        return ZStack {
            Color.black

            Image(uiImage: previewImage)
                .resizable()
                .frame(width: renderedSize.width, height: renderedSize.height)
                .scaleEffect(zoom)
                .offset(offset)
        }
        .frame(width: cropSize.width, height: cropSize.height)
        .clipped()
        .overlay {
            Rectangle()
                .stroke(.white.opacity(0.9), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(cropSize: cropSize))
        .simultaneousGesture(magnificationGesture(cropSize: cropSize))
    }

    private func footer(cropSize: CGSize) -> some View {
        HStack {
            Button(action: onCancel) {
                Text("取消")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 64, minHeight: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                let settledZoom = min(max(zoom, minimumZoom), maximumZoom)
                let settledOffset = CoverCropGeometry.constrainedOffset(
                    offset,
                    imageSize: image.size,
                    cropSize: cropSize,
                    zoom: settledZoom
                )
                let croppedImage = CoverCropRenderer.render(
                    image: image,
                    cropSize: cropSize,
                    zoom: settledZoom,
                    offset: settledOffset
                )
                onConfirm(croppedImage)
            } label: {
                Text("保存")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(minWidth: 92, minHeight: 48)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(AppColors.accent, in: Capsule())
        }
        .padding(.horizontal, 24)
    }

    private func dragGesture(cropSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOriginOffset == nil {
                    dragOriginOffset = offset
                }
                guard let dragOriginOffset else { return }

                offset = CoverCropGeometry.constrainedOffset(
                    CGSize(
                        width: dragOriginOffset.width + value.translation.width,
                        height: dragOriginOffset.height + value.translation.height
                    ),
                    imageSize: image.size,
                    cropSize: cropSize,
                    zoom: zoom
                )
            }
            .onEnded { value in
                let origin = dragOriginOffset ?? offset
                offset = CoverCropGeometry.constrainedOffset(
                    CGSize(
                        width: origin.width + value.translation.width,
                        height: origin.height + value.translation.height
                    ),
                    imageSize: image.size,
                    cropSize: cropSize,
                    zoom: zoom
                )
                dragOriginOffset = nil
            }
    }

    private func magnificationGesture(cropSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if magnificationOriginZoom == nil {
                    magnificationOriginZoom = zoom
                }
                guard let magnificationOriginZoom else { return }

                let nextZoom = min(
                    max(magnificationOriginZoom * value, minimumZoom),
                    maximumZoom
                )
                zoom = nextZoom
                offset = CoverCropGeometry.constrainedOffset(
                    offset,
                    imageSize: image.size,
                    cropSize: cropSize,
                    zoom: nextZoom
                )
            }
            .onEnded { value in
                let origin = magnificationOriginZoom ?? zoom
                let settledZoom = min(max(origin * value, minimumZoom), maximumZoom)
                zoom = settledZoom
                offset = CoverCropGeometry.constrainedOffset(
                    offset,
                    imageSize: image.size,
                    cropSize: cropSize,
                    zoom: settledZoom
                )
                magnificationOriginZoom = nil
            }
    }
}

private enum CoverCropGeometry {
    static func renderedImageSize(
        imageSize: CGSize,
        cropSize: CGSize,
        zoom: CGFloat
    ) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return cropSize
        }

        let aspectFillScale = max(
            cropSize.width / imageSize.width,
            cropSize.height / imageSize.height
        )
        return CGSize(
            width: imageSize.width * aspectFillScale * zoom,
            height: imageSize.height * aspectFillScale * zoom
        )
    }

    static func constrainedOffset(
        _ proposedOffset: CGSize,
        imageSize: CGSize,
        cropSize: CGSize,
        zoom: CGFloat
    ) -> CGSize {
        let renderedSize = renderedImageSize(
            imageSize: imageSize,
            cropSize: cropSize,
            zoom: zoom
        )
        let maximumX = max((renderedSize.width - cropSize.width) / 2, 0)
        let maximumY = max((renderedSize.height - cropSize.height) / 2, 0)

        return CGSize(
            width: min(max(proposedOffset.width, -maximumX), maximumX),
            height: min(max(proposedOffset.height, -maximumY), maximumY)
        )
    }
}

private enum CoverCropRenderer {
    static func render(
        image: UIImage,
        cropSize: CGSize,
        zoom: CGFloat,
        offset: CGSize,
        outputWidth: CGFloat = 1_600
    ) -> UIImage {
        let renderedSize = CoverCropGeometry.renderedImageSize(
            imageSize: image.size,
            cropSize: cropSize,
            zoom: zoom
        )
        let scale = outputWidth / cropSize.width
        let outputSize = CGSize(
            width: outputWidth,
            height: cropSize.height * scale
        )
        let drawRect = CGRect(
            x: ((cropSize.width - renderedSize.width) / 2 + offset.width) * scale,
            y: ((cropSize.height - renderedSize.height) / 2 + offset.height) * scale,
            width: renderedSize.width * scale,
            height: renderedSize.height * scale
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            UIColor.black.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: outputSize))
            image.draw(in: drawRect)
        }
    }
}

private enum AvatarCropGeometry {
    static func renderedImageSize(
        imageSize: CGSize,
        cropSide: CGFloat,
        zoom: CGFloat
    ) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: cropSide, height: cropSide)
        }

        let aspectFillScale = max(cropSide / imageSize.width, cropSide / imageSize.height)
        return CGSize(
            width: imageSize.width * aspectFillScale * zoom,
            height: imageSize.height * aspectFillScale * zoom
        )
    }

    static func constrainedOffset(
        _ proposedOffset: CGSize,
        imageSize: CGSize,
        cropSide: CGFloat,
        zoom: CGFloat
    ) -> CGSize {
        let renderedSize = renderedImageSize(
            imageSize: imageSize,
            cropSide: cropSide,
            zoom: zoom
        )
        let maximumX = max((renderedSize.width - cropSide) / 2, 0)
        let maximumY = max((renderedSize.height - cropSide) / 2, 0)

        return CGSize(
            width: min(max(proposedOffset.width, -maximumX), maximumX),
            height: min(max(proposedOffset.height, -maximumY), maximumY)
        )
    }

}

private enum AvatarCropRenderer {
    static func render(
        image: UIImage,
        cropSide: CGFloat,
        zoom: CGFloat,
        offset: CGSize,
        outputSide: CGFloat = 1_024
    ) -> UIImage {
        let renderedSize = AvatarCropGeometry.renderedImageSize(
            imageSize: image.size,
            cropSide: cropSide,
            zoom: zoom
        )
        let scale = outputSide / cropSide
        let drawRect = CGRect(
            x: ((cropSide - renderedSize.width) / 2 + offset.width) * scale,
            y: ((cropSide - renderedSize.height) / 2 + offset.height) * scale,
            width: renderedSize.width * scale,
            height: renderedSize.height * scale
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(
            size: CGSize(width: outputSide, height: outputSide),
            format: format
        ).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: outputSide, height: outputSide))
            image.draw(in: drawRect)
        }
    }
}

private struct TapToPreviewAvatarModifier: ViewModifier {
    let urlString: String?
    @State private var showingPreview = false

    private var imageURL: URL? {
        guard let urlString, !urlString.isEmpty else { return nil }
        return URL(string: urlString)
    }

    func body(content: Content) -> some View {
        content
            .contentShape(Circle())
            .highPriorityGesture(
                TapGesture().onEnded {
                    guard imageURL != nil else { return }
                    setPreviewPresented(true)
                }
            )
            .fullScreenCover(isPresented: $showingPreview) {
                if let imageURL {
                    RemoteAvatarPreviewView(
                        imageURL: imageURL,
                        onDismiss: { setPreviewPresented(false) }
                    )
                        .presentationBackground(.clear)
                }
            }
    }

    private func setPreviewPresented(_ isPresented: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            showingPreview = isPresented
        }
    }
}

private struct RemoteAvatarPreviewView: View {
    let imageURL: URL
    let onDismiss: () -> Void

    @State private var isVisible = false
    @State private var isClosing = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width - 72, 320)

            ZStack {
                Color.black
                    .opacity(isVisible ? 0.72 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                CachedRemoteImage(url: imageURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    ProgressView()
                        .tint(.white)
                }
                .frame(width: side, height: side)
                .clipShape(Circle())
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().stroke(.white.opacity(0.2), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                .scaleEffect(isVisible ? 1 : 0.68)
                .opacity(isVisible ? 1 : 0)

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            close()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white.opacity(0.88))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(16)
                .opacity(isVisible ? 1 : 0)
            }
        }
        .background(Color.clear)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                isVisible = true
            }
        }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(
            .easeOut(duration: 0.16),
            completionCriteria: .logicallyComplete
        ) {
            isVisible = false
        } completion: {
            onDismiss()
        }
    }
}

extension View {
    func tappableAvatarPreview(_ urlString: String?) -> some View {
        modifier(TapToPreviewAvatarModifier(urlString: urlString))
    }
}

struct OfficialAccountAvatar: View {
    let size: CGFloat

    var body: some View {
        Image("CheeseAppLogo")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.tr("Cheese Official avatar", "奶酪官方头像")))
    }
}

struct OfficialVerificationBadge: View {
    enum Style {
        case icon
        case label
    }

    var style: Style = .label

    var body: some View {
        HStack(spacing: 3) {
            Text("🧀")
                .font(.system(size: style == .label ? 12 : 14))

            if style == .label {
                Text(L10n.tr("Cheese Official", "奶酪官方"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
            }
        }
        .padding(.horizontal, style == .label ? 7 : 0)
        .frame(height: style == .label ? 22 : nil)
        .background {
            if style == .label {
                Capsule().fill(AppColors.accent.opacity(0.2))
            }
        }
        .overlay {
            if style == .label {
                Capsule()
                    .stroke(AppColors.accentStrong.opacity(0.28), lineWidth: 1)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.tr("Cheese Official", "奶酪官方")))
    }
}

struct McMasterStudentBadge: View {
    enum Style {
        case icon
        case label
    }

    var style: Style = .icon

    private let maroon = Color(red: 122 / 255, green: 0, blue: 60 / 255)
    private let gold = Color(red: 253 / 255, green: 191 / 255, blue: 87 / 255)

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Image(systemName: "shield.fill")
                    .foregroundStyle(maroon)
                Text("M")
                    .font(.system(size: 7, weight: .black, design: .rounded))
                    .foregroundStyle(gold)
                    .offset(y: -0.5)
            }
            .font(.system(size: style == .label ? 15 : 14, weight: .semibold))

            if style == .label {
                Text("麦马学生")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(maroon)
            }
        }
        .padding(.horizontal, style == .label ? 7 : 0)
        .padding(.vertical, style == .label ? 4 : 0)
        .background {
            if style == .label {
                Capsule().fill(gold.opacity(0.24))
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("麦马学生认证"))
    }
}
