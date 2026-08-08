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
        let data = try await encodeJPEGData(from: image)
        try await SupabaseManager.shared
            .storage(plan.bucket)
            .upload(
                plan.objectPath,
                data: data,
                options: FileOptions(contentType: "image/jpeg", upsert: true)
            )
        return plan.uploadedAsset
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
