//
//  Date+Extensions.swift
//  CheeseApp
//
//  🎯 Date 扩展
//

import Foundation

extension Date {
    
    /// 相对时 间描述
    var relativeDescription: String {
        return Formatters.formatRelativeTime(self)
    }
    
    /// 是否是今天
    var isToday: Bool {
        return Calendar.current.isDateInToday(self)
    }
    
    /// 是否是昨天
    var isYesterday: Bool {
        return Calendar.current.isDateInYesterday(self)
    }
    
    /// 格式化日期
    func formatted(style: DateFormatter.Style) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = style
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: self)
    }
}
   
