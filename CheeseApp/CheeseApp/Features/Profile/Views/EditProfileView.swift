//
//  ProfileView.swift
//  CheeseApp
//
//  👤 个人中心视图
//  展示真实用户信息、我的发布、设置等
//

import SwiftUI
import PhotosUI

private enum EditProfileFocusField: Hashable {
    case fullName
    case bio
    case occupation
    case phone
}

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authService: AuthService

    @State private var fullName: String = ""
    @State private var profileStatus: String = "student"
    @State private var school: String = ""
    @State private var phoneNumber: String = ""
    @State private var gender: String = ""
    @State private var isGenderVisible = true
    @State private var occupation: String = ""
    @State private var bio: String = ""
    @State private var isSaving = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var selectedAvatarImage: UIImage?
    @State private var pendingAvatarCropImage: UIImage?
    @State private var showingAvatarCropper = false
    @State private var showingAvatarCamera = false
    @State private var avatarURLString: String = ""
    @State private var coverURLString: String?
    @State private var saveErrorMessage: String?
    @State private var showingAvatarActionPreview = false
    @State private var showingCoverEditor = false
    @FocusState private var focusedField: EditProfileFocusField?

    private let startsWithAvatarActions: Bool

    private let genderOptions: [(value: String, label: String)] = [
        ("male", "男"),
        ("female", "女"),
        ("non_binary", "非二元"),
        ("prefer_not_to_say", "暂不透露")
    ]

    init(startsWithAvatarActions: Bool = false) {
        self.startsWithAvatarActions = startsWithAvatarActions
        _showingAvatarActionPreview = State(initialValue: startsWithAvatarActions)
    }

    private var selectedSchool: CheeseUniversityOption? {
        CheeseUniversityOption.option(matching: school)
    }

    var body: some View {
        Group {
            if startsWithAvatarActions && showingAvatarActionPreview {
                avatarActionFullScreen
            } else {
                profileEditor
            }
        }
        .onChange(of: selectedAvatarItem) { _, newItem in
            guard let newItem else { return }
            Task {
                let image: UIImage?
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    image = UIImage(data: data)
                } else {
                    image = nil
                }

                await MainActor.run {
                    selectedAvatarItem = nil
                    guard let image else {
                        saveErrorMessage = L10n.tr(
                            "Unable to load this photo. Please choose another image.",
                            "无法读取这张照片，请选择其他图片"
                        )
                        return
                    }
                    saveErrorMessage = nil
                    pendingAvatarCropImage = image
                    showingAvatarCropper = true
                }
            }
        }
        .onAppear {
            guard let user = authService.currentUser else { return }
            fullName = user.fullName ?? ""
            profileStatus = user.profileStatus == "working" ? "working" : "student"
            school = user.school ?? ""
            phoneNumber = user.phoneNumber ?? ""
            let savedGender = user.gender ?? ""
            gender = genderOptions.contains(where: { $0.value == savedGender }) ? savedGender : ""
            isGenderVisible = user.isGenderVisible ?? true
            occupation = user.occupation ?? ""
            bio = user.bio ?? ""
            avatarURLString = user.avatarUrl ?? ""
            coverURLString = user.coverImageUrl
        }
    }

    private var profileEditor: some View {
        NavigationStack {
            ZStack {
                AppColors.pageBackground
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        avatarHeroSection

                        if let saveErrorMessage {
                            inlineErrorCard(message: saveErrorMessage)
                        }

                        profileSectionCard {
                            inlineTextFieldRow(
                                title: "昵称",
                                placeholder: "输入你的昵称",
                                text: $fullName,
                                field: .fullName,
                                textInputAutocapitalization: .words,
                                submitLabel: .next
                            ) {
                                focusedField = .bio
                            }

                            Divider()
                                .padding(.leading, 16)

                            coverImageField

                            Divider()
                                .padding(.leading, 16)

                            profileStatusField

                            Divider()
                                .padding(.leading, 16)

                            schoolField

                            if profileStatus == "student", selectedSchool?.supportsStudentVerification == true {
                                Divider().padding(.leading, 16)
                                studentVerificationInfo
                                Divider().padding(.leading, 16)
                                studentVerificationField
                            }
                        }

                        profileSectionCard {
                            bioEditorField
                        }

                        profileSectionCard {
                            genderPickerField

                            Divider()
                                .padding(.leading, 16)

                            genderVisibilityField

                            Divider()
                                .padding(.leading, 16)

                            inlineTextFieldRow(
                                title: "职业",
                                placeholder: "如：学生、实习生、工程师",
                                text: $occupation,
                                field: .occupation,
                                textInputAutocapitalization: .words,
                                submitLabel: .next
                            ) {
                                focusedField = .phone
                            }

                            Divider()
                                .padding(.leading, 16)

                            inlineTextFieldRow(
                                title: "手机号",
                                placeholder: "+1 234 567 890",
                                text: $phoneNumber,
                                field: .phone,
                                keyboardType: .phonePad,
                                textInputAutocapitalization: .never
                            )
                        }

                        Text("手机号仅在需要联系你时使用，不会作为个人主页主信息展示。")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppColors.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(L10n.tr("Edit Profile", "编辑资料"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(AppColors.pageBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.tr("Save", "保存")) {
                        Task { await saveProfile() }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSaving ? AppColors.textMuted : AppColors.textPrimary)
                    .disabled(isSaving)
                }
            }
            .fullScreenCover(isPresented: $showingAvatarActionPreview) {
                avatarActionFullScreen
            }
            .fullScreenCover(isPresented: $showingCoverEditor) {
                if let userID = authService.currentUser?.id {
                    ProfileCoverEditorView(
                        userID: userID,
                        coverURLString: coverURLString
                    ) { updatedURL in
                        coverURLString = updatedURL
                        guard var updatedProfile = authService.currentUser else { return }
                        updatedProfile.coverImageUrl = updatedURL
                        authService.currentUser = updatedProfile
                    }
                }
            }
        }
    }

    private var avatarHeroSection: some View {
        VStack(spacing: 12) {
            Button {
                showingAvatarActionPreview = true
            } label: {
                avatarEditorView
            }
            .buttonStyle(.plain)

            Text("点击头像更换照片")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func inlineErrorCard(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.red)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.red.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func profileSectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .cheeseCardChrome(cornerRadius: 20)
    }

    private func inlineTextFieldRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        field: EditProfileFocusField,
        keyboardType: UIKeyboardType = .default,
        textInputAutocapitalization: TextInputAutocapitalization? = .sentences,
        submitLabel: SubmitLabel = .done,
        onSubmit: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
                .frame(width: 66, alignment: .leading)

            TextField(placeholder, text: text)
                .focused($focusedField, equals: field)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(textInputAutocapitalization)
                .autocorrectionDisabled(field == .phone)
                .foregroundStyle(AppColors.textPrimary)
                .submitLabel(submitLabel)
                .onSubmit {
                    onSubmit?()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
    }

    private var bioEditorField: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("个性签名")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
                .frame(width: 66, alignment: .leading)

            TextField("简单介绍一下自己", text: $bio, axis: .vertical)
                .focused($focusedField, equals: .bio)
                .lineLimit(1...3)
                .foregroundStyle(AppColors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
    }

    private var coverImageField: some View {
        Button {
            focusedField = nil
            showingCoverEditor = true
        } label: {
            HStack(spacing: 14) {
                Text(L10n.tr("Cover image", "背景图"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppColors.textMuted)
                    .frame(width: 66, alignment: .leading)

                coverImageThumbnail

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted.opacity(0.65))
            }
            .padding(.horizontal, 16)
            .frame(height: 70)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(authService.currentUser?.id == nil)
    }

    @ViewBuilder
    private var coverImageThumbnail: some View {
        if let resolvedURL = SupabasePublicImageURLResolver.url(
            fromStoredURL: coverURLString,
            purpose: .feedThumbnail
        ) {
            CachedRemoteImage(
                url: resolvedURL,
                targetPixelWidth: 180
            ) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                coverThumbnailPlaceholder
            }
            .frame(width: 64, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            HStack(spacing: 6) {
                coverThumbnailPlaceholder
                    .frame(width: 42, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(L10n.tr("Not set", "未设置"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppColors.textMuted.opacity(0.72))
            }
        }
    }

    private var coverThumbnailPlaceholder: some View {
        LinearGradient(
            colors: [AppColors.accent.opacity(0.24), Color(.systemGray6)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "photo")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.textMuted.opacity(0.7))
        }
    }

    private var genderPickerField: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("性别")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
                .frame(width: 66, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(genderOptions, id: \.value) { option in
                    Button {
                        focusedField = nil
                        gender = option.value
                    } label: {
                        Text(option.label)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(gender == option.value ? AppColors.textPrimary : AppColors.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(gender == option.value ? AppColors.accent.opacity(0.24) : Color(.systemGray6))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
    }

    private var genderVisibilityField: some View {
        Toggle(isOn: $isGenderVisible) {
            VStack(alignment: .leading, spacing: 3) {
                Text("公开性别图标")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppColors.textPrimary)
                Text(isGenderVisible ? "在个人主页显示性别" : "在个人主页隐藏性别")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppColors.textMuted)
            }
        }
        .tint(AppColors.accentStrong)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var studentVerificationField: some View {
        NavigationLink(destination: SchoolVerificationView()) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(AppColors.accentStrong)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("学生邮箱认证")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Text("使用 \(selectedSchool?.verificationDomainHint ?? "学校官方") 邮箱完成验证")
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var studentVerificationInfo: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(AppColors.accentStrong)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text("学生验证")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text("使用所选学校的官方邮箱认证后，个人资料和发布内容会显示学校学生徽章。")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var profileStatusField: some View {
        HStack(spacing: 14) {
            Text("状态")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
                .frame(width: 66, alignment: .leading)
            Picker("状态", selection: $profileStatus) {
                Text("在校").tag("student")
                Text("工作").tag("working")
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var schoolField: some View {
        HStack(spacing: 14) {
            Text(profileStatus == "student" ? "学校*" : "学校")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
                .frame(width: 66, alignment: .leading)
            Picker("学校", selection: $school) {
                Text(profileStatus == "student" ? "请选择学校" : "不填写").tag("")
                ForEach(CheeseUniversityOption.all, id: \.name) { option in
                    Text(option.localizedName).tag(option.name)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var avatarEditorView: some View {
        Group {
            if let selectedAvatarImage {
                Image(uiImage: selectedAvatarImage)
                    .resizable()
                    .scaledToFill()
            } else if let url = URL(string: avatarURLString), !avatarURLString.isEmpty {
                AsyncImage(url: url) { image in
                    image.resizable()
                        .scaledToFill()
                } placeholder: {
                    avatarFallbackView
                }
            } else {
                avatarFallbackView
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.78))

                Image(systemName: "camera.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .offset(x: 2, y: 2)
        }
    }

    private var avatarFallbackView: some View {
        Circle()
            .fill(AppColors.accent)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
            }
    }

    @ViewBuilder
    private var avatarActionFullScreen: some View {
        if showingAvatarCamera {
            CameraImagePicker(
                onCapture: { image in
                    saveErrorMessage = nil
                    pendingAvatarCropImage = image
                    showingAvatarCamera = false
                    showingAvatarCropper = true
                },
                onCancel: {
                    showingAvatarCamera = false
                }
            )
            .ignoresSafeArea()
        } else if showingAvatarCropper, let pendingAvatarCropImage {
            AvatarCropView(
                image: pendingAvatarCropImage,
                onCancel: cancelAvatarCrop,
                onConfirm: confirmAvatarCrop
            )
        } else {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack {
                        Button {
                            closeAvatarActions()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 28, weight: .regular))
                                .foregroundStyle(.white.opacity(0.95))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)

                    Spacer(minLength: 28)

                    GeometryReader { proxy in
                        let side = min(proxy.size.width - 64, 380)
                        avatarPreviewInActionSheet
                            .frame(width: side, height: side)
                            .clipShape(Circle())
                            .overlay {
                                Circle()
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .frame(height: 430)

                    Spacer(minLength: 10)

                    VStack(spacing: 0) {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button {
                                showingAvatarCamera = true
                            } label: {
                                avatarActionRow(
                                    title: L10n.tr("Take Photo", "拍照"),
                                    icon: "camera.fill"
                                )
                            }
                            .buttonStyle(.plain)

                            Divider()
                                .overlay(Color.white.opacity(0.10))
                                .padding(.leading, 24)
                        }

                        PhotosPicker(
                            selection: $selectedAvatarItem,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            avatarActionRow(
                                title: L10n.tr("Upload New Avatar", "上传新头像"),
                                icon: "photo.on.rectangle.angled"
                            )
                        }
                    }
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 22)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private var avatarPreviewInActionSheet: some View {
        if let selectedAvatarImage {
            Image(uiImage: selectedAvatarImage)
                .resizable()
                .scaledToFill()
        } else if let url = URL(string: avatarURLString), !avatarURLString.isEmpty {
            AsyncImage(url: url) { image in
                image.resizable()
                    .scaledToFill()
            } placeholder: {
                avatarFallbackView
            }
        } else {
            avatarFallbackView
        }
    }

    private func avatarActionRow(title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .contentShape(Rectangle())
    }

    private func cancelAvatarCrop() {
        pendingAvatarCropImage = nil
        showingAvatarCropper = false
    }

    private func closeAvatarActions() {
        guard startsWithAvatarActions,
              selectedAvatarImage == nil
        else {
            showingAvatarActionPreview = false
            return
        }

        // The profile-avatar entry presents this editor directly full screen,
        // so closing dismisses that surface without flashing the profile form.
        dismiss()
    }

    private func confirmAvatarCrop(_ image: UIImage) {
        selectedAvatarImage = image
        pendingAvatarCropImage = nil
        showingAvatarCropper = false
        showingAvatarActionPreview = false
    }

    @MainActor
    private func saveProfile() async {
        isSaving = true
        saveErrorMessage = nil
        defer { isSaving = false }

        let normalizedFullName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFullName.isEmpty else {
            saveErrorMessage = "昵称为必填项"
            focusedField = .fullName
            return
        }

        guard !gender.isEmpty else {
            saveErrorMessage = "请选择性别"
            return
        }
        guard profileStatus == "working" || selectedSchool != nil else {
            saveErrorMessage = "在校状态必须选择学校"
            return
        }

        let userId: UUID
        do {
            userId = try await authService.requireAuthUserId()
        } catch {
            saveErrorMessage = L10n.tr("Please sign in again", "请重新登录后再试")
            return
        }

        do {
            var avatarURLToSave = avatarURLString
            if let selectedAvatarImage {
                avatarURLToSave = try await ImageUploadService.shared.uploadAvatar(
                    selectedAvatarImage,
                    userId: userId
                )
            }

            let input = ProfileUpdateInput(
                userId: userId,
                fullName: normalizedFullName,
                profileStatus: profileStatus,
                schoolName: school.isEmpty ? nil : school,
                avatarURL: avatarURLToSave,
                gender: gender,
                isGenderVisible: isGenderVisible,
                occupation: occupation,
                phoneNumber: phoneNumber,
                bio: bio
            )
            if let updatedProfile = try await ProfileService.updateProfile(
                input: input,
                currentProfile: authService.currentUser
            ) {
                authService.currentUser = updatedProfile
            }

            dismiss()
        } catch {
            saveErrorMessage = normalizedSaveErrorMessage(from: error)
        }
    }

    private func normalizedSaveErrorMessage(from error: Error) -> String {
        let fallback = L10n.tr("Unable to save profile. Please try again.", "无法保存个人资料，请稍后重试")
        let message = AppErrorMessage.userMessage(for: error).trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty || message == "The operation couldn’t be completed." {
            return fallback
        }
        let lower = message.lowercased()
        if lower.contains("storage.objects") || (lower.contains("row-level security") && lower.contains("objects")) {
            return L10n.tr(
                "Avatar upload is blocked by Storage policy. Please run the avatar storage SQL migration.",
                "头像上传被 Storage 权限拦截，请先执行 avatars 的 SQL 权限迁移"
            )
        }
        if lower.contains("column") && lower.contains("does not exist") {
            return L10n.tr(
                "Database profile columns are outdated. Please run the latest profile migrations and retry.",
                "数据库 profiles 字段版本过旧，请先执行最新 migration 后再保存"
            )
        }
        if lower.contains("row-level security") || lower.contains("rls") {
            return L10n.tr(
                "Permission denied by database policy. Please re-login and run latest Supabase SQL migrations.",
                "数据库权限策略拒绝此次保存，请重新登录并执行最新 Supabase SQL migration"
            )
        }
        return message
    }

}

// MARK: - 设置页
