//
//  ChatMessage.swift
//  CheeseApp
//
//  🎯 Feature-owned 聊天消息模型
//

import Foundation

struct Message: Codable, Identifiable {
    let id: UUID
    let conversationId: UUID
    let senderId: UUID?
    let content: String
    let messageType: String
    let metadata: MessageMetadata?
    var isRead: Bool
    let createdAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case senderId = "sender_id"
        case content
        case messageType = "message_type"
        case metadata
        case isRead = "is_read"
        case createdAt = "created_at"
    }
}

struct MessageMetadata: Codable, Hashable {
    let imageURL: String?
    let sharedPostCard: SharedPostCardMetadata?
    let postContactCard: PostContactCardMetadata?
    let secondhandTransactionEvent: SecondhandTransactionEventMetadata?
    let quotedMessage: QuotedMessageMetadata?
    let imageBucket: String?
    let imageObjectPath: String?
    let imageScope: String?
    let imageScopeID: UUID?

    init(
        imageURL: String?,
        sharedPostCard: SharedPostCardMetadata?,
        postContactCard: PostContactCardMetadata?,
        secondhandTransactionEvent: SecondhandTransactionEventMetadata? = nil,
        quotedMessage: QuotedMessageMetadata? = nil,
        imageBucket: String? = nil,
        imageObjectPath: String? = nil,
        imageScope: String? = nil,
        imageScopeID: UUID? = nil
    ) {
        self.imageURL = imageURL
        self.sharedPostCard = sharedPostCard
        self.postContactCard = postContactCard
        self.secondhandTransactionEvent = secondhandTransactionEvent
        self.quotedMessage = quotedMessage
        self.imageBucket = imageBucket
        self.imageObjectPath = imageObjectPath
        self.imageScope = imageScope
        self.imageScopeID = imageScopeID
    }

    var chatMediaReference: ChatMediaReference? {
        guard let imageBucket,
              let imageObjectPath,
              let imageScope,
              let scope = ChatMediaScope(rawValue: imageScope),
              let imageScopeID
        else { return nil }

        let reference = ChatMediaReference(
            bucket: imageBucket,
            objectPath: imageObjectPath,
            scope: scope,
            scopeID: imageScopeID
        )
        return reference.hasValidContract ? reference : nil
    }

    enum CodingKeys: String, CodingKey {
        case imageURL = "image_url"
        case sharedPostCard = "shared_post_card"
        case postContactCard = "post_contact_card"
        case secondhandTransactionEvent = "secondhand_transaction_event"
        case quotedMessage = "quoted_message"
        case imageBucket = "image_bucket"
        case imageObjectPath = "image_object_path"
        case imageScope = "image_scope"
        case imageScopeID = "image_scope_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(imageURL, forKey: .imageURL)
        try container.encodeIfPresent(sharedPostCard, forKey: .sharedPostCard)
        try container.encodeIfPresent(postContactCard, forKey: .postContactCard)
        try container.encodeIfPresent(
            secondhandTransactionEvent,
            forKey: .secondhandTransactionEvent
        )
        try container.encodeIfPresent(quotedMessage, forKey: .quotedMessage)
        try container.encodeIfPresent(imageBucket, forKey: .imageBucket)
        try container.encodeIfPresent(imageObjectPath, forKey: .imageObjectPath)
        try container.encodeIfPresent(imageScope, forKey: .imageScope)

        // Foundation encodes UUID values with uppercase hexadecimal digits.
        // Chat media paths and the database contract are canonical lowercase,
        // so persist the same canonical representation in message metadata.
        if let imageScopeID {
            try container.encode(
                imageScopeID.uuidString.lowercased(),
                forKey: .imageScopeID
            )
        }
    }
}

struct SecondhandTransactionEventMetadata: Codable, Hashable {
    let kind: SecondhandPurchaseIntentStatus
    let listingId: UUID
    let intentId: UUID

    enum CodingKeys: String, CodingKey {
        case kind
        case listingId = "listing_id"
        case intentId = "intent_id"
    }
}

enum SecondhandPurchaseIntentStatus: String, Codable, Hashable {
    case active
    case buyerCancelled = "buyer_cancelled"
    case completed
    case listingSold = "listing_sold"
    case sellerStopped = "seller_stopped"

    var displayTitle: String {
        switch self {
        case .active: return L10n.tr("Transaction in progress", "交易进行中")
        case .buyerCancelled: return L10n.tr("Purchase intent cancelled", "购买意向已取消")
        case .completed: return L10n.tr("Transaction completed", "交易已完成")
        case .listingSold: return L10n.tr("This item has been sold", "该商品已售出")
        case .sellerStopped: return L10n.tr("Seller stopped selling", "卖家已停止出售")
        }
    }

    var isActive: Bool { self == .active }
}

enum SecondhandTransactionViewerRole: String, Codable, Hashable {
    case buyer
    case seller
}

struct SecondhandChatPurchaseIntent: Codable, Identifiable, Hashable {
    let id: UUID
    let listingId: UUID
    let conversationId: UUID
    let sellerId: UUID
    let buyerId: UUID
    let status: SecondhandPurchaseIntentStatus
    let startedAt: Date
    let updatedAt: Date
    let listingTitle: String
    let listingStatus: String
    let listingIsPrivate: Bool
    let viewerRole: SecondhandTransactionViewerRole

    enum CodingKeys: String, CodingKey {
        case id
        case listingId = "listing_id"
        case conversationId = "conversation_id"
        case sellerId = "seller_id"
        case buyerId = "buyer_id"
        case status
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case listingTitle = "listing_title"
        case listingStatus = "listing_status"
        case listingIsPrivate = "listing_is_private"
        case viewerRole = "viewer_role"
    }
}

struct SecondhandActiveBuyer: Codable, Identifiable, Hashable {
    let buyerId: UUID
    let buyerName: String
    let buyerAvatar: String?
    let conversationId: UUID
    let startedAt: Date

    var id: UUID { buyerId }

    enum CodingKeys: String, CodingKey {
        case buyerId = "buyer_id"
        case buyerName = "buyer_name"
        case buyerAvatar = "buyer_avatar"
        case conversationId = "conversation_id"
        case startedAt = "started_at"
    }
}

struct QuotedMessageMetadata: Codable, Hashable {
    let messageId: UUID
    let senderName: String
    let preview: String
    let messageType: String

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case senderName = "sender_name"
        case preview
        case messageType = "message_type"
    }

    var displayPreview: String {
        messageType == "image" ? L10n.tr("Photo", "图片") : preview
    }
}

enum ChatMessageReportTarget: Identifiable, Hashable {
    case direct(UUID)
    case group(UUID)

    var id: String {
        switch self {
        case .direct(let messageID): return "direct:\(messageID.uuidString)"
        case .group(let messageID): return "group:\(messageID.uuidString)"
        }
    }
}

enum ChatMediaScope: String, Codable, Hashable {
    case direct
    case group
}

struct ChatMediaReference: Codable, Hashable {
    let bucket: String
    let objectPath: String
    let scope: ChatMediaScope
    let scopeID: UUID

    var hasValidContract: Bool {
        guard bucket == StorageBuckets.chatImages else { return false }

        let parts = objectPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == Substring(scope.rawValue),
              parts[1].lowercased() == scopeID.uuidString.lowercased(),
              UUID(uuidString: String(parts[2])) != nil
        else { return false }

        let filename = String(parts[3])
        guard filename.hasSuffix(".jpg") else { return false }
        return UUID(uuidString: String(filename.dropLast(4))) != nil
    }

    func belongs(to expectedScope: ChatMediaScope, id: UUID) -> Bool {
        hasValidContract && scope == expectedScope && scopeID == id
    }
}

struct PostContactCardMetadata: Codable, Hashable {
    let postKind: String
    let postId: UUID?
    let title: String
    let subtitle: String?
    let summary: String?
    let imageURL: String?
    let requesterUserId: UUID?
    let requesterName: String?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case postKind = "post_kind"
        case postId = "post_id"
        case title
        case subtitle
        case summary
        case imageURL = "image_url"
        case requesterUserId = "requester_user_id"
        case requesterName = "requester_name"
        case note
    }
}

struct SharedPostCardMetadata: Codable, Hashable {
    let postKind: String
    let postId: UUID?
    let title: String
    let subtitle: String?
    let summary: String?
    let imageURL: String?
    let authorName: String?

    enum CodingKeys: String, CodingKey {
        case postKind = "post_kind"
        case postId = "post_id"
        case title
        case subtitle
        case summary
        case imageURL = "image_url"
        case authorName = "author_name"
    }
}

// ============================================
// 会话列表模型（来自 RPC: get_user_conversations）
// ============================================

struct ChatConversationPreview: Codable, Identifiable, Hashable {
    let id: UUID
    let otherUserId: UUID
    let otherUserName: String?
    let otherUserAvatar: String?
    let relatedPostId: UUID?
    let lastMessageAt: Date
    let lastMessagePreview: String?
    var unreadCount: Int
    var isMuted: Bool = false

    var displayName: String {
        let trimmed = otherUserName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "已注销" : trimmed
    }

    enum CodingKeys: String, CodingKey {
        case id
        case otherUserId = "other_user_id"
        case otherUserName = "other_user_name"
        case otherUserAvatar = "other_user_avatar"
        case relatedPostId = "related_post_id"
        case lastMessageAt = "last_message_at"
        case lastMessagePreview = "last_message_preview"
        case unreadCount = "unread_count"
    }
}

struct ChatGroupPreview: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let avatarURL: String?
    var lastMessageAt: Date
    var lastMessagePreview: String?
    let memberCount: Int
    var unreadCount: Int
    var isMuted: Bool = false

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "群聊" : trimmed
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case avatarURL = "avatar_url"
        case lastMessageAt = "last_message_at"
        case lastMessagePreview = "last_message_preview"
        case memberCount = "member_count"
        case unreadCount = "unread_count"
    }

    init(
        id: UUID,
        name: String,
        avatarURL: String?,
        lastMessageAt: Date,
        lastMessagePreview: String?,
        memberCount: Int,
        unreadCount: Int = 0,
        isMuted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.lastMessageAt = lastMessageAt
        self.lastMessagePreview = lastMessagePreview
        self.memberCount = memberCount
        self.unreadCount = max(0, unreadCount)
        self.isMuted = isMuted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        lastMessageAt = try container.decode(Date.self, forKey: .lastMessageAt)
        lastMessagePreview = try container.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        memberCount = try container.decode(Int.self, forKey: .memberCount)
        unreadCount = max(0, try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0)
        isMuted = false
    }
}

struct GroupMessage: Codable, Identifiable, Hashable {
    let id: UUID
    let groupId: UUID
    let senderId: UUID
    let content: String
    let messageType: String
    let metadata: MessageMetadata?
    let isDeleted: Bool
    let createdAt: Date
    let senderName: String
    let senderAvatar: String?

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
        case senderId = "sender_id"
        case content
        case messageType = "message_type"
        case metadata
        case isDeleted = "is_deleted"
        case createdAt = "created_at"
        case senderName = "sender_name"
        case senderAvatar = "sender_avatar"
    }
}

struct MutualFollowProfile: Codable, Identifiable, Hashable {
    let id: UUID
    let fullName: String
    let avatarURL: String?
    let university: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case avatarURL = "avatar_url"
        case university
    }
}
