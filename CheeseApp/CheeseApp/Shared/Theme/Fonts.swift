//
//  Fonts.swift
//  CheeseApp
//
//  🎯 字体定义
//

import SwiftUI

// ============================================
// 应用字体
// ============================================

enum AppFonts {
    /// 大标题
    static let largeTitle = Font.largeTitle.weight(.bold)
    
    /// 标题
    static let title = Font.title2.weight(.semibold)
    
    /// 标题3
    static let title3 = Font.title3.weight(.medium)
    
    /// 正文
    static let body = Font.body
    
    /// 小字
    static let caption = Font.caption
    
    /// 按钮
    static let button = Font.body.weight(.semibold)
}
