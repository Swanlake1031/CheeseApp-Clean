//
//  ForumListView.swift
//  CheeseApp
//
//  💬 论坛列表视图
//  展示论坛帖子，支持分类筛选
//

import SwiftUI
import UIKit

struct HotpotSteamRefreshView: View {
    @State private var rise = false
    @State private var fade = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.96, green: 0.80, blue: 0.62))
                .frame(width: 148, height: 40)
                .overlay {
                    Text("正在刷新")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.35, green: 0.16, blue: 0.05))
                }
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { idx in
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 5, height: 15)
                        .offset(y: rise ? CGFloat(-28 - idx * 3) : -8)
                        .opacity(fade ? 0.2 : 0.85)
                        .animation(.easeOut(duration: 0.9).repeatForever(autoreverses: true).delay(Double(idx) * 0.15), value: rise)
                }
            }
        }
        .frame(height: 66)
        .onAppear {
            rise = true
            fade = true
        }
    }
}
