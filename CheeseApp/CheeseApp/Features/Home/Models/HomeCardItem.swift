//
//  HomeCardItem.swift
//  CheeseApp
//
//  🏠 首页卡片数据模型
//  用于展示二手、论坛与课程内容卡片的轻量级 DTO
//

import SwiftUI

// MARK: - 图片来源枚举
/// 支持本地资源图片和网络 URL 图片
enum ImageSource {
    case asset(String)      // 本地 Assets 中的图片名称
    case url(URL)           // 网络图片 URL
    case placeholder        // 默认占位图

    var isPlaceholder: Bool {
        if case .placeholder = self {
            return true
        }
        return false
    }
    
    /// 将图片来源转换为 SwiftUI View
    @ViewBuilder
    func view(targetPixelWidth: Int) -> some View {
        switch self {
        case .asset(let name):
            // 尝试加载本地图片，失败则显示占位符
            Image(name)
                .resizable()
                .scaledToFill()
        case .url(let url):
            // 异步加载网络图片
            CachedRemoteImage(url: url, targetPixelWidth: targetPixelWidth) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Color.gray.opacity(0.2))
            }
        case .placeholder:
            // 灰色占位矩形
            Rectangle().fill(Color.gray.opacity(0.2))
        }
    }

    var view: some View {
        view(targetPixelWidth: 1024)
    }
}

// MARK: - 卡片底部样式枚举
enum CardFooterStyle {
    case posted(name: String, avatar: ImageSource)   // "Posted by xxx"
    case hosted(name: String, avatar: ImageSource)   // "Hosted by xxx"
    case avatars(countText: String, avatars: [ImageSource])  // 多头像 + 数量
    case none
}

// MARK: - 首页卡片数据模型
/// 用于首页统一信息流展示的轻量数据结构。
/// 交互状态不在此模型内作第二份真实来源，由 HomeViewModel 从现有
/// PostReactionService / PostFavoriteService 同步后管理。
struct HomeCardItem: Identifiable {
    let id: UUID
    let postId: UUID?               // 关联真实帖子 ID
    let authorId: UUID?             // 关联作者 ID
    let image: ImageSource          // 卡片顶部图片
    let title: String               // 主标题
    let subtitle: String            // 副标题
    let footer: CardFooterStyle     // 底部样式
    let isAuthorMcMasterVerified: Bool
    let category: HomeCardCategory  // 所属分类
    let viewCount: Int              // 板块内排序信号
    let badgeText: String?          // 论坛板块或内容分类
    let boardID: UUID?              // 论坛板块稳定 ID（用于直接进入板块）
    let boardIcon: String?          // 论坛板块图标
    let timeText: String?           // 发布时间
    let priceText: String?          // 价格正文（不作为 tag）
    let originalPriceText: String?  // 二手原价（划线展示）
    let likeCount: Int
    let commentCount: Int
    let saveCount: Int
    let isSystemPinned: Bool
    let initiallyLiked: Bool
    let courseID: UUID?
    let courseCode: String?
    let rating: Double?
    let reviewCount: Int
    let professorText: String?
    let isSeatRadar: Bool
    
    /// 便捷初始化方法
    init(
        id: UUID? = nil,
        postId: UUID? = nil,
        authorId: UUID? = nil,
        image: ImageSource = .placeholder,
        title: String,
        subtitle: String,
        footer: CardFooterStyle = .none,
        isAuthorMcMasterVerified: Bool = false,
        category: HomeCardCategory = .forum,
        viewCount: Int = 0,
        badgeText: String? = nil,
        boardID: UUID? = nil,
        boardIcon: String? = nil,
        timeText: String? = nil,
        priceText: String? = nil,
        originalPriceText: String? = nil,
        likeCount: Int = 0,
        commentCount: Int = 0,
        saveCount: Int = 0,
        isSystemPinned: Bool = false,
        initiallyLiked: Bool = false,
        courseID: UUID? = nil,
        courseCode: String? = nil,
        rating: Double? = nil,
        reviewCount: Int = 0,
        professorText: String? = nil,
        isSeatRadar: Bool = false
    ) {
        self.id = id ?? postId ?? UUID()
        self.postId = postId
        self.authorId = authorId
        self.image = image
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.isAuthorMcMasterVerified = isAuthorMcMasterVerified
        self.category = category
        self.viewCount = max(viewCount, 0)
        self.badgeText = badgeText
        self.boardID = boardID
        self.boardIcon = boardIcon
        self.timeText = timeText
        self.priceText = priceText
        self.originalPriceText = originalPriceText
        self.likeCount = max(likeCount, 0)
        self.commentCount = max(commentCount, 0)
        self.saveCount = max(saveCount, 0)
        self.isSystemPinned = isSystemPinned
        self.initiallyLiked = initiallyLiked
        self.courseID = courseID
        self.courseCode = courseCode
        self.rating = rating
        self.reviewCount = max(reviewCount, 0)
        self.professorText = professorText
        self.isSeatRadar = isSeatRadar
    }
}

enum HomeRecommendationRanker {
    private struct Candidate {
        let card: HomeCardItem
        let originalIndex: Int
        let score: Double
    }

    static func ranked(
        _ cards: [HomeCardItem],
        seed: UInt64,
        limit: Int = 12
    ) -> [HomeCardItem] {
        guard limit > 0 else { return [] }

        var seenPostIDs = Set<UUID>()
        let uniqueCards = cards.filter { card in
            seenPostIDs.insert(card.postId ?? card.id).inserted
        }
        let pinnedCards = uniqueCards.filter(\.isSystemPinned)
        let organicCards = uniqueCards.filter { !$0.isSystemPinned }
        let remainingLimit = max(limit - pinnedCards.count, 0)
        guard remainingLimit > 0 else {
            return Array(pinnedCards.prefix(limit))
        }

        let viewScale = metricScale(organicCards.map(\.viewCount))
        let likeScale = metricScale(organicCards.map(\.likeCount))
        let commentScale = metricScale(organicCards.map(\.commentCount))
        let saveScale = metricScale(organicCards.map(\.saveCount))

        let candidates = organicCards.enumerated().map { index, card in
            let randomScore = deterministicRandom(
                id: card.postId ?? card.id,
                seed: seed
            )
            let score: Double
            switch card.category {
            case .forum:
                score = normalized(card.viewCount, scale: viewScale) * 0.12
                    + normalized(card.saveCount, scale: saveScale) * 0.14
                    + normalized(card.likeCount, scale: likeScale) * 0.10
                    + normalized(card.commentCount, scale: commentScale) * 0.14
                    + randomScore * 0.50
            case .secondhand:
                score = normalized(card.viewCount, scale: viewScale) * 0.25
                    + normalized(card.saveCount, scale: saveScale) * 0.25
                    + randomScore * 0.50
            case .course:
                score = normalized(card.viewCount, scale: viewScale) * 0.30
                    + randomScore * 0.70
            }
            return Candidate(card: card, originalIndex: index, score: score)
        }

        let rankedOrganic = candidates.sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.000_001 {
                return lhs.score > rhs.score
            }
            return lhs.originalIndex < rhs.originalIndex
        }
        .prefix(remainingLimit)
        .map(\.card)

        return Array(pinnedCards.prefix(limit)) + rankedOrganic
    }

    static func insertingCreatedPost(
        _ createdPost: HomeCardItem,
        into rankedCards: [HomeCardItem],
        limit: Int = 12
    ) -> [HomeCardItem] {
        guard limit > 0 else { return [] }
        let createdID = createdPost.postId ?? createdPost.id
        let withoutCreated = rankedCards.filter {
            ($0.postId ?? $0.id) != createdID
        }
        let pinnedCards = withoutCreated.filter(\.isSystemPinned)
        let organicCards = withoutCreated.filter { !$0.isSystemPinned }
        let effectiveLimit = max(limit, pinnedCards.count + 1)
        return Array(
            (pinnedCards + [createdPost] + organicCards).prefix(effectiveLimit)
        )
    }

    private static func metricScale(_ values: [Int]) -> Double {
        log1p(Double(values.max() ?? 0))
    }

    private static func normalized(_ value: Int, scale: Double) -> Double {
        guard scale > 0 else { return 0 }
        return log1p(Double(max(value, 0))) / scale
    }

    private static func deterministicRandom(id: UUID, seed: UInt64) -> Double {
        var hash = 1_469_598_103_934_665_603 ^ seed
        for byte in id.uuidString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Double(hash % 1_000_000) / 999_999
    }
}

enum HomeViewRanker {
    static func rankedByViews(
        _ cards: [HomeCardItem],
        limit: Int = 12
    ) -> [HomeCardItem] {
        guard limit > 0 else { return [] }

        var seenPostIDs = Set<UUID>()
        let uniqueCards = cards.enumerated().filter { _, card in
            seenPostIDs.insert(card.postId ?? card.id).inserted
        }

        return uniqueCards
            .sorted { lhs, rhs in
                if lhs.element.viewCount != rhs.element.viewCount {
                    return lhs.element.viewCount > rhs.element.viewCount
                }
                return lhs.offset < rhs.offset
            }
            .prefix(limit)
            .map(\.element)
    }

    static func featuredFirst(
        _ featuredCards: [HomeCardItem],
        rankedCards: [HomeCardItem],
        limit: Int = 12
    ) -> [HomeCardItem] {
        guard limit > 0 else { return [] }

        let featured = Array(featuredCards.prefix(limit))
        let featuredIDs = Set(featured.map { $0.postId ?? $0.id })
        let remaining = rankedByViews(
            rankedCards.filter {
                !featuredIDs.contains($0.postId ?? $0.id)
            },
            limit: max(limit - featured.count, 0)
        )
        return featured + remaining
    }
}

// MARK: - 卡片分类枚举
enum HomeCardCategory: String, CaseIterable {
    case secondhand = "Secondhand"  // 二手
    case forum = "Forum"            // 论坛
    case course = "Course"          // 课程评分

    var localizedTitle: String {
        switch self {
        case .secondhand:
            return L10n.tr("Secondhand", "二手")
        case .forum:
            return L10n.tr("Forum", "论坛")
        case .course:
            return L10n.tr("Course Ratings", "课程评分")
        }
    }
}
