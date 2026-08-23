import SwiftUI
import UIKit
import ImageIO

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

enum RemoteImageLoadError: Error, Equatable {
    case httpStatus(Int)
}

enum RemoteImageRetryPolicy {
    static let maximumAutomaticAttemptCount = 8

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
    private var sourceAspectRatios: [URL: CGFloat] = [:]
    private var inFlightRequests: [RemoteImageRequestKey: Task<UIImage, Error>] = [:]
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
        let request = URLRequest(
            url: requestKey.url,
            cachePolicy: .returnCacheDataElseLoad
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
            guard RemoteImageRetryPolicy.shouldRetry(error) else {
                throw error
            }
            guard generation == requestGeneration else {
                throw CancellationError()
            }
            responseCache.removeCachedResponse(for: request)
            let retryRequest = URLRequest(
                url: requestKey.url,
                cachePolicy: .reloadIgnoringLocalCacheData
            )
            return try await loadImage(
                for: retryRequest,
                maxPixelSize: requestKey.maxPixelSize,
                requestGeneration: requestGeneration
            )
        }
    }

    private func loadImage(
        for request: URLRequest,
        maxPixelSize: Int,
        requestGeneration: UInt64
    ) async throws -> UIImage {
        let (data, response) = try await session.data(for: request)
        guard generation == requestGeneration else {
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
        guard generation == requestGeneration else {
            throw CancellationError()
        }

        responseCache.storeCachedResponse(
            CachedURLResponse(response: response, data: data, storagePolicy: .allowed),
            for: request
        )
        return image
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
        decodedImageCache.removeAllObjects()
        sourceAspectRatios.removeAll()
        responseCache.removeAllCachedResponses()
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
    let onImageLoaded: ((CGSize) -> Void)?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var loadedImage: UIImage?
    @State private var loadedURL: URL?
    @State private var activeLoadID: UUID?

    init(
        url: URL,
        targetPixelWidth: Int? = nil,
        onImageLoaded: ((CGSize) -> Void)? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.targetPixelWidth = targetPixelWidth
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
                placeholder()
            }
        }
        .task(id: requestKey) {
            await loadImage()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard loadedImage == nil else { return }
            Task { await loadImage() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteImageCacheDidLoad)) { notification in
            guard loadedImage == nil,
                  let loadedURL = notification.object as? URL,
                  loadedURL == url
            else { return }
            Task { await loadImage() }
        }
    }

    private func loadImage() async {
        guard !Task.isCancelled else { return }

        let loadKey = requestKey
        let loadID = UUID()
        activeLoadID = loadID
        defer {
            if activeLoadID == loadID {
                activeLoadID = nil
            }
        }

        var failureCount = 0
        while !Task.isCancelled {
            guard activeLoadID == loadID,
                  requestKey == loadKey
            else { return }

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
                onImageLoaded?(image.size)
                return
            } catch is CancellationError {
                return
            } catch {
                guard RemoteImageRetryPolicy.shouldRetry(error),
                      activeLoadID == loadID,
                      requestKey == loadKey
                else { return }

                failureCount += 1
                guard RemoteImageRetryPolicy.canRetry(
                    afterFailureCount: failureCount
                ) else { return }
                do {
                    try await Task.sleep(
                        nanoseconds: RemoteImageRetryPolicy.delayNanoseconds(
                            afterFailureCount: failureCount
                        )
                    )
                } catch {
                    return
                }
                guard activeLoadID == loadID else { return }
            }
        }
    }

    private struct LoadKey: Hashable {
        let url: URL
        let maxPixelSize: Int
    }
}
