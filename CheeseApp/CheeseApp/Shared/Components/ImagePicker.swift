//
//  ImagePicker.swift
//  CheeseApp
//
//  🎯 图片选择器组件
//

import SwiftUI
import PhotosUI
import UIKit

// ============================================
// 图片选择器
// ============================================

struct ImagePicker: View {
    enum PresentationStyle {
        case standard
        case composerToolbar
    }

    @Binding var selectedImages: [UIImage]
    let maxCount: Int
    let existingImageCount: Int
    let presentationStyle: PresentationStyle
    
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var showingSourceMenu = false
    @State private var showingPhotoLibrary = false
    @State private var showingCamera = false
    
    init(
        selectedImages: Binding<[UIImage]>,
        maxCount: Int = 9,
        existingImageCount: Int = 0,
        presentationStyle: PresentationStyle = .standard
    ) {
        self._selectedImages = selectedImages
        self.maxCount = maxCount
        self.existingImageCount = max(0, existingImageCount)
        self.presentationStyle = presentationStyle
    }
    
    var body: some View {
        Button {
            showingSourceMenu = true
        } label: {
            pickerLabel
        }
        .buttonStyle(.plain)
        .disabled(totalImageCount >= maxCount)
        .confirmationDialog(
            L10n.tr("Add photos", "添加图片"),
            isPresented: $showingSourceMenu,
            titleVisibility: .visible
        ) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(L10n.tr("Take Photo", "拍照")) {
                    showingCamera = true
                }
            }

            Button(L10n.tr("Choose from Library", "从相册选择")) {
                showingPhotoLibrary = true
            }

            Button(L10n.tr("Cancel", "取消"), role: .cancel) {}
        }
        .photosPicker(
            isPresented: $showingPhotoLibrary,
            selection: $selectedItems,
            maxSelectionCount: remainingSelectionCount,
            matching: .images
        )
        .fullScreenCover(isPresented: $showingCamera) {
            CameraImagePicker(
                onCapture: { image in
                    appendImages([image])
                    showingCamera = false
                },
                onCancel: {
                    showingCamera = false
                }
            )
            .ignoresSafeArea()
        }
        .onChange(of: selectedItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                var loadedImages: [UIImage] = []
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        loadedImages.append(image)
                    }
                }
                await MainActor.run {
                    appendImages(loadedImages)
                    selectedItems = []
                }
            }
        }
    }

    private var remainingSelectionCount: Int {
        max(1, maxCount - totalImageCount)
    }

    private func appendImages(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        let availableSlots = max(0, maxCount - totalImageCount)
        selectedImages.append(contentsOf: images.prefix(availableSlots))
    }

    private var totalImageCount: Int {
        existingImageCount + selectedImages.count
    }

    @ViewBuilder
    private var pickerLabel: some View {
        switch presentationStyle {
        case .standard:
            HStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColors.accentStrong)
                    .frame(width: 20)

                Text(L10n.tr("Choose Images", "选择图片"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)

                Spacer(minLength: 8)

                Text("\(totalImageCount)/\(maxCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(AppColors.pageBackground.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .composerToolbar:
            ZStack(alignment: .topTrailing) {
                Image(systemName: totalImageCount == 0 ? "photo" : "photo.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(totalImageCount == 0 ? AppColors.textPrimary : AppColors.accentStrong)
                    .frame(width: 44, height: 44)

                if totalImageCount > 0 {
                    Text("\(totalImageCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(AppColors.accentStrong)
                        .clipShape(Circle())
                        .offset(x: 2, y: 1)
                }
            }
            .contentShape(Rectangle())
            .accessibilityLabel(L10n.tr("Choose Images", "选择图片"))
            .accessibilityValue("\(totalImageCount)/\(maxCount)")
        }
    }
}

struct CameraImagePicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.allowsEditing = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIImagePickerController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraImagePicker

        init(parent: CameraImagePicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                parent.onCancel()
                return
            }
            parent.onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}
