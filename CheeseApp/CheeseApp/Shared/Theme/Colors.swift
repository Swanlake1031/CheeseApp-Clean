//
//  Colors.swift
//  CheeseApp
//
//  🎯 颜色定义
//

import SwiftUI

// ============================================
// 应用颜色
// ============================================

enum AppColors {
    /// 主色调（芝士黄）
    static let primary = Color(red: 1.0, green: 0.725, blue: 0.176)
    
    /// 次要色
    static let secondary = Color(red: 0.4, green: 0.4, blue: 0.45)
    
    /// 背景色
    static let background = Color(.systemBackground)
    
    /// 次要背景色
    static let secondaryBackground = Color(.secondarySystemBackground)
    
    /// 文字色
    static let text = Color(.label)
    
    /// 次要文字色
    static let secondaryText = Color(.secondaryLabel)

    /// 固定浅色主题主文本（避免系统深色模式导致浅底白字）
    static let textPrimary = Color(red: 0.10, green: 0.10, blue: 0.12)

    /// 固定浅色主题次文本
    static let textMuted = Color(red: 0.42, green: 0.42, blue: 0.46)
    
    /// 成功色
    static let success = Color.green
    
    /// 警告色
    static let warning = Color.orange
    
    /// 错误色
    static let error = Color.red

    /// 全局页面底色
    static let pageBackground = Color.white

    /// 卡片底色
    static let cardBackground = Color.white

    /// 白色页面上的统一卡片边界
    static let cardBorder = Color.black.opacity(0.28)

    /// 主题强调色（按钮）
    static let accent = Color(red: 0.95, green: 0.85, blue: 0.45)

    /// 主题强调深色（渐变/hover）
    static let accentStrong = Color(red: 0.90, green: 0.75, blue: 0.35)

    /// 当前用户的聊天气泡。与操作按钮的强调黄分开，避免大面积高饱和黄色。
    static let chatOutgoingBubble = Color(red: 1.00, green: 0.96, blue: 0.80)

    /// 全 App 点赞激活态。收藏继续使用芝士黄，避免两种操作混淆。
    static let likeActive = Color.red

    /// 文本链接/强调
    static let link = Color(red: 0.78, green: 0.60, blue: 0.20)

    /// 选中态深色
    static let selectedBackground = Color.black

    /// 分割线
    static let divider = Color(.systemGray5)

    /// 按业务类型映射统一色板
    static func categoryColor(for type: String) -> Color {
        switch type.lowercased() {
        case "secondhand":
            return Color(red: 0.93, green: 0.76, blue: 0.29)
        case "forum":
            return Color(red: 0.90, green: 0.38, blue: 0.56)
        default:
            return secondary
        }
    }
}

private enum CheeseContainerChromeRole {
    case card
    case input
}

private struct CheeseContainerChromeModifier: ViewModifier {
    let cornerRadius: CGFloat
    let role: CheeseContainerChromeRole

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppColors.cardBorder, lineWidth: 1.1)
                    .allowsHitTesting(false)
            }
            .shadow(
                color: role == .card ? .black.opacity(0.065) : .clear,
                radius: role == .card ? 10 : 0,
                x: 0,
                y: role == .card ? 4 : 0
            )
    }
}

struct CheeseContainerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// Apply after the card background and clip shape.
    func cheeseCardChrome(cornerRadius: CGFloat = 18) -> some View {
        modifier(
            CheeseContainerChromeModifier(
                cornerRadius: cornerRadius,
                role: .card
            )
        )
    }

    /// Shared black outline for editable fields and compact input containers.
    /// Apply after the background and clip shape so Create and Chat use one token.
    func cheeseInputChrome(cornerRadius: CGFloat = 14) -> some View {
        modifier(
            CheeseContainerChromeModifier(
                cornerRadius: cornerRadius,
                role: .input
            )
        )
    }
}
