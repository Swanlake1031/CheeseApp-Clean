import SwiftUI
import UIKit
import ImageIO
import Supabase

extension Notification.Name {
    static let remoteImageCacheDidLoad = Notification.Name("remoteImageCacheDidLoad")
}

struct RemoteImageRequestKey: Hashable {
    let url: URL
    let maxPixelSize: Int

    var cacheKey: NSString {
        "\(url.absoluteString)#pixels=\(maxPixelSize)" as NSString
    }
}

enum RemoteImagePurpose: Hashable {
    case feedThumbnail
    case detail
    case original

    var targetPixelWidth: Int {
        switch self {
        case .feedThumbnail:
            return 720
        case .detail:
            return 1_440
        case .original:
            return 2_048
        }
    }

    fileprivate var transformOptions: TransformOptions? {
        switch self {
        case .feedThumbnail:
            return TransformOptions(
                width: 720,
                resize: "contain",
                quality: 70
            )
        case .detail:
            return TransformOptions(
                width: 1_440,
                resize: "contain",
                quality: 82
            )
        case .original:
            return nil
        }
    }
}

struct SupabasePublicImageIdentity: Hashable {
    let bucket: String
    let objectPath: String

    init(bucket: String, objectPath: String) {
        self.bucket = bucket
        self.objectPath = objectPath
    }

    init?(publicURL: URL) {
        guard let components = URLComponents(
            url: publicURL,
            resolvingAgainstBaseURL: false
        ) else { return nil }

        let encodedSegments = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let markers = [
            ["storage", "v1", "object", "public"],
            ["storage", "v1", "render", "image", "public"]
        ]

        guard let match = markers.compactMap({ marker -> Int? in
            guard encodedSegments.count > marker.count else { return nil }
            for start in 0...(encodedSegments.count - marker.count) {
                if Array(encodedSegments[start..<(start + marker.count)]) == marker {
                    return start + marker.count
                }
            }
            return nil
        }).first,
        encodedSegments.indices.contains(match),
        match + 1 < encodedSegments.count
        else { return nil }

        let decodedBucket = encodedSegments[match]
            .removingPercentEncoding ?? encodedSegments[match]
        let decodedPath = encodedSegments[(match + 1)...]
            .map { $0.removingPercentEncoding ?? $0 }
            .joined(separator: "/")
        guard !decodedBucket.isEmpty, !decodedPath.isEmpty else { return nil }

        bucket = decodedBucket
        objectPath = decodedPath
    }

    func url(for purpose: RemoteImagePurpose) -> URL? {
        try? SupabaseManager.shared
            .storage(bucket)
            .getPublicURL(
                path: objectPath,
                options: purpose.transformOptions
            )
    }
}

enum SupabasePublicImageURLResolver {
    static func url(
        bucket: String?,
        objectPath: String?,
        fromStoredURL storedURL: String?,
        purpose: RemoteImagePurpose
    ) -> URL? {
        if let bucket,
           !bucket.isEmpty,
           let objectPath,
           !objectPath.isEmpty {
            return SupabasePublicImageIdentity(
                bucket: bucket,
                objectPath: objectPath
            ).url(for: purpose)
        }
        return url(fromStoredURL: storedURL, purpose: purpose)
    }

    static func url(
        fromStoredURL storedURL: String?,
        purpose: RemoteImagePurpose
    ) -> URL? {
        guard let storedURL,
              let sourceURL = URL(string: storedURL)
        else { return nil }

        guard let identity = SupabasePublicImageIdentity(publicURL: sourceURL) else {
            return sourceURL
        }
        return identity.url(for: purpose) ?? sourceURL
    }

    static func url(
        from sourceURL: URL,
        purpose: RemoteImagePurpose
    ) -> URL {
        guard let identity = SupabasePublicImageIdentity(publicURL: sourceURL) else {
            return sourceURL
        }
        return identity.url(for: purpose) ?? sourceURL
    }
}

enum RemoteImageLoadError: Error, Equatable {
    case httpStatus(Int)
}

enum RemoteImageRetryPolicy {
    static let maximumAutomaticAttemptCount = 3

    static func shouldRetry(_ error: Error) -> Bool {
        if let loadError = error as? RemoteImageLoadError {
            switch loadError {
            case .httpStatus(let statusCode):
                return statusCode == 408
                    || statusCode == 425
                    || statusCode == 429
                    || (500...599).contains(statusCode)
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .badURL,
                 .unsupportedURL,
                 .fileDoesNotExist,
                 .cannotDecodeContentData,
                 .appTransportSecurityRequiresSecureConnection:
                return false
            default:
                return true
            }
        }

        return true
    }

    static func delayNanoseconds(afterFailureCount failureCount: Int) -> UInt64 {
        let exponent = max(min(failureCount - 1, 4), 0)
        let seconds = min(1 << exponent, 15)
        return UInt64(seconds) * 1_000_000_000
    }

    static func canRetry(afterFailureCount failureCount: Int) -> Bool {
        failureCount < maximumAutomaticAttemptCount
    }
}

@MainActor
final class RemoteImageCache {
    static let shared = RemoteImageCache()

    private let responseCache: URLCache
    private let session: URLSession
    private let decodedImageCache = NSCache<NSString, UIImage>()
    private var decodedRequestKeys: Set<RemoteImageRequestKey> = []
    private var sourceAspectRatios: [URL: CGFloat] = [:]
    private var inFlightRequests: [RemoteImageRequestKey: Task<UIImage, Error>] = [:]
    private var inFlightDataRequests: [URL: Task<(Data, URLResponse), Error>] = [:]
    private(set) var generation: UInt64 = 0

    init(
        responseCache: URLCache = URLCache(
            memoryCapacity: 24 * 1_024 * 1_024,
            diskCapacity: 128 * 1_024 * 1_024,
            diskPath: "cheese-remote-images"
        ),
        configuration: URLSessionConfiguration = .default
    ) {
        self.responseCache = responseCache
        configuration.urlCache = responseCache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: configuration)
        decodedImageCache.countLimit = 160
        decodedImageCache.totalCostLimit = 64 * 1_024 * 1_024
    }

    func image(for url: URL, maxPixelSize: Int = 2_048) async throws -> UIImage {
        let requestKey = RemoteImageRequestKey(
            url: url,
            maxPixelSize: max(maxPixelSize, 1)
        )
        if let cachedImage = decodedImageCache.object(forKey: requestKey.cacheKey) {
            recordAspectRatio(of: cachedImage, for: url)
            return cachedImage
        }
        if let inFlightRequest = inFlightRequests[requestKey] {
            return try await inFlightRequest.value
        }

        let requestGeneration = generation
        let requestTask = Task { [self] in
            try await downloadImage(
                for: requestKey,
                requestGeneration: requestGeneration
            )
        }
        inFlightRequests[requestKey] = requestTask
        defer { inFlightRequests[requestKey] = nil }

        let image = try await requestTask.value
        let imageCost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        decodedImageCache.setObject(image, forKey: requestKey.cacheKey, cost: imageCost)
        decodedRequestKeys.insert(requestKey)
        recordAspectRatio(of: image, for: url)
        NotificationCenter.default.post(name: .remoteImageCacheDidLoad, object: url)
        return image
    }

    /// Lightweight metadata attached to the existing decoded-image cache. This
    /// does not retain another UIImage or create a competing download pipeline.
    func aspectRatio(for url: URL) -> CGFloat? {
        sourceAspectRatios[url]
    }

    func prefetch(
        _ urls: [URL],
        maxPixelSize: Int,
        limit: Int = 4,
        maxConcurrent: Int = 2
    ) {
        var seenURLs = Set<URL>()
        let uniqueURLs = urls.filter { seenURLs.insert($0).inserted }

        let candidateURLs = Array(uniqueURLs.prefix(max(limit, 0)))
        let laneCount = min(max(maxConcurrent, 0), candidateURLs.count)
        guard laneCount > 0 else { return }

        for lane in 0..<laneCount {
            let laneURLs = stride(from: lane, to: candidateURLs.count, by: laneCount)
                .map { candidateURLs[$0] }
            Task(priority: .utility) { [weak self] in
                guard let self else { return }
                for url in laneURLs {
                    guard !Task.isCancelled else { return }
                    _ = try? await self.image(for: url, maxPixelSize: maxPixelSize)
                }
            }
        }
    }

    private func downloadImage(
        for requestKey: RemoteImageRequestKey,
        requestGeneration: UInt64
    ) async throws -> UIImage {
        var attemptCount = 0
        while true {
            attemptCount += 1
            let request = URLRequest(
                url: requestKey.url,
                cachePolicy: attemptCount == 1
                    ? .returnCacheDataElseLoad
                    : .reloadIgnoringLocalCacheData
            )
            do {
                return try await loadImage(
                    for: request,
                    maxPixelSize: requestKey.maxPixelSize,
                    requestGeneration: requestGeneration
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard RemoteImageRetryPolicy.shouldRetry(error),
                      attemptCount < RemoteImageRetryPolicy.maximumAutomaticAttemptCount,
                      generation == requestGeneration
                else { throw error }

                responseCache.removeCachedResponse(for: request)
                try await Task.sleep(
                    nanoseconds: RemoteImageRetryPolicy.delayNanoseconds(
                        afterFailureCount: attemptCount
                    )
                )
            }
        }
    }

    private func loadImage(
        for request: URLRequest,
        maxPixelSize: Int,
        requestGeneration: UInt64
    ) async throws -> UIImage {
        let (data, response) = try await responseData(for: request)
        guard !Task.isCancelled,
              generation == requestGeneration
        else {
            throw CancellationError()
        }
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw RemoteImageLoadError.httpStatus(httpResponse.statusCode)
        }
        guard let image = await Self.downsampledImage(
            from: data,
            maxPixelSize: maxPixelSize
        ) else {
            throw URLError(.cannotDecodeContentData)
        }
        guard !Task.isCancelled,
              generation == requestGeneration
        else {
            throw CancellationError()
        }

        responseCache.storeCachedResponse(
            CachedURLResponse(response: response, data: data, storagePolicy: .allowed),
            for: request
        )
        return image
    }

    private func responseData(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        if request.cachePolicy != .reloadIgnoringLocalCacheData,
           let cached = responseCache.cachedResponse(for: request) {
            return (cached.data, cached.response)
        }
        if let inFlight = inFlightDataRequests[url] {
            return try await inFlight.value
        }

        let task = Task { [session] in
            try await session.data(for: request)
        }
        inFlightDataRequests[url] = task
        defer { inFlightDataRequests[url] = nil }
        return try await task.value
    }

    private static func downsampledImage(
        from data: Data,
        maxPixelSize: Int
    ) async -> UIImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    options as CFDictionary
                ) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: UIImage(cgImage: image))
            }
        }
    }

    func removeAll() {
        generation &+= 1
        inFlightRequests.values.forEach { $0.cancel() }
        inFlightRequests.removeAll()
        inFlightDataRequests.values.forEach { $0.cancel() }
        inFlightDataRequests.removeAll()
        decodedImageCache.removeAllObjects()
        decodedRequestKeys.removeAll()
        sourceAspectRatios.removeAll()
        responseCache.removeAllCachedResponses()
    }

    /// Account changes must remove cached private/signed media without
    /// cancelling public post-image requests that belong to the whole app.
    func removeAccountSensitiveContent() {
        let sensitiveKeys = decodedRequestKeys.filter {
            !Self.isPublicStorageURL($0.url)
        }
        for key in sensitiveKeys {
            decodedImageCache.removeObject(forKey: key.cacheKey)
            decodedRequestKeys.remove(key)
        }
        sourceAspectRatios = sourceAspectRatios.filter {
            Self.isPublicStorageURL($0.key)
        }

        let sensitiveRequests = inFlightRequests.keys.filter {
            !Self.isPublicStorageURL($0.url)
        }
        for key in sensitiveRequests {
            inFlightRequests[key]?.cancel()
            inFlightRequests[key] = nil
        }
        let sensitiveDataURLs = inFlightDataRequests.keys.filter {
            !Self.isPublicStorageURL($0)
        }
        for url in sensitiveDataURLs {
            inFlightDataRequests[url]?.cancel()
            inFlightDataRequests[url] = nil
        }

        // URLCache does not provide selective enumeration. Clear persisted
        // responses at the account boundary for privacy, while keeping decoded
        // public images and their active requests alive for visible feeds.
        responseCache.removeAllCachedResponses()
    }

    private static func isPublicStorageURL(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("/storage/v1/object/public/")
            || path.contains("/storage/v1/render/image/public/")
    }

    private func recordAspectRatio(of image: UIImage, for url: URL) {
        let width = image.size.width
        let height = image.size.height
        guard width.isFinite,
              height.isFinite,
              width > 0,
              height > 0
        else { return }
        sourceAspectRatios[url] = width / height
    }
}

struct CachedRemoteImage<Content: View, Placeholder: View>: View {
    let url: URL
    let targetPixelWidth: Int?
    let showsRetryButton: Bool
    let onImageLoaded: ((CGSize) -> Void)?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var loadedImage: UIImage?
    @State private var loadedURL: URL?
    @State private var activeLoadID: UUID?
    @State private var loadPhase: LoadPhase = .idle
    @State private var retryGeneration = 0

    init(
        url: URL,
        targetPixelWidth: Int? = nil,
        showsRetryButton: Bool = false,
        onImageLoaded: ((CGSize) -> Void)? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.targetPixelWidth = targetPixelWidth
        self.showsRetryButton = showsRetryButton
        self.onImageLoaded = onImageLoaded
        self.content = content
        self.placeholder = placeholder
    }

    private var requestKey: LoadKey {
        LoadKey(
            url: url,
            maxPixelSize: targetPixelWidth ?? 2_048
        )
    }

    var body: some View {
        Group {
            if let loadedImage, loadedURL == url {
                content(Image(uiImage: loadedImage))
            } else {
                ZStack {
                    placeholder()

                    if showsRetryButton, loadPhase == .failure {
                        Button {
                            loadPhase = .idle
                            retryGeneration &+= 1
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AppColors.textMuted)
                                .frame(width: 34, height: 34)
                                .background(.thinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.tr("Retry image", "重试图片"))
                    }
                }
            }
        }
        .task(id: LoadTaskKey(requestKey: requestKey, retryGeneration: retryGeneration)) {
            await loadImage()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard loadedImage == nil else { return }
            retryGeneration &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteImageCacheDidLoad)) { notification in
            guard loadedImage == nil,
                  let loadedURL = notification.object as? URL,
                  loadedURL == url
            else { return }
            retryGeneration &+= 1
        }
    }

    private func loadImage() async {
        guard !Task.isCancelled else { return }

        let loadKey = requestKey
        let loadID = UUID()
        activeLoadID = loadID
        loadPhase = .loading
        defer {
            if activeLoadID == loadID {
                activeLoadID = nil
            }
        }

        do {
            let image = try await RemoteImageCache.shared.image(
                for: loadKey.url,
                maxPixelSize: loadKey.maxPixelSize
            )
            guard !Task.isCancelled,
                  activeLoadID == loadID,
                  requestKey == loadKey
            else { return }
            loadedImage = image
            loadedURL = loadKey.url
            loadPhase = .success
            onImageLoaded?(image.size)
        } catch is CancellationError {
            guard activeLoadID == loadID else { return }
            loadPhase = .idle
        } catch {
            guard activeLoadID == loadID,
                  requestKey == loadKey
            else { return }
            loadPhase = .failure
        }
    }

    private struct LoadKey: Hashable {
        let url: URL
        let maxPixelSize: Int
    }

    private struct LoadTaskKey: Hashable {
        let requestKey: LoadKey
        let retryGeneration: Int
    }

    private enum LoadPhase: Equatable {
        case idle
        case loading
        case success
        case failure
    }
}
