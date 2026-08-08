//
//  LoadingView.swift
//  CheeseApp
//
//  🎯 加载视图组件
//

import SwiftUI

// ============================================
// 加载视图
// ============================================

struct LoadingView: View {
    var message: String = "加载中..."
    
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(message)
                .font(AppFonts.caption)
                .foregroundColor(AppColors.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.background)
    }
}

struct CheeseLoadingOverlay: View {
    var message: String
    var showsBackdrop: Bool = true

    var body: some View {
        ZStack {
            if showsBackdrop {
                Color.black.opacity(0.04)
                    .ignoresSafeArea()
            }

            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)

                Text(message)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 8)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

#Preview {
    LoadingView()
}

private struct CheeseLoadingOverlayModifier: ViewModifier {
    let isPresented: Bool
    let message: String
    let showsBackdrop: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                CheeseLoadingOverlay(message: message, showsBackdrop: showsBackdrop)
            }
        }
    }
}

extension View {
    func cheeseLoadingOverlay(
        isPresented: Bool,
        message: String,
        showsBackdrop: Bool = true
    ) -> some View {
        modifier(
            CheeseLoadingOverlayModifier(
                isPresented: isPresented,
                message: message,
                showsBackdrop: showsBackdrop
            )
        )
    }
}
