import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AccountAvatarEditor: View {
    let target: AccountAvatarTarget
    let language: WidgetLanguage
    var initial: AccountAvatarRecord
    var existingImage: NSImage?
    var store: AccountAvatarAssetStore
    var onSave: (AccountAvatarRecord, NSImage?) -> Void
    var onCancel: () -> Void

    @State private var mode: AccountAvatarMode
    @State private var emojiDraft: String
    @State private var pickedImage: NSImage?
    @State private var cropOffset = CGSize.zero
    @State private var cropScale: CGFloat = 1
    @State private var errorText: String?
    @State private var warningText: String?

    init(
        target: AccountAvatarTarget,
        language: WidgetLanguage,
        initial: AccountAvatarRecord,
        existingImage: NSImage?,
        store: AccountAvatarAssetStore,
        onSave: @escaping (AccountAvatarRecord, NSImage?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.target = target
        self.language = language
        self.initial = initial
        self.existingImage = existingImage
        self.store = store
        self.onSave = onSave
        self.onCancel = onCancel
        _mode = State(initialValue: initial.mode)
        _emojiDraft = State(initialValue: initial.emoji ?? "")
        _pickedImage = State(initialValue: existingImage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(language.text("更换头像", "Change avatar")).font(.headline)
            Text(target.displayName).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                preview(slot: .list)
                preview(slot: .card)
                preview(slot: .detail)
                preview(slot: .editor)
            }
            Picker(language.text("头像来源", "Avatar source"), selection: $mode) {
                Text(language.text("默认平台图标", "Default platform icon")).tag(AccountAvatarMode.platformDefault)
                Text(language.text("图片", "Image")).tag(AccountAvatarMode.image)
                Text("Emoji").tag(AccountAvatarMode.emoji)
            }
            .pickerStyle(.segmented)
            if mode == .emoji {
                TextField(language.text("一个 emoji", "One emoji"), text: $emojiDraft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: emojiDraft) { _ in
                        errorText = AccountAvatarEmoji.validationMessage(emojiDraft, language: language)
                    }
            }
            if mode == .image {
                HStack {
                    Button(language.text("选择图片…", "Choose image…"), action: pickImage)
                    Text(language.text("建议不小于 128×128，输出 256 PNG，不含位置信息。", "Prefer ≥128×128. Saved as a 256 PNG without location metadata."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if pickedImage != nil {
                    cropCanvas
                }
            }
            if let warningText {
                Text(warningText).font(.caption).foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
            Text(language.text("恢复默认不会删除账号，也不会改名称、调度或额度。", "Restoring the default does not delete the account or change its name, dispatch or quota."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(language.text("恢复默认", "Restore default")) {
                    mode = .platformDefault
                    emojiDraft = ""
                    pickedImage = nil
                    errorText = nil
                }
                Spacer()
                Button(language.text("取消", "Cancel"), action: onCancel)
                Button(language.text("保存", "Save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(errorText != nil)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func preview(slot: ProviderIconSlot) -> some View {
        VStack(spacing: 6) {
            AccountAvatarView(
                record: previewRecord,
                providerID: target.providerID,
                slot: slot,
                image: pickedImage
            )
            Text("\(Int(slot.container))pt").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var previewRecord: AccountAvatarRecord {
        switch mode {
        case .platformDefault: return .init(mode: .platformDefault)
        case .emoji: return .init(mode: .emoji, emoji: AccountAvatarEmoji.isolatedCluster(emojiDraft))
        case .image: return .init(mode: .image, assetID: "preview")
        }
    }

    private var cropCanvas: some View {
        ZStack {
            if let pickedImage {
                Image(nsImage: pickedImage)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(cropScale)
                    .offset(cropOffset)
            }
        }
        .frame(width: 160, height: 160)
        .clipped()
        .clipShape(Circle())
        .gesture(DragGesture().onChanged { cropOffset = $0.translation })
        .gesture(MagnificationGesture().onChanged { cropScale = max(1, $0) })
        .help(language.text("拖动和缩放以裁剪为正方形", "Drag and zoom to crop a square"))
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .bmp, .gif, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = language.text("选择头像图片", "Choose an avatar image")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch AccountAvatarImageProcessor.inspect(url: url) {
        case .failure(let reason):
            errorText = reason.message(language)
            return
        case .success(let info):
            if info.width < AccountAvatarImageProcessor.recommendedMinSide || info.height < AccountAvatarImageProcessor.recommendedMinSide {
                warningText = language.text("图片小于 128×128，放大后可能模糊。", "This image is smaller than 128×128 and may look soft.")
            } else {
                warningText = nil
            }
        }
        guard let image = NSImage(contentsOf: url) else {
            errorText = AccountAvatarImageProcessor.Rejection.undecodable.message(language)
            return
        }
        pickedImage = image
        mode = .image
        errorText = nil
        cropOffset = .zero
        cropScale = 1
    }

    private func save() {
        switch mode {
        case .platformDefault:
            onSave(.init(mode: .platformDefault), nil)
        case .emoji:
            if let message = AccountAvatarEmoji.validationMessage(emojiDraft, language: language) {
                errorText = message
                return
            }
            onSave(.init(mode: .emoji, emoji: AccountAvatarEmoji.isolatedCluster(emojiDraft)), nil)
        case .image:
            guard let pickedImage else {
                errorText = language.text("请先选择一张图片。", "Choose an image first.")
                return
            }
            let size = pickedImage.size
            let side = min(size.width, size.height)
            let crop = NSRect(
                x: (size.width - side) / 2 - cropOffset.width,
                y: (size.height - side) / 2 + cropOffset.height,
                width: side / cropScale,
                height: side / cropScale
            )
            guard let png = AccountAvatarImageProcessor.renderPNG(image: pickedImage, crop: crop) else {
                errorText = AccountAvatarImageProcessor.Rejection.undecodable.message(language)
                return
            }
            do {
                let assetID = try store.savePNG(png, profileID: target.profileID)
                onSave(.init(mode: .image, assetID: assetID), NSImage(data: png))
            } catch {
                errorText = language.text("头像未能保存到受管目录。", "The avatar could not be saved to the managed folder.")
            }
        }
    }
}
