//
//  ImageUploadService.swift
//  CheeseApp
//
//  🎯 图片上传服务
//

import SwiftUI
import Supabase

struct UploadedImageAsset: Hashable {
    let publicURL: String
    let bucket: String
    let path: String
}

struct PreparedPostImage: Sendable {
    let data: Data
    let contentType: String
    let pixelSize: CGSize
    let preservesTransparency: Bool
}

struct PostImageUploadPlan: Hashable, Encodable {
    let bucket: String
    let objectPath: String
    let publicURL: String
    let orderIndex: Int

    enum CodingKeys: String, CodingKey {
        case bucket
        case objectPath = "object_path"
        case publicURL = "url"
        case orderIndex = "order_index"
    }

    var uploadedAsset: UploadedImageAsset {
        UploadedImageAsset(
            publicURL: publicURL,
            bucket: bucket,
            path: objectPath
        )
    }
}

/// Exact, database-owned cleanup obligation for post media. This is a shared
/// Storage data contract only; each feature owns when it creates and retries
/// these obligations.
struct PostMediaCleanupItem: Codable, Identifiable, Hashable {
    let id: UUID
    let postImageID: UUID?
    let postID: UUID?
    let bucket: String?
    let objectPath: String?
    let storedURL: String
    let status: String
    let reason: String?
    let candidateCount: Int?
    let attemptCount: Int?
    let lastErrorCode: String?

    enum CodingKeys: String, CodingKey {
        case id = "cleanup_id"
        case postImageID = "post_image_id"
        case postID = "post_id"
        case bucket
        case objectPath = "object_path"
        case storedURL = "stored_url"
        case status
        case reason
        case candidateCount = "candidate_count"
        case attemptCount = "attempt_count"
        case lastErrorCode = "last_error_code"
    }

    var uploadedAsset: UploadedImageAsset? {
        guard let bucket, let objectPath else { return nil }
        return UploadedImageAsset(
            publicURL: storedURL,
            bucket: bucket,
            path: objectPath
        )
    }
}

class ImageUploadService {
    static let shared = ImageUploadService()
    
    private init() {}

    func uploadAvatar(_ image: UIImage, userId: UUID) async throws -> String {
        try await uploadImage(image, to: StorageBuckets.avatars, userIdOverride: userId)
    }

    func uploadProfileCover(
        _ image: UIImage,
        userId: UUID
    ) async throws -> UploadedImageAsset {
        let data = try await encodeProfileCoverJPEGData(from: image)
        let normalizedUserID = userId.uuidString.lowercased()
        let path = "\(normalizedUserID)/covers/\(UUID().uuidString.lowercased()).jpg"
        let publicURL = try SupabaseManager.shared
            .storage(StorageBuckets.avatars)
            .getPublicURL(path: path)

        try await SupabaseManager.shared
            .storage(StorageBuckets.avatars)
            .upload(
                path,
                data: data,
                options: FileOptions(contentType: "image/jpeg")
            )

        return UploadedImageAsset(
            publicURL: publicURL.absoluteString,
            bucket: StorageBuckets.avatars,
            path: path
        )
    }

    func deleteOwnedProfileCover(
        at publicURLString: String?,
        userId: UUID
    ) async throws {
        guard let publicURLString,
              let publicURL = URL(string: publicURLString),
              let identity = SupabasePublicImageIdentity(publicURL: publicURL),
              identity.bucket == StorageBuckets.avatars
        else { return }

        let expectedPrefix = "\(userId.uuidString.lowercased())/covers/"
        guard identity.objectPath.lowercased().hasPrefix(expectedPrefix) else { return }

        _ = try await SupabaseManager.shared
            .storage(identity.bucket)
            .remove(paths: [identity.objectPath])
    }
    
    func uploadImage(_ image: UIImage, to bucket: String, userIdOverride: UUID? = nil) async throws -> String {
        (try await uploadImageAsset(
            image,
            to: bucket,
            userIdOverride: userIdOverride
        )).publicURL
    }

    func uploadImageAsset(
        _ image: UIImage,
        to bucket: String,
        userIdOverride: UUID? = nil
    ) async throws -> UploadedImageAsset {
        let data = try await encodeJPEGData(from: image)

        let userId: String
        if let userIdOverride {
            userId = userIdOverride.uuidString.lowercased()
        } else {
            do {
                userId = try await AuthService.shared.requireAuthUserId().uuidString.lowercased()
            } catch {
                throw NSError(
                    domain: "",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: L10n.tr("Please sign in again before uploading images", "上传图片前请重新登入")]
                )
            }
        }
        let path = "\(userId)/\(UUID().uuidString).jpg"
        let publicURL = try SupabaseManager.shared
            .storage(bucket)
            .getPublicURL(path: path)

        try await SupabaseManager.shared
            .storage(bucket)
            .upload(
                path,
                data: data,
                options: FileOptions(contentType: "image/jpeg")
            )

        return UploadedImageAsset(
            publicURL: publicURL.absoluteString,
            bucket: bucket,
            path: path
        )
    }

    func deleteUploadedImageAsset(_ asset: UploadedImageAsset) async throws {
        _ = try await SupabaseManager.shared
            .storage(asset.bucket)
            .remove(paths: [asset.path])
    }

    /// Uploads bytes to an exact private object identity. Unlike the generic
    /// public-media helper, this never creates or returns a public URL.
    func uploadPrivateImageAsset(
        _ image: UIImage,
        to bucket: String,
        path: String
    ) async throws -> UploadedImageAsset {
        let data = try await encodeJPEGData(from: image)
        try await SupabaseManager.shared
            .storage(bucket)
            .upload(
                path,
                data: data,
                options: FileOptions(contentType: "image/jpeg")
            )

        return UploadedImageAsset(
            publicURL: "",
            bucket: bucket,
            path: path
        )
    }

    /// Produces deterministic, exact Storage identities before any bytes are
    /// uploaded. The feature workflow records these plans in the database
    /// first, so an interrupted upload never becomes an untracked object.
    func makePostImageUploadPlans(
        imageCount: Int,
        userID: UUID,
        postID: UUID,
        operationID: UUID
    ) throws -> [PostImageUploadPlan] {
        guard imageCount >= 0, imageCount <= 6 else {
            throw NSError(
                domain: "PostMedia",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "A post can contain at most six images."]
            )
        }

        let prefix = [
            userID.uuidString.lowercased(),
            "posts",
            postID.uuidString.lowercased(),
            operationID.uuidString.lowercased()
        ].joined(separator: "/")

        return try (0..<imageCount).map { orderIndex in
            let objectPath = "\(prefix)/\(String(format: "%03d", orderIndex)).jpg"
            let publicURL = try SupabaseManager.shared
                .storage(StorageBuckets.postImages)
                .getPublicURL(path: objectPath)

            return PostImageUploadPlan(
                bucket: StorageBuckets.postImages,
                objectPath: objectPath,
                publicURL: publicURL.absoluteString,
                orderIndex: orderIndex
            )
        }
    }

    /// Uploads one already-recorded post-media plan. Upsert is intentional:
    /// retrying the same idempotent operation rewrites the same object rather
    /// than allocating a second path.
    func uploadPostImage(
        _ image: UIImage,
        plan: PostImageUploadPlan
    ) async throws -> UploadedImageAsset {
        let preparedImage = try await preparePostImageForUpload(image)
        try await SupabaseManager.shared
            .storage(plan.bucket)
            .upload(
                plan.objectPath,
                data: preparedImage.data,
                options: FileOptions(
                    contentType: preparedImage.contentType,
                    upsert: true
                )
            )
        return plan.uploadedAsset
    }

    /// Post media is normalized and encoded away from the main actor. The
    /// staged `.jpg` object name is retained because it is part of the existing
    /// database-owned ownership contract; Storage uses the explicit MIME type.
    func preparePostImageForUpload(_ image: UIImage) async throws -> PreparedPostImage {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.preparePostImage(image))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func encodeJPEGData(from image: UIImage) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let preparedImage = Self.imageByConstrainingLongestEdge(
                    image,
                    maximumDimension: 2_048
                )
                guard let data = preparedImage.jpegData(compressionQuality: 0.82) else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "",
                            code: 400,
                            userInfo: [NSLocalizedDescriptionKey: "Unable to process image data"]
                        )
                    )
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    private func encodeProfileCoverJPEGData(from image: UIImage) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let preparedImage = Self.renderedImage(
                    image,
                    maximumDimension: 1_600,
                    opaque: true
                )
                let qualities: [CGFloat] = [0.80, 0.76, 0.72]
                var smallestData: Data?

                for quality in qualities {
                    guard let data = preparedImage.jpegData(compressionQuality: quality) else {
                        continue
                    }
                    smallestData = data
                    if data.count <= 1_000_000 {
                        continuation.resume(returning: data)
                        return
                    }
                }

                guard let smallestData else {
                    continuation.resume(throwing: Self.imageProcessingError)
                    return
                }
                continuation.resume(returning: smallestData)
            }
        }
    }

    private static func imageByConstrainingLongestEdge(
        _ image: UIImage,
        maximumDimension: CGFloat
    ) -> UIImage {
        let longestEdge = max(image.size.width, image.size.height)
        guard longestEdge > maximumDimension, longestEdge > 0 else { return image }

        let scale = maximumDimension / longestEdge
        let targetSize = CGSize(
            width: max(1, floor(image.size.width * scale)),
            height: max(1, floor(image.size.height * scale))
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func preparePostImage(_ image: UIImage) throws -> PreparedPostImage {
        guard image.size.width > 0, image.size.height > 0 else {
            throw imageProcessingError
        }

        if imageRequiresTransparency(image) {
            let prepared = renderedImage(
                image,
                maximumDimension: 2_048,
                opaque: false
            )
            guard let data = prepared.pngData() else { throw imageProcessingError }
            return PreparedPostImage(
                data: data,
                contentType: "image/png",
                pixelSize: prepared.size,
                preservesTransparency: true
            )
        }

        let maximumDimensions: [CGFloat] = [2_304, 2_048, 1_792, 1_536, 1_280]
        let qualities: [CGFloat] = [0.80, 0.78, 0.76, 0.75]
        let preferredMaximumByteCount = 1_000_000
        var smallestCandidate: (data: Data, size: CGSize)?
        var previousSize: CGSize?

        for maximumDimension in maximumDimensions {
            let prepared = renderedImage(
                image,
                maximumDimension: maximumDimension,
                opaque: true
            )
            if prepared.size == previousSize { continue }
            previousSize = prepared.size

            for quality in qualities {
                guard let data = prepared.jpegData(compressionQuality: quality) else {
                    throw imageProcessingError
                }
                if smallestCandidate == nil || data.count < smallestCandidate!.data.count {
                    smallestCandidate = (data, prepared.size)
                }
                if data.count <= preferredMaximumByteCount {
                    return PreparedPostImage(
                        data: data,
                        contentType: "image/jpeg",
                        pixelSize: prepared.size,
                        preservesTransparency: false
                    )
                }
            }
        }

        guard let smallestCandidate else { throw imageProcessingError }
        return PreparedPostImage(
            data: smallestCandidate.data,
            contentType: "image/jpeg",
            pixelSize: smallestCandidate.size,
            preservesTransparency: false
        )
    }

    /// Drawing every selected image into a fresh, scale-1 bitmap applies the
    /// UIImage orientation and avoids uploading camera-sized decoded buffers.
    private static func renderedImage(
        _ image: UIImage,
        maximumDimension: CGFloat,
        opaque: Bool
    ) -> UIImage {
        let longestEdge = max(image.size.width, image.size.height)
        let scale = longestEdge > maximumDimension
            ? maximumDimension / longestEdge
            : 1
        let targetSize = CGSize(
            width: max(1, floor(image.size.width * scale)),
            height: max(1, floor(image.size.height * scale))
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            if opaque {
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: targetSize))
            }
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// Preserve PNG only when sampled pixels actually contain transparency,
    /// rather than merely because the source bitmap has an alpha channel.
    private static func imageRequiresTransparency(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        switch cgImage.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            break
        default:
            return false
        }

        let sampleWidth = min(cgImage.width, 128)
        let sampleHeight = min(cgImage.height, 128)
        guard sampleWidth > 0, sampleHeight > 0 else { return false }
        let bytesPerRow = sampleWidth * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * sampleHeight)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return false }
        context.interpolationQuality = .low
        context.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight)
        )
        return stride(from: 3, to: pixels.count, by: 4).contains {
            pixels[$0] < 250
        }
    }

    private static var imageProcessingError: NSError {
        NSError(
            domain: "PostImageProcessing",
            code: 400,
            userInfo: [NSLocalizedDescriptionKey: "Unable to process image data"]
        )
    }

    func uploadImages(_ images: [UIImage], to bucket: String) async throws -> [String] {
        var urls: [String] = []
        for image in images {
            let url = try await uploadImage(image, to: bucket, userIdOverride: nil)
            urls.append(url)
        }
        return urls
    }

    func attachImages(_ images: [UIImage], toPostId postId: UUID) async throws -> [String] {
        guard !images.isEmpty else { return [] }

        let urls = try await uploadImages(images, to: StorageBuckets.postImages)
        let payload = urls.enumerated().map { index, url in
            PostImageInsert(postId: postId, url: url, orderIndex: index)
        }

        try await SupabaseManager.shared
            .database(Tables.postImages)
            .insert(payload)
            .execute()

        return urls
    }
}

private struct PostImageInsert: Encodable {
    let postId: UUID
    let url: String
    let orderIndex: Int

    enum CodingKeys: String, CodingKey {
        case postId = "post_id"
        case url
        case orderIndex = "order_index"
    }
}
