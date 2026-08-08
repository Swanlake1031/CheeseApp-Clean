//
//  PostSharePayload.swift
//  CheeseApp
//
//  Business-neutral share link and metadata contract.
//

import Foundation

enum CheeseShareConfiguration {
    static let canonicalBaseURL = URL(string: "https://cheeseapp.org")!
}

struct PostSharePayload: Identifiable, Equatable {
    let kind: PostKind
    let postId: UUID
    let title: String
    let subtitle: String?
    let summary: String?
    let imageURL: URL?
    let imageURLs: [URL]
    let canonicalURL: URL
    let deepLinkURL: URL

    var id: String {
        "\(kind.rawValue):\(postId.uuidString.lowercased())"
    }

    var previewTitle: String {
        "\(kind.displayName) · \(title)"
    }

    var composedText: String {
        var lines: [String] = [title]
        if let subtitle {
            lines.append(subtitle)
        }
        if let summary {
            lines.append(summary)
        }
        return lines.joined(separator: "\n")
    }

    static func makeCanonicalURL(kind: PostKind, postId: UUID) -> URL {
        CheeseShareConfiguration.canonicalBaseURL
            .appendingPathComponent("posts")
            .appendingPathComponent(kind.rawValue)
            .appendingPathComponent(postId.uuidString.lowercased())
    }

    static func makeDeepLink(kind: PostKind, postId: UUID) -> URL {
        URL(string: "cheeseapp://post/\(kind.rawValue)/\(postId.uuidString.lowercased())")!
    }

    init(
        kind: PostKind,
        postId: UUID,
        title: String,
        subtitle: String? = nil,
        summary: String? = nil,
        imageURL: URL? = nil,
        imageURLs: [URL] = [],
        canonicalURL: URL? = nil,
        deepLinkURL: URL? = nil
    ) {
        let normalizedPrimaryImageURL = Self.normalizedURL(imageURL, allowDeepLink: false)
        let normalizedImageURLs = imageURLs.compactMap { Self.normalizedURL($0, allowDeepLink: false) }
        let mergedImageURLs = Self.uniqued(([normalizedPrimaryImageURL].compactMap { $0 }) + normalizedImageURLs)
        let resolvedCanonicalURL = Self.normalizedURL(
            canonicalURL ?? Self.makeCanonicalURL(kind: kind, postId: postId),
            allowDeepLink: false
        ) ?? Self.makeCanonicalURL(kind: kind, postId: postId)
        let resolvedDeepLinkURL = Self.normalizedURL(
            deepLinkURL ?? Self.makeDeepLink(kind: kind, postId: postId),
            allowDeepLink: true
        ) ?? Self.makeDeepLink(kind: kind, postId: postId)

        self.kind = kind
        self.postId = postId
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subtitle = Self.normalizedLine(subtitle)
        self.summary = Self.normalizedLine(summary).map { Self.truncated($0, limit: 140) }
        self.imageURL = mergedImageURLs.first
        self.imageURLs = mergedImageURLs
        self.canonicalURL = resolvedCanonicalURL
        self.deepLinkURL = resolvedDeepLinkURL
    }

    private static func normalizedLine(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func truncated(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "..."
    }

    private static func normalizedURL(_ value: URL?, allowDeepLink: Bool) -> URL? {
        guard let value, let scheme = value.scheme?.lowercased() else { return nil }
        if scheme == "https" || scheme == "http" { return value }
        if allowDeepLink && scheme == "cheeseapp" { return value }
        return nil
    }

    private static func uniqued(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }
}
