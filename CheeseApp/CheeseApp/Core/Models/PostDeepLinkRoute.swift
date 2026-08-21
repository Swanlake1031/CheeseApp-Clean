//
//  PostDeepLinkRoute.swift
//  CheeseApp
//
//  Business-neutral post link parsing contract.
//

import Foundation

struct PostDeepLinkRoute: Identifiable, Hashable {
    let kind: PostKind
    let postId: UUID
    let commentId: UUID?

    init(
        kind: PostKind,
        postId: UUID,
        commentId: UUID? = nil
    ) {
        self.kind = kind
        self.postId = postId
        self.commentId = commentId
    }

    var id: String {
        [
            kind.rawValue,
            postId.uuidString.lowercased(),
            commentId?.uuidString.lowercased()
        ]
        .compactMap { $0 }
        .joined(separator: ":")
    }

    static func parse(_ url: URL) -> Result<PostDeepLinkRoute, PostDeepLinkParseError>? {
        guard let scheme = url.scheme?.lowercased() else { return nil }

        switch scheme {
        case "https", "http":
            guard let host = url.host?.lowercased(),
                  host == "cheeseapp.org" || host == "www.cheeseapp.org" else {
                return nil
            }
            return parseWebPath(url.pathComponents)

        case "cheeseapp":
            guard url.host?.lowercased() != "auth" else { return nil }
            return parseAppPath(host: url.host?.lowercased(), pathComponents: url.pathComponents)

        default:
            return nil
        }
    }

    private static func parseWebPath(_ pathComponents: [String]) -> Result<PostDeepLinkRoute, PostDeepLinkParseError> {
        let components = sanitized(pathComponents)
        guard components.count >= 3 else {
            return .failure(.unsupportedPath)
        }
        let head = components[0].lowercased()
        guard head == "posts" || head == "open" else {
            return .failure(.unsupportedPath)
        }
        return buildRoute(kindRawValue: components[1], postIDRawValue: components[2])
    }

    private static func parseAppPath(
        host: String?,
        pathComponents: [String]
    ) -> Result<PostDeepLinkRoute, PostDeepLinkParseError> {
        let components = sanitized(pathComponents)

        if host == "post" || host == "posts" {
            guard components.count >= 2 else { return .failure(.unsupportedPath) }
            return buildRoute(kindRawValue: components[0], postIDRawValue: components[1])
        }

        guard components.count >= 3,
              components[0].lowercased() == "post" || components[0].lowercased() == "posts" else {
            return .failure(.unsupportedPath)
        }
        return buildRoute(kindRawValue: components[1], postIDRawValue: components[2])
    }

    private static func buildRoute(
        kindRawValue: String,
        postIDRawValue: String
    ) -> Result<PostDeepLinkRoute, PostDeepLinkParseError> {
        guard let kind = PostKind(remoteValue: kindRawValue) else {
            return .failure(.unsupportedKind(kindRawValue))
        }
        guard let postId = UUID(uuidString: postIDRawValue) else {
            return .failure(.invalidIdentifier(postIDRawValue))
        }
        return .success(PostDeepLinkRoute(kind: kind, postId: postId))
    }

    private static func sanitized(_ pathComponents: [String]) -> [String] {
        pathComponents.filter { $0 != "/" && !$0.isEmpty }
    }
}

enum PostDeepLinkParseError: LocalizedError {
    case unsupportedPath
    case unsupportedKind(String)
    case invalidIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPath:
            return L10n.tr(
                "This Cheese link format is not supported yet.",
                "这个 Cheese 链接格式暂时不支持。"
            )
        case .unsupportedKind(let kind):
            return L10n.tr(
                "Unsupported post type: \(kind).",
                "暂不支持的帖子类型：\(kind)。"
            )
        case .invalidIdentifier:
            return L10n.tr(
                "This Cheese link is missing a valid post identifier.",
                "这个 Cheese 链接缺少有效的帖子编号。"
            )
        }
    }
}
