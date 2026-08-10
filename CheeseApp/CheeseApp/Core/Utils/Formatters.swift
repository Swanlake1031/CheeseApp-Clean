//
//  Formatters.swift
//  CheeseApp
//
//  🎯 格式化工具
//

import Foundation

enum ChatTimeFormatter {
    static let timelineSeparatorInterval: TimeInterval = 5 * 60

    static func shouldShowTimelineSeparator(
        before date: Date,
        previousDate: Date?,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        guard let previousDate else { return true }
        if !calendar.isDate(date, inSameDayAs: previousDate) {
            return true
        }
        return date.timeIntervalSince(previousDate) >= timelineSeparatorInterval
    }

    static func timelineString(
        from date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale? = nil
    ) -> String {
        let resolvedLocale = locale ?? Locale(
            identifier: AppLanguageStore.shared.current == .chinese ? "zh_CN" : "en_US"
        )
        let usesChineseLabels = resolvedLocale.identifier
            .lowercased()
            .hasPrefix("zh")
        let clock = formatted(
            date,
            format: "HH:mm",
            calendar: calendar,
            locale: resolvedLocale
        )

        if calendar.isDate(date, inSameDayAs: now) {
            return "\(usesChineseLabels ? "今天" : "Today") \(clock)"
        }

        if let yesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: calendar.startOfDay(for: now)
        ), calendar.isDate(date, inSameDayAs: yesterday) {
            return "\(usesChineseLabels ? "昨天" : "Yesterday") \(clock)"
        }

        let isInCurrentWeek = calendar.component(.weekOfYear, from: date)
            == calendar.component(.weekOfYear, from: now)
            && calendar.component(.yearForWeekOfYear, from: date)
            == calendar.component(.yearForWeekOfYear, from: now)
        if isInCurrentWeek {
            let weekday = formatted(
                date,
                format: "EEE",
                calendar: calendar,
                locale: resolvedLocale
            )
            return "\(weekday) \(clock)"
        }

        let isInCurrentYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: now)
        let dateFormat = isInCurrentYear ? "MM-dd HH:mm" : "yyyy-MM-dd HH:mm"
        return formatted(
            date,
            format: dateFormat,
            calendar: calendar,
            locale: resolvedLocale
        )
    }

    private static func formatted(
        _ date: Date,
        format: String,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

// ============================================
// 格式化工具类
// ============================================

enum Formatters {
    
    // ============================================
    // 价格格式化
    // ============================================
    
    /// 格式化价格
    static func formatPrice(_ price: Decimal) -> String {
        formatCADCompact((price as NSDecimalNumber).doubleValue)
    }
    
    /// 格式化价格（Double）
    static func formatPrice(_ price: Double) -> String {
        formatCADCompact(price)
    }

    /// 价格数值文本（最多两位小数，自动去掉尾随 0）
    static func formatCompactNumber(_ value: Double, maxFractionDigits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = max(0, maxFractionDigits)
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// CAD 价格文本（最多两位小数，自动去掉尾随 0）
    static func formatCADCompact(_ value: Double, maxFractionDigits: Int = 2) -> String {
        "CAD \(formatCompactNumber(value, maxFractionDigits: maxFractionDigits))"
    }

    /// 月租价格文本，保持现有列表中的整数展示
    static func formatMonthlyRentPrice(_ value: Double) -> String {
        "CAD \(Int(value))/mo"
    }

    /// 兼容旧调用：统一按 CAD 展示
    static func formatUSDCompact(_ value: Double, maxFractionDigits: Int = 2) -> String {
        formatCADCompact(value, maxFractionDigits: maxFractionDigits)
    }
    
    // ============================================
    // 时间格式化
    // ============================================
    
    /// 相对时间格式化
    static func formatRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// 列表里的紧凑时间文案，例如 "5m ago" / "5分钟前"
    static func formatCompactTimeAgo(_ date: Date, useJustNow: Bool = false) -> String {
        let interval = Date().timeIntervalSince(date)

        if useJustNow, interval < 60 {
            return L10n.tr("just now", "刚刚")
        }

        if interval < 3600 {
            let minutes = max(Int(interval / 60), 1)
            return L10n.tr("\(minutes)m ago", "\(minutes)分钟前")
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return L10n.tr("\(hours)h ago", "\(hours)小时前")
        } else {
            let days = Int(interval / 86400)
            return L10n.tr("\(days)d ago", "\(days)天前")
        }
    }
    
}
