import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AccountAvatarMode: String, Codable, CaseIterable {
    case platformDefault
    case image
    case emoji
}

struct AccountAvatarRecord: Codable, Equatable {
    var mode: AccountAvatarMode = .platformDefault
    var assetID: String?
    var emoji: String?

    func normalized() -> Self {
        var copy = self
        switch copy.mode {
        case .platformDefault:
            copy.assetID = nil
            copy.emoji = nil
        case .emoji:
            copy.assetID = nil
            copy.emoji = AccountAvatarEmoji.isolatedCluster(copy.emoji ?? "")
        case .image:
            copy.emoji = nil
            if (copy.assetID ?? "").isEmpty {
                copy.mode = .platformDefault
                copy.assetID = nil
            }
        }
        return copy
    }
}

struct AccountAvatarTable: Codable, Equatable {
    static let storageKey = "AiGoodBro.accountAvatars.v1"
    var schemaVersion = 1
    var byProfileID: [String: AccountAvatarRecord] = [:]

    static func load(_ data: Data?) -> Self {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        var table = value
        table.byProfileID = table.byProfileID.mapValues { $0.normalized() }
        return table
    }

    func record(for profileID: String) -> AccountAvatarRecord {
        byProfileID[profileID]?.normalized() ?? AccountAvatarRecord()
    }

    mutating func set(_ record: AccountAvatarRecord, for profileID: String) {
        let normalized = record.normalized()
        if normalized.mode == .platformDefault {
            byProfileID.removeValue(forKey: profileID)
        } else {
            byProfileID[profileID] = normalized
        }
    }

    mutating func restoreDefault(for profileID: String) {
        byProfileID.removeValue(forKey: profileID)
    }
}

struct AccountAvatarTarget: Identifiable, Equatable {
    var id: String { profileID }
    var profileID: String
    var providerID: String
    var displayName: String
}

enum AccountAvatarEmoji {
    static func isolatedCluster(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        guard trimmed.dropFirst().isEmpty else { return nil }
        let cluster = String(first)
        let hasEmoji = first.unicodeScalars.contains { $0.properties.isEmoji }
        return hasEmoji ? cluster : nil
    }

    static func validationMessage(_ raw: String, language: WidgetLanguage) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return language.text("请输入一个 emoji。", "Enter one emoji.")
        }
        if isolatedCluster(trimmed) == nil {
            return language.text("请只输入一个 emoji，不要用普通文字或多个符号。", "Use a single emoji, not plain text or several glyphs.")
        }
        return nil
    }
}

enum AccountAvatarImageProcessor {
    static let outputSize = 256
    static let maxBytes = 10 * 1024 * 1024
    static let maxSide = 8192
    static let recommendedMinSide = 128

    enum Rejection: Error, Equatable {
        case tooLarge
        case tooWide
        case undecodable
        case vector
        case empty

        func message(_ language: WidgetLanguage) -> String {
            switch self {
            case .tooLarge: language.text("图片不能超过 10MB。", "Images must be 10MB or smaller.")
            case .tooWide: language.text("单边不能超过 8192 像素。", "Each side must be 8192 pixels or smaller.")
            case .undecodable: language.text("无法解码这张图片。", "This image could not be decoded.")
            case .vector: language.text("不支持把矢量文件当作头像。", "Vector files cannot be used as avatars.")
            case .empty: language.text("没有可读的图像数据。", "No readable image data.")
            }
        }
    }

    static func inspect(url: URL) -> Result<(width: Int, height: Int, uti: String?), Rejection> {
        let ext = url.pathExtension.lowercased()
        if ["svg", "svgz", "eps", "pdf"].contains(ext) { return .failure(.vector) }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize, size > maxBytes { return .failure(.tooLarge) }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return .failure(.undecodable) }
        let uti = CGImageSourceGetType(source) as String?
        if let uti, uti.contains("svg") { return .failure(.vector) }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int,
            let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return .failure(.undecodable) }
        if width > maxSide || height > maxSide { return .failure(.tooWide) }
        if width <= 0 || height <= 0 { return .failure(.empty) }
        return .success((width, height, uti))
    }

    static func renderPNG(image: NSImage, crop: CGRect) -> Data? {
        let output = NSImage(size: NSSize(width: outputSize, height: outputSize))
        output.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: outputSize, height: outputSize).fill()
        let dest = NSRect(x: 0, y: 0, width: outputSize, height: outputSize)
        image.draw(in: dest, from: crop, operation: .copy, fraction: 1)
        output.unlockFocus()
        guard let tiff = output.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return png
    }
}

struct AccountAvatarAssetStore {
    var root: URL

    func url(for assetID: String) -> URL {
        root.appendingPathComponent("\(assetID).png")
    }

    func load(assetID: String) -> NSImage? {
        let url = url(for: assetID)
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    func savePNG(_ data: Data, profileID: String) throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let assetID = "avatar-\(stableToken(profileID))-\(UUID().uuidString.prefix(8))"
        let url = url(for: assetID)
        try data.write(to: url, options: .atomic)
        return assetID
    }

    func remove(assetID: String) {
        try? FileManager.default.removeItem(at: url(for: assetID))
    }

    private func stableToken(_ profileID: String) -> String {
        String(profileID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }
}

enum ProviderIconSlot: String, CaseIterable {
    case navigation
    case menu
    case list
    case card
    case detail
    case editor
    case badge

    var container: CGFloat {
        switch self {
        case .navigation: 20
        case .menu: 16
        case .list: 24
        case .card: 32
        case .detail: 48
        case .editor: 80
        case .badge: 14
        }
    }

    var glyph: CGFloat {
        switch self {
        case .navigation: 17
        case .menu: 16
        case .list: 24
        case .card: 32
        case .detail: 48
        case .editor: 80
        case .badge: 12
        }
    }

    var hitTarget: CGFloat {
        switch self {
        case .list, .navigation, .menu, .badge:
            container
        default:
            max(32, container)
        }
    }
}

enum ProviderIconMetrics {
    static let opticalRatio: CGFloat = 0.78
    static let avatarSpacing: CGFloat = 8
    static let emojiScale: CGFloat = 0.68

    static func opticalLayout(sourceWidth: CGFloat, sourceHeight: CGFloat, size: CGFloat, ratio: CGFloat = opticalRatio) -> CGRect {
        let box = max(1, size)
        let width = max(1, sourceWidth)
        let height = max(1, sourceHeight)
        let clampedRatio = min(1, max(0.5, ratio))
        let scale = (box * clampedRatio) / max(width, height)
        let drawWidth = width * scale
        let drawHeight = height * scale
        return CGRect(x: (box - drawWidth) / 2, y: (box - drawHeight) / 2, width: drawWidth, height: drawHeight)
    }

    static func badgeLayout(size: CGFloat) -> CGRect {
        let iconSize = max(16, size.rounded())
        let badgeSize = (iconSize * 0.43).rounded()
        let borderWidth = max(2, (iconSize * 0.045).rounded())
        let edgeInset = ceil(borderWidth / 2)
        return CGRect(
            x: iconSize - badgeSize - edgeInset,
            y: iconSize - badgeSize - edgeInset,
            width: badgeSize,
            height: badgeSize
        )
    }
}

struct AnchoredMenuAction: Identifiable, Equatable {
    var id: String
    var title: String
    var destructive = false
    var disabled = false
}

struct AnchoredMenuRequest: Equatable {
    var ownerID: String
    var actions: [AnchoredMenuAction]

    func action(id: String) -> AnchoredMenuAction? {
        actions.first { $0.id == id }
    }
}

enum ExecutionPreferenceCompactCopy {
    /// Compact labels must not repeat the main model name that already starts the summary.
    static func compactSummary(modelName: String, summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == modelName { return trimmed }
        let prefix = modelName + " · "
        if trimmed.hasPrefix(prefix) { return trimmed }
        if trimmed.hasPrefix(modelName) {
            let rest = trimmed.dropFirst(modelName.count).trimmingCharacters(in: CharacterSet(charactersIn: " ·"))
            return rest.isEmpty ? trimmed : trimmed
        }
        return trimmed
    }

    static func showsDuplicateModelName(modelName: String, visibleLine: String) -> Bool {
        guard let first = visibleLine.range(of: modelName) else { return false }
        return visibleLine[first.upperBound...].contains(modelName)
    }
}
