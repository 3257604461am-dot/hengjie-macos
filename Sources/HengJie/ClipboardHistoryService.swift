import AppKit
import CryptoKit
import HengJieCore
import ImageIO
import UniformTypeIdentifiers

enum ClipboardHistoryKind: String, Codable, Sendable {
    case text, richText, link, image

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

enum ClipboardHistoryFilter: Int, CaseIterable {
    case all, text, link, image, pinned

    var title: String {
        switch self {
        case .all: "全部"
        case .text: "文字"
        case .link: "链接"
        case .image: "图片"
        case .pinned: "已固定"
        }
    }
}

enum ClipboardHistoryTimeFilter: Int, CaseIterable {
    case all, today, week, month
    var title: String {
        switch self {
        case .all: "全部时间"
        case .today: "今天"
        case .week: "最近 7 天"
        case .month: "最近 30 天"
        }
    }
    func contains(_ date: Date, now: Date = Date()) -> Bool {
        switch self {
        case .all: true
        case .today: Calendar.current.isDate(date, inSameDayAs: now)
        case .week: date >= now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .month: date >= now.addingTimeInterval(-30 * 24 * 60 * 60)
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
    var searchText: String?
    var thumbnailFileName: String?
}

private struct ClipboardSnapshot: Sendable {
    let rawTypes: Set<String>
    let plainText: String?
    let urlText: String?
    let rtfData: Data?
    let htmlData: Data?
    let imageData: Data?
}

private struct CapturedRepresentation: Sendable {
    let type: String
    let data: Data
    let fileExtension: String
}

private struct ClipboardCapturedPayload: Sendable {
    let kind: ClipboardHistoryKind
    let previewText: String
    let searchText: String?
    let contentHash: String
    let byteCount: Int64
    let representations: [CapturedRepresentation]
    let thumbnailData: Data?
}

private enum ClipboardProcessingError: Error, Sendable {
    case ignored
    case rejected(String)
}

private actor ClipboardHistoryProcessor {
    func process(_ snapshot: ClipboardSnapshot) -> Result<ClipboardCapturedPayload, ClipboardProcessingError> {
        if let url = snapshot.urlText, URL(string: url)?.pathExtension.lowercased() == "gif" {
            return .failure(.ignored)
        }
        var representations: [CapturedRepresentation] = []
        var kind: ClipboardHistoryKind = .text
        var preview = ""
        var searchSource = ""
        var thumbnail: Data?

        if let imageData = snapshot.imageData {
            guard imageData.count <= ClipboardHistoryRules.maximumItemBytes,
                  let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let type = CGImageSourceGetType(source).map({ UTType($0 as String) }),
                  type?.conforms(to: .gif) != true,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let normalized = encodePNG(image),
                  normalized.count <= ClipboardHistoryRules.maximumItemBytes
            else { return .failure(.rejected("最近一项图片超过 50MB、属于 GIF 或无法解码，未加入历史。")) }
            kind = .image
            preview = "静态图片"
            representations.append(.init(type: NSPasteboard.PasteboardType.png.rawValue, data: normalized, fileExtension: "png"))
            thumbnail = makeThumbnail(from: source)
        } else {
            if let value = snapshot.plainText, let data = value.data(using: .utf8) {
                representations.append(.init(type: NSPasteboard.PasteboardType.string.rawValue, data: data, fileExtension: "txt"))
                preview = value
                searchSource += value + "\n"
            }
            if let value = snapshot.urlText, let data = value.data(using: .utf8) {
                representations.append(.init(type: NSPasteboard.PasteboardType.URL.rawValue, data: data, fileExtension: "url"))
                if preview.isEmpty { preview = value }
                searchSource += value + "\n"
                kind = .link
            }
            if let data = snapshot.rtfData {
                representations.append(.init(type: NSPasteboard.PasteboardType.rtf.rawValue, data: data, fileExtension: "rtf"))
                let text = attributedPlainText(data: data, documentType: .rtf)
                if preview.isEmpty { preview = text }
                searchSource += text + "\n"
                if kind != .link { kind = .richText }
            }
            if let data = snapshot.htmlData {
                representations.append(.init(type: NSPasteboard.PasteboardType.html.rawValue, data: data, fileExtension: "html"))
                let text = attributedPlainText(data: data, documentType: .html)
                if preview.isEmpty { preview = text }
                searchSource += text + "\n"
                if kind != .link { kind = .richText }
            }
        }

        guard !representations.isEmpty else { return .failure(.ignored) }
        let total = representations.reduce(Int64(0)) { $0 + Int64($1.data.count) }
        guard total <= ClipboardHistoryRules.maximumItemBytes else {
            return .failure(.rejected("最近一项超过 50MB，未加入历史。"))
        }
        var hasher = SHA256()
        for representation in representations.sorted(by: { $0.type < $1.type }) {
            hasher.update(data: Data(representation.type.utf8))
            hasher.update(data: representation.data)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .success(ClipboardCapturedPayload(
            kind: kind,
            previewText: ClipboardHistoryRules.normalizedPreview(preview),
            searchText: kind == .image ? nil : ClipboardHistoryRules.normalizedSearchText(searchSource),
            contentHash: hash,
            byteCount: total,
            representations: representations,
            thumbnailData: thumbnail
        ))
    }

    private func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func makeThumbnail(from source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 180
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encodePNG(image)
    }

    private func attributedPlainText(data: Data, documentType: NSAttributedString.DocumentType) -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: documentType]
        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil).string) ?? ""
    }
}

private actor ClipboardHistoryStore {
    private let rootURL: URL
    private let payloadsURL: URL
    private let indexURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        payloadsURL = rootURL.appendingPathComponent("Payloads", isDirectory: true)
        indexURL = rootURL.appendingPathComponent("index.json")
    }

    func load() -> [ClipboardHistoryItem] {
        try? FileManager.default.createDirectory(at: payloadsURL, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: indexURL) else {
            removeOrphans(referencedIDs: [])
            return []
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let items = try decoder.decode([ClipboardHistoryItem].self, from: data).sorted { $0.lastUsedAt > $1.lastUsedAt }
            removeOrphans(referencedIDs: Set(items.map(\.id)))
            return items
        } catch {
            try? FileManager.default.removeItem(at: indexURL)
            try? FileManager.default.removeItem(at: payloadsURL)
            try? FileManager.default.createDirectory(at: payloadsURL, withIntermediateDirectories: true)
            return []
        }
    }

    func saveIndex(_ items: [ClipboardHistoryItem]) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(items).write(to: indexURL, options: .atomic)
    }

    func writePayload(id: UUID, payload: ClipboardCapturedPayload) throws -> ([ClipboardRepresentation], String?) {
        let directory = payloadDirectory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stored: [ClipboardRepresentation] = []
        do {
            for (index, representation) in payload.representations.enumerated() {
                let name = "\(index).\(representation.fileExtension)"
                try representation.data.write(to: directory.appendingPathComponent(name), options: .atomic)
                stored.append(.init(typeIdentifier: representation.type, fileName: name))
            }
            let thumbnailName = payload.thumbnailData == nil ? nil : "thumbnail.png"
            if let data = payload.thumbnailData, let thumbnailName {
                try data.write(to: directory.appendingPathComponent(thumbnailName), options: .atomic)
            }
            return (stored, thumbnailName)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func readPayload(_ item: ClipboardHistoryItem) -> [(String, Data)] {
        item.representations.compactMap { representation in
            let url = payloadDirectory(for: item.id).appendingPathComponent(representation.fileName)
            return (try? Data(contentsOf: url)).map { (representation.typeIdentifier, $0) }
        }
    }

    func thumbnailData(for item: ClipboardHistoryItem) -> Data? {
        guard let name = item.thumbnailFileName else { return nil }
        return try? Data(contentsOf: payloadDirectory(for: item.id).appendingPathComponent(name))
    }

    func remove(_ ids: [UUID]) {
        ids.forEach { try? FileManager.default.removeItem(at: payloadDirectory(for: $0)) }
    }

    func clear() {
        try? FileManager.default.removeItem(at: payloadsURL)
        try? FileManager.default.createDirectory(at: payloadsURL, withIntermediateDirectories: true)
    }

    private func payloadDirectory(for id: UUID) -> URL {
        payloadsURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func removeOrphans(referencedIDs: Set<UUID>) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: payloadsURL, includingPropertiesForKeys: nil) else { return }
        for url in urls where UUID(uuidString: url.lastPathComponent).map({ !referencedIDs.contains($0) }) ?? true {
            try? FileManager.default.removeItem(at: url)
        }
    }
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
    private let processor = ClipboardHistoryProcessor()
    private let store: ClipboardHistoryStore
    private let imageCache = NSCache<NSUUID, NSImage>()
    private var timer: Timer?
    private var observedChangeCount = 0
    private var ignoredChangeCount: Int?
    private var saveTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var wantsRunning = false
    private var waitingForRestore = false

    init(pasteboard: NSPasteboard = .general, rootURL: URL? = nil) {
        self.pasteboard = pasteboard
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("横截", isDirectory: true)
            .appendingPathComponent("ClipboardHistory", isDirectory: true)
        store = ClipboardHistoryStore(rootURL: root)
        imageCache.totalCostLimit = 12 * 1_024 * 1_024
        restoreTask = Task { [weak self] in
            guard let self else { return }
            items = await store.load()
            pruneExpired()
            scheduleSave()
            onChange?()
        }
    }

    var isRunning: Bool { timer != nil }

    func start() {
        wantsRunning = true
        guard timer == nil, !waitingForRestore else { return }
        if let restoreTask {
            waitingForRestore = true
            Task { [weak self] in
                await restoreTask.value
                guard let self else { return }
                waitingForRestore = false
                self.restoreTask = nil
                guard wantsRunning, timer == nil else { return }
                startTimer()
            }
            return
        }
        startTimer()
    }

    private func startTimer() {
        observedChangeCount = pasteboard.changeCount
        ignoredChangeCount = nil
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPasteboard() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DiagnosticLogger.shared.log("clipboard", "monitor_started")
    }

    func stop() {
        wantsRunning = false
        timer?.invalidate()
        timer = nil
        ignoredChangeCount = nil
        DiagnosticLogger.shared.log("clipboard", "monitor_stopped")
    }

    func filteredItems(query: String, filter: ClipboardHistoryFilter, timeFilter: ClipboardHistoryTimeFilter = .all) -> [ClipboardHistoryItem] {
        items.filter { item in
            let typeMatches: Bool = switch filter {
            case .all: true
            case .text: item.kind == .text || item.kind == .richText
            case .link: item.kind == .link
            case .image: item.kind == .image
            case .pinned: item.isPinned
            }
            guard typeMatches, timeFilter.contains(item.lastUsedAt) else { return false }
            let searchable = item.searchText ?? item.previewText
            return ClipboardHistoryRules.matches(searchText: searchable, query: query)
        }
    }

    func copyToPasteboard(_ item: ClipboardHistoryItem) {
        Task { [weak self] in
            guard let self else { return }
            let values = await store.readPayload(item)
            guard !values.isEmpty else {
                statusMessage = "历史内容文件已丢失，无法复制。"
                onChange?()
                return
            }
            let pasteboardItem = NSPasteboardItem()
            for (identifier, data) in values {
                let type = NSPasteboard.PasteboardType(identifier)
                if (type == .string || type == .URL), let value = String(data: data, encoding: .utf8) {
                    pasteboardItem.setString(value, forType: type)
                } else { pasteboardItem.setData(data, forType: type) }
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([pasteboardItem])
            observedChangeCount = pasteboard.changeCount
            ignoredChangeCount = observedChangeCount
            touch(item.id)
        }
    }

    func loadPreview(for item: ClipboardHistoryItem, completion: @escaping (NSImage?) -> Void) {
        guard item.kind == .image else { completion(nil); return }
        if let cached = imageCache.object(forKey: item.id as NSUUID) { completion(cached); return }
        Task { [weak self] in
            guard let self else { return }
            let data = await store.thumbnailData(for: item)
            let image = data.flatMap(NSImage.init(data:))
            if let image { imageCache.setObject(image, forKey: item.id as NSUUID, cost: data?.count ?? 0) }
            completion(image)
        }
    }

    func togglePinned(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
        scheduleSave(); onChange?()
    }

    func delete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        imageCache.removeObject(forKey: id as NSUUID)
        Task { await store.remove([id]) }
        statusMessage = nil
        scheduleSave(); onChange?()
    }

    func clearUnpinned() {
        let removed = items.filter { !$0.isPinned }.map(\.id)
        items.removeAll { !$0.isPinned }
        removed.forEach { imageCache.removeObject(forKey: $0 as NSUUID) }
        Task { await store.remove(removed) }
        statusMessage = nil
        scheduleSave(); onChange?()
    }

    func clearAll() {
        items.removeAll()
        imageCache.removeAllObjects()
        Task { await store.clear(); try? await store.saveIndex([]) }
        statusMessage = nil
        onChange?()
    }

    private func pollPasteboard() {
        let current = pasteboard.changeCount
        guard current != observedChangeCount else { return }
        observedChangeCount = current
        if ignoredChangeCount == current { ignoredChangeCount = nil; return }
        guard let item = pasteboard.pasteboardItems?.first else { return }
        let rawTypes = Set(item.types.map(\.rawValue))
        guard !containsExcludedType(rawTypes) else { return }
        let imageData = item.data(forType: .png)
            ?? item.data(forType: NSPasteboard.PasteboardType("public.jpeg"))
            ?? item.data(forType: .tiff)
        let snapshot = ClipboardSnapshot(
            rawTypes: rawTypes,
            plainText: item.string(forType: .string),
            urlText: item.string(forType: .URL),
            rtfData: item.data(forType: .rtf),
            htmlData: item.data(forType: .html),
            imageData: imageData
        )
        Task { [weak self] in
            guard let self else { return }
            switch await processor.process(snapshot) {
            case let .success(payload): await add(payload)
            case let .failure(.rejected(message)):
                statusMessage = message; onChange?()
            case .failure(.ignored): break
            }
        }
    }

    private func add(_ payload: ClipboardCapturedPayload) async {
        if let index = items.firstIndex(where: { $0.contentHash == payload.contentHash }) {
            var duplicate = items.remove(at: index)
            duplicate.lastUsedAt = Date()
            items.insert(duplicate, at: 0)
            statusMessage = nil
            scheduleSave(); onChange?()
            return
        }
        pruneExpired()
        var removed: [UUID] = []
        while items.count >= Self.maximumItemCount || totalBytes + payload.byteCount > Self.maximumTotalBytes {
            guard let index = items.lastIndex(where: { !$0.isPinned }) else {
                statusMessage = "历史已满且全部固定，请取消固定或删除部分记录。"
                onChange?(); return
            }
            removed.append(items.remove(at: index).id)
        }
        if !removed.isEmpty { await store.remove(removed) }
        let id = UUID()
        do {
            let stored = try await store.writePayload(id: id, payload: payload)
            let now = Date()
            items.insert(ClipboardHistoryItem(
                id: id, kind: payload.kind, createdAt: now, lastUsedAt: now, isPinned: false,
                previewText: payload.previewText, contentHash: payload.contentHash, byteCount: payload.byteCount,
                representations: stored.0, searchText: payload.searchText, thumbnailFileName: stored.1
            ), at: 0)
            statusMessage = nil
            scheduleSave(); onChange?()
        } catch {
            statusMessage = "无法保存剪贴板历史：\(error.localizedDescription)"
            onChange?()
        }
    }

    private func touch(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.lastUsedAt = Date()
        items.insert(item, at: 0)
        scheduleSave(); onChange?()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = items
        saveTask = Task { [store] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            try? await store.saveIndex(snapshot)
        }
    }

    private func pruneExpired() {
        let removed = items.filter { ClipboardHistoryRules.isExpired(lastUsedAt: $0.lastUsedAt, isPinned: $0.isPinned) }.map(\.id)
        items.removeAll { ClipboardHistoryRules.isExpired(lastUsedAt: $0.lastUsedAt, isPinned: $0.isPinned) }
        if !removed.isEmpty { Task { await store.remove(removed) } }
    }

    private var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteCount } }

    private func containsExcludedType(_ types: Set<String>) -> Bool {
        let fragments = [
            "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
            "public.file-url", "NSFilenamesPboardType", "public.gif", "com.compuserve.gif", "public.movie",
            "public.video", "public.audio", "public.audiovisual-content", "public.mp3", "public.mpeg",
            "public.avi", "com.apple.m4v-video", "com.apple.quicktime-movie"
        ]
        return types.contains { type in fragments.contains { type.localizedCaseInsensitiveContains($0) } }
    }
}
