import AppKit
import CryptoKit
import HengJieCore

enum ClipboardHistoryKind: String, Codable, Sendable {
    case text
    case richText
    case link
    case image

    var title: String {
        switch self {
        case .text: "文字"
        case .richText: "富文本"
        case .link: "链接"
        case .image: "图片"
        }
    }

    var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .link: "link"
        case .image: "photo"
        }
    }
}

struct ClipboardRepresentation: Codable, Hashable, Sendable {
    let typeIdentifier: String
    let fileName: String
}

struct ClipboardHistoryItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var kind: ClipboardHistoryKind
    var createdAt: Date
    var lastUsedAt: Date
    var isPinned: Bool
    var previewText: String
    var contentHash: String
    var byteCount: Int64
    var representations: [ClipboardRepresentation]
}

private struct ClipboardCapturedPayload {
    let kind: ClipboardHistoryKind
    let previewText: String
    let contentHash: String
    let byteCount: Int64
    let representations: [(type: String, data: Data, extension: String)]
}

@MainActor
final class ClipboardHistoryService {
    static let maximumItemBytes = ClipboardHistoryRules.maximumItemBytes
    static let maximumTotalBytes = ClipboardHistoryRules.maximumTotalBytes
    static let maximumItemCount = ClipboardHistoryRules.maximumItemCount

    private(set) var items: [ClipboardHistoryItem] = []
    private(set) var statusMessage: String?
    var onChange: (() -> Void)?

    private let pasteboard: NSPasteboard
    private let payloadsURL: URL
    private let indexURL: URL
    private var timer: Timer?
    private var observedChangeCount = 0
    private var ignoredChangeCount: Int?

    init(pasteboard: NSPasteboard = .general, rootURL: URL? = nil) {
        self.pasteboard = pasteboard
        let baseURL = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("横截", isDirectory: true)
            .appendingPathComponent("ClipboardHistory", isDirectory: true)
        payloadsURL = baseURL.appendingPathComponent("Payloads", isDirectory: true)
        indexURL = baseURL.appendingPathComponent("index.json")
        prepareStorage()
        loadIndex()
        pruneAndPersistIfNeeded()
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        observedChangeCount = pasteboard.changeCount
        ignoredChangeCount = nil
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPasteboard() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        ignoredChangeCount = nil
    }

    func copyToPasteboard(_ item: ClipboardHistoryItem) {
        let pasteboardItem = NSPasteboardItem()
        var wroteRepresentation = false
        for representation in item.representations {
            let url = payloadDirectory(for: item.id).appendingPathComponent(representation.fileName)
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = NSPasteboard.PasteboardType(representation.typeIdentifier)
            if (type == .string || type == .URL), let value = String(data: data, encoding: .utf8) {
                pasteboardItem.setString(value, forType: type)
            } else {
                pasteboardItem.setData(data, forType: type)
            }
            wroteRepresentation = true
        }
        guard wroteRepresentation else {
            statusMessage = "历史内容文件已丢失，无法复制。"
            onChange?()
            return
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([pasteboardItem])
        observedChangeCount = pasteboard.changeCount
        ignoredChangeCount = observedChangeCount
        touch(item.id)
    }

    func togglePinned(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
        saveIndex()
        onChange?()
    }

    func delete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        try? FileManager.default.removeItem(at: payloadDirectory(for: item.id))
        statusMessage = nil
        saveIndex()
        onChange?()
    }

    func clearUnpinned() {
        let removed = items.filter { !$0.isPinned }
        items.removeAll { !$0.isPinned }
        removed.forEach { try? FileManager.default.removeItem(at: payloadDirectory(for: $0.id)) }
        statusMessage = nil
        saveIndex()
        onChange?()
    }

    func clearAll() {
        items.removeAll()
        try? FileManager.default.removeItem(at: payloadsURL)
        try? FileManager.default.createDirectory(at: payloadsURL, withIntermediateDirectories: true)
        statusMessage = nil
        saveIndex()
        onChange?()
    }

    func previewImage(for item: ClipboardHistoryItem) -> NSImage? {
        guard item.kind == .image,
              let representation = item.representations.first,
              let data = try? Data(contentsOf: payloadDirectory(for: item.id).appendingPathComponent(representation.fileName))
        else { return nil }
        return NSImage(data: data)
    }

    private func pollPasteboard() {
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != observedChangeCount else { return }
        observedChangeCount = currentChangeCount
        if ignoredChangeCount == currentChangeCount {
            ignoredChangeCount = nil
            return
        }
        guard let payload = capturePayload() else { return }
        add(payload)
    }

    private func capturePayload() -> ClipboardCapturedPayload? {
        guard let source = pasteboard.pasteboardItems?.first else { return nil }
        let rawTypes = Set(source.types.map(\.rawValue))
        guard !containsExcludedType(rawTypes) else { return nil }
        if let urlText = source.string(forType: .URL), URL(string: urlText)?.pathExtension.lowercased() == "gif" {
            return nil
        }

        var representations: [(type: String, data: Data, extension: String)] = []
        var kind: ClipboardHistoryKind = .text
        var preview = ""

        let pngType = NSPasteboard.PasteboardType.png
        let tiffType = NSPasteboard.PasteboardType.tiff
        let jpegType = NSPasteboard.PasteboardType("public.jpeg")
        if let imageData = source.data(forType: pngType) ?? source.data(forType: jpegType) ?? source.data(forType: tiffType) {
            guard imageData.count <= Self.maximumItemBytes,
                  let normalized = normalizedPNG(from: imageData), normalized.count <= Self.maximumItemBytes
            else {
                statusMessage = "最近一项图片超过 50MB 或无法解码，未加入历史。"
                onChange?()
                return nil
            }
            kind = .image
            preview = "静态图片"
            representations.append((pngType.rawValue, normalized, "png"))
        } else {
            let plainText = source.string(forType: .string)
            let urlText = source.string(forType: .URL)
            let rtfData = source.data(forType: .rtf)
            let htmlData = source.data(forType: .html)

            if let value = plainText, let data = value.data(using: .utf8) {
                representations.append((NSPasteboard.PasteboardType.string.rawValue, data, "txt"))
                preview = value
            }
            if let value = urlText, let data = value.data(using: .utf8) {
                representations.append((NSPasteboard.PasteboardType.URL.rawValue, data, "url"))
                if preview.isEmpty { preview = value }
                kind = .link
            }
            if let data = rtfData {
                representations.append((NSPasteboard.PasteboardType.rtf.rawValue, data, "rtf"))
                if preview.isEmpty { preview = attributedPlainText(data: data, documentType: .rtf) }
                if kind != .link { kind = .richText }
            }
            if let data = htmlData {
                representations.append((NSPasteboard.PasteboardType.html.rawValue, data, "html"))
                if preview.isEmpty { preview = attributedPlainText(data: data, documentType: .html) }
                if kind != .link { kind = .richText }
            }
        }

        guard !representations.isEmpty else { return nil }
        let totalBytes = representations.reduce(Int64(0)) { $0 + Int64($1.data.count) }
        guard totalBytes <= Self.maximumItemBytes else {
            statusMessage = "最近一项超过 50MB，未加入历史。"
            onChange?()
            return nil
        }
        let hash = contentHash(for: representations)
        return ClipboardCapturedPayload(
            kind: kind,
            previewText: normalizedPreview(preview),
            contentHash: hash,
            byteCount: totalBytes,
            representations: representations
        )
    }

    private func add(_ payload: ClipboardCapturedPayload) {
        if let duplicateIndex = items.firstIndex(where: { $0.contentHash == payload.contentHash }) {
            var duplicate = items.remove(at: duplicateIndex)
            duplicate.lastUsedAt = Date()
            items.insert(duplicate, at: 0)
            statusMessage = nil
            saveIndex()
            onChange?()
            return
        }

        pruneExpired()
        while items.count >= Self.maximumItemCount || totalBytes + payload.byteCount > Self.maximumTotalBytes {
            guard let removalIndex = items.lastIndex(where: { !$0.isPinned }) else {
                statusMessage = "历史已满且全部固定，请取消固定或删除部分记录。"
                onChange?()
                return
            }
            let removed = items.remove(at: removalIndex)
            try? FileManager.default.removeItem(at: payloadDirectory(for: removed.id))
        }

        let id = UUID()
        let directory = payloadDirectory(for: id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var stored: [ClipboardRepresentation] = []
            for (index, representation) in payload.representations.enumerated() {
                let fileName = "\(index).\(representation.extension)"
                try representation.data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
                stored.append(ClipboardRepresentation(typeIdentifier: representation.type, fileName: fileName))
            }
            let now = Date()
            items.insert(ClipboardHistoryItem(
                id: id,
                kind: payload.kind,
                createdAt: now,
                lastUsedAt: now,
                isPinned: false,
                previewText: payload.previewText,
                contentHash: payload.contentHash,
                byteCount: payload.byteCount,
                representations: stored
            ), at: 0)
            statusMessage = nil
            saveIndex()
            onChange?()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            statusMessage = "无法保存剪贴板历史：\(error.localizedDescription)"
            onChange?()
        }
    }

    private func touch(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.lastUsedAt = Date()
        items.insert(item, at: 0)
        saveIndex()
        onChange?()
    }

    private func prepareStorage() {
        try? FileManager.default.createDirectory(at: payloadsURL, withIntermediateDirectories: true)
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL) else {
            removeOrphanedPayloads(referencedIDs: [])
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([ClipboardHistoryItem].self, from: data)
                .sorted { $0.lastUsedAt > $1.lastUsedAt }
            removeOrphanedPayloads(referencedIDs: Set(items.map(\.id)))
        } catch {
            try? FileManager.default.removeItem(at: indexURL)
            try? FileManager.default.removeItem(at: payloadsURL)
            try? FileManager.default.createDirectory(at: payloadsURL, withIntermediateDirectories: true)
            items = []
            statusMessage = "历史索引损坏，已安全重建。"
        }
    }

    private func saveIndex() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            statusMessage = "无法更新历史索引：\(error.localizedDescription)"
        }
    }

    private func pruneAndPersistIfNeeded() {
        let oldIDs = Set(items.map(\.id))
        pruneExpired()
        while items.count > Self.maximumItemCount || totalBytes > Self.maximumTotalBytes {
            guard let index = items.lastIndex(where: { !$0.isPinned }) else { break }
            let removed = items.remove(at: index)
            try? FileManager.default.removeItem(at: payloadDirectory(for: removed.id))
        }
        if Set(items.map(\.id)) != oldIDs { saveIndex() }
    }

    private func pruneExpired() {
        let now = Date()
        let removed = items.filter { ClipboardHistoryRules.isExpired(lastUsedAt: $0.lastUsedAt, isPinned: $0.isPinned, now: now) }
        items.removeAll { ClipboardHistoryRules.isExpired(lastUsedAt: $0.lastUsedAt, isPinned: $0.isPinned, now: now) }
        removed.forEach { try? FileManager.default.removeItem(at: payloadDirectory(for: $0.id)) }
    }

    private var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteCount } }

    private func payloadDirectory(for id: UUID) -> URL {
        payloadsURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func removeOrphanedPayloads(referencedIDs: Set<UUID>) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: payloadsURL, includingPropertiesForKeys: nil) else { return }
        for url in urls where UUID(uuidString: url.lastPathComponent).map({ !referencedIDs.contains($0) }) ?? true {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func normalizedPNG(from data: Data) -> Data? {
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func attributedPlainText(data: Data, documentType: NSAttributedString.DocumentType) -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: documentType]
        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil).string) ?? ""
    }

    private func normalizedPreview(_ value: String) -> String {
        ClipboardHistoryRules.normalizedPreview(value)
    }

    private func contentHash(for representations: [(type: String, data: Data, extension: String)]) -> String {
        var hasher = SHA256()
        for representation in representations.sorted(by: { $0.type < $1.type }) {
            hasher.update(data: Data(representation.type.utf8))
            hasher.update(data: representation.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func containsExcludedType(_ types: Set<String>) -> Bool {
        let excludedFragments = [
            "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType", "public.file-url", "NSFilenamesPboardType",
            "public.gif", "com.compuserve.gif", "public.movie", "public.video", "public.audio",
            "public.audiovisual-content", "public.mp3", "public.mpeg-4-audio", "public.mpeg",
            "public.avi", "com.apple.m4v-video", "com.apple.quicktime-movie"
        ]
        return types.contains { type in excludedFragments.contains { type.localizedCaseInsensitiveContains($0) } }
    }
}
