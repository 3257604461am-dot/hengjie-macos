import AppKit
import ImageIO
import UniformTypeIdentifiers
import HengJieCore

enum ScreenshotHistoryKind: String, Codable, CaseIterable, Sendable {
    case standard, horizontal, vertical

    var title: String {
        switch self {
        case .standard: "普通截图"
        case .horizontal: "横向长图"
        case .vertical: "纵向长图"
        }
    }

    var symbolName: String {
        switch self {
        case .standard: "viewfinder"
        case .horizontal: "arrow.left.and.right"
        case .vertical: "arrow.up.and.down"
        }
    }
}

enum ScreenshotDraftState: String, Codable, Sendable {
    case draft, completed
    var title: String { self == .draft ? "草稿" : "已完成" }
}

enum ScreenshotHistoryFilter: Int, CaseIterable {
    case all, standard, horizontal, vertical

    var title: String {
        switch self {
        case .all: "全部"
        case .standard: "普通"
        case .horizontal: "横向"
        case .vertical: "纵向"
        }
    }

    func matches(_ kind: ScreenshotHistoryKind) -> Bool {
        switch self {
        case .all: true
        case .standard: kind == .standard
        case .horizontal: kind == .horizontal
        case .vertical: kind == .vertical
        }
    }
}

struct ScreenshotHistoryItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var kind: ScreenshotHistoryKind
    var state: ScreenshotDraftState
    var createdAt: Date
    var updatedAt: Date
    var pixelWidth: Int
    var pixelHeight: Int
    var displayWidth: Double
    var displayHeight: Double
    var byteCount: Int64
}

struct ScreenshotProject: Codable, Sendable {
    static let currentVersion = 1
    var version: Int
    var displayWidth: Double
    var displayHeight: Double
    var annotations: [AnnotationMarkRecord]

    init(displaySize: CGSize, annotations: [AnnotationMarkRecord] = []) {
        version = Self.currentVersion
        displayWidth = Double(displaySize.width)
        displayHeight = Double(displaySize.height)
        self.annotations = annotations
    }
}

struct LoadedScreenshotProject {
    let item: ScreenshotHistoryItem
    let image: CGImage
    let project: ScreenshotProject
    let annotationRecoveryWarning: String?
}

enum ScreenshotHistoryError: LocalizedError {
    case imageEncodingFailed
    case missingImage
    case invalidImage
    case itemTooLarge

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed: "无法编码截图。"
        case .missingImage: "截图底图文件已丢失。"
        case .invalidImage: "截图底图已损坏，无法打开。"
        case .itemTooLarge: "截图超过 2GB 历史容量限制，未保存草稿。"
        }
    }
}

private actor ScreenshotHistoryStore {
    private let rootURL: URL
    private let indexURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL) {
        self.rootURL = rootURL
        indexURL = rootURL.appendingPathComponent("index.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadIndex() -> [ScreenshotHistoryItem] {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: indexURL),
              let values = try? decoder.decode([ScreenshotHistoryItem].self, from: data) else {
            let recovered = recoverItems()
            try? encoder.encode(recovered).write(to: indexURL, options: .atomic)
            removeOrphans(referenced: Set(recovered.map(\.id)))
            return recovered
        }
        let sorted = values.sorted { $0.updatedAt > $1.updatedAt }
        removeOrphans(referenced: Set(sorted.map(\.id)))
        return sorted
    }

    func create(item: ScreenshotHistoryItem, imageData: Data, thumbnailData: Data, project: ScreenshotProject) throws -> ScreenshotHistoryItem {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let directory = directory(for: item.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let projectData = try encoder.encode(project)
            try imageData.write(to: directory.appendingPathComponent("source.png"), options: .atomic)
            try thumbnailData.write(to: directory.appendingPathComponent("thumbnail.png"), options: .atomic)
            try projectData.write(to: directory.appendingPathComponent("project.json"), options: .atomic)
            var storedItem = item
            storedItem.byteCount = Int64(imageData.count + thumbnailData.count + projectData.count)
            try encoder.encode(storedItem).write(to: directory.appendingPathComponent("item.json"), options: .atomic)
            return storedItem
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func saveProject(_ project: ScreenshotProject, item: ScreenshotHistoryItem) throws -> ScreenshotHistoryItem {
        let directory = directory(for: item.id)
        let projectData = try encoder.encode(project)
        try projectData.write(to: directory.appendingPathComponent("project.json"), options: .atomic)
        var storedItem = item
        storedItem.byteCount = byteCount(in: directory)
        try encoder.encode(storedItem).write(to: directory.appendingPathComponent("item.json"), options: .atomic)
        return storedItem
    }

    func saveIndex(_ items: [ScreenshotHistoryItem]) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try encoder.encode(items).write(to: indexURL, options: .atomic)
    }

    func load(item: ScreenshotHistoryItem) throws -> (CGImage, ScreenshotProject?, String?) {
        let directory = directory(for: item.id)
        let imageURL = directory.appendingPathComponent("source.png")
        guard FileManager.default.fileExists(atPath: imageURL.path) else { throw ScreenshotHistoryError.missingImage }
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ScreenshotHistoryError.invalidImage }
        let projectURL = directory.appendingPathComponent("project.json")
        guard let projectData = try? Data(contentsOf: projectURL) else {
            return (image, nil, "标注工程文件已丢失，已仅打开原始底图。")
        }
        guard let project = try? decoder.decode(ScreenshotProject.self, from: projectData), project.version <= ScreenshotProject.currentVersion else {
            return (image, nil, "标注工程文件已损坏或版本过新，已仅打开原始底图。")
        }
        return (image, project, nil)
    }

    func thumbnailImage(id: UUID) -> CGImage? {
        let url = directory(for: id).appendingPathComponent("thumbnail.png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func remove(_ ids: [UUID]) {
        for id in ids { try? FileManager.default.removeItem(at: directory(for: id)) }
    }

    func clear() {
        try? FileManager.default.removeItem(at: rootURL)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func directory(for id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func byteCount(in directory: URL) -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return urls.reduce(0) { result, url in
            result + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func removeOrphans(referenced: Set<UUID>) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.lastPathComponent != "index.json" {
            if let id = UUID(uuidString: url.lastPathComponent), referenced.contains(id) { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func recoverItems() -> [ScreenshotHistoryItem] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return [] }
        return urls.compactMap { url -> ScreenshotHistoryItem? in
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: url.appendingPathComponent("item.json")),
                  var item = try? decoder.decode(ScreenshotHistoryItem.self, from: data) else { return nil }
            item.byteCount = byteCount(in: url)
            return item
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
}

@MainActor
final class ScreenshotHistoryService {
    static let shared = ScreenshotHistoryService()
    static let maximumItemCount = ScreenshotHistoryRetentionRules.maximumItemCount
    static let maximumTotalBytes = ScreenshotHistoryRetentionRules.maximumTotalBytes
    static let retentionInterval = ScreenshotHistoryRetentionRules.retentionInterval

    private(set) var items: [ScreenshotHistoryItem] = []
    private(set) var statusMessage: String?

    private let store: ScreenshotHistoryStore
    private let thumbnailCache = NSCache<NSUUID, NSImage>()
    private var pendingUpdates: [UUID: Task<Void, Never>] = [:]
    private var pendingCreations: [UUID: Task<Bool, Never>] = [:]
    private var observers: [UUID: () -> Void] = [:]

    private init(rootURL: URL? = nil) {
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("横截", isDirectory: true)
            .appendingPathComponent("ScreenshotHistory", isDirectory: true)
        store = ScreenshotHistoryStore(rootURL: root)
        thumbnailCache.totalCostLimit = 16 * 1_024 * 1_024
        Task { [weak self] in
            guard let self else { return }
            items = await store.loadIndex()
            await pruneAndPersist()
            notifyObservers()
        }
    }

    var isEnabled: Bool {
        AppPreferences.shared.screenshotHistoryEnabled && AppPreferences.shared.screenshotHistoryConsentCompleted
    }

    func filteredItems(_ filter: ScreenshotHistoryFilter) -> [ScreenshotHistoryItem] {
        items.filter { filter.matches($0.kind) }
    }

    func observe(_ handler: @escaping () -> Void) -> HistoryObservationToken {
        let id = UUID()
        observers[id] = handler
        return HistoryObservationToken { [weak self] in self?.observers[id] = nil }
    }

    func trimCaches() { thumbnailCache.removeAllObjects() }

    /// Reserves the history item immediately, then performs lossless encoding and
    /// persistence in the background so editor presentation is never gated on I/O.
    func create(image: CGImage, displaySize: CGSize, kind: ScreenshotHistoryKind) -> UUID? {
        guard isEnabled else { return nil }
        let now = Date()
        let item = ScreenshotHistoryItem(
            id: UUID(), kind: kind, state: .draft, createdAt: now, updatedAt: now,
            pixelWidth: image.width, pixelHeight: image.height,
            displayWidth: Double(displaySize.width), displayHeight: Double(displaySize.height), byteCount: 0
        )
        items.insert(item, at: 0)
        statusMessage = nil
        notifyObservers()

        let trace = PerformanceTrace.begin("ScreenshotDraftCreate")
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            let encoded = await Task.detached(priority: .utility) { () -> (Data, Data)? in
                guard let imageData = Self.pngData(image),
                      let thumbnailData = Self.thumbnailData(from: imageData) else { return nil }
                return (imageData, thumbnailData)
            }.value
            defer { PerformanceTrace.end("ScreenshotDraftCreate", trace) }
            guard !Task.isCancelled else { return false }
            guard let (imageData, thumbnailData) = encoded else {
                failCreation(id: item.id, error: ScreenshotHistoryError.imageEncodingFailed)
                return false
            }
            guard Int64(imageData.count + thumbnailData.count) < Self.maximumTotalBytes else {
                failCreation(id: item.id, error: ScreenshotHistoryError.itemTooLarge)
                return false
            }
            do {
                let stored = try await store.create(
                    item: item,
                    imageData: imageData,
                    thumbnailData: thumbnailData,
                    project: ScreenshotProject(displaySize: displaySize)
                )
                if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = stored }
                pendingCreations[item.id] = nil
                await pruneAndPersist()
                notifyObservers()
                return true
            } catch {
                failCreation(id: item.id, error: error)
                return false
            }
        }
        pendingCreations[item.id] = task
        return item.id
    }

    func scheduleUpdate(id: UUID, annotations: [AnnotationMarkRecord]) {
        guard isEnabled, items.contains(where: { $0.id == id }) else { return }
        pendingUpdates[id]?.cancel()
        pendingUpdates[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await persist(id: id, annotations: annotations, completed: false)
        }
    }

    func complete(id: UUID, annotations: [AnnotationMarkRecord]) {
        pendingUpdates[id]?.cancel()
        pendingUpdates[id] = nil
        Task { [weak self] in await self?.persist(id: id, annotations: annotations, completed: true) }
    }

    func load(id: UUID) async throws -> LoadedScreenshotProject {
        if let creation = pendingCreations[id], !(await creation.value) { throw ScreenshotHistoryError.missingImage }
        guard let item = items.first(where: { $0.id == id }) else { throw ScreenshotHistoryError.missingImage }
        let (image, storedProject, warning) = try await store.load(item: item)
        let fallback = ScreenshotProject(displaySize: CGSize(width: item.displayWidth, height: item.displayHeight))
        return LoadedScreenshotProject(item: item, image: image, project: storedProject ?? fallback, annotationRecoveryWarning: warning)
    }

    func loadThumbnail(for item: ScreenshotHistoryItem, completion: @escaping (NSImage?) -> Void) {
        if let cached = thumbnailCache.object(forKey: item.id as NSUUID) { completion(cached); return }
        Task { [weak self] in
            guard let self else { return }
            if let creation = pendingCreations[item.id], !(await creation.value) { completion(nil); return }
            let cgImage = await store.thumbnailImage(id: item.id)
            let image = cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            if let image, let cgImage {
                thumbnailCache.setObject(image, forKey: item.id as NSUUID, cost: cgImage.bytesPerRow * cgImage.height)
            }
            completion(image)
        }
    }

    func delete(_ id: UUID) {
        pendingCreations[id]?.cancel()
        pendingCreations[id] = nil
        pendingUpdates[id]?.cancel()
        pendingUpdates[id] = nil
        items.removeAll { $0.id == id }
        thumbnailCache.removeObject(forKey: id as NSUUID)
        Task { await store.remove([id]); await saveIndex() }
        notifyObservers()
    }

    func clearAll() {
        pendingCreations.values.forEach { $0.cancel() }
        pendingCreations.removeAll()
        pendingUpdates.values.forEach { $0.cancel() }
        pendingUpdates.removeAll()
        items.removeAll()
        thumbnailCache.removeAllObjects()
        statusMessage = nil
        Task { await store.clear(); try? await store.saveIndex([]) }
        notifyObservers()
    }

    private func persist(id: UUID, annotations: [AnnotationMarkRecord], completed: Bool) async {
        pendingUpdates[id] = nil
        if let creation = pendingCreations[id], !(await creation.value) { return }
        guard isEnabled, let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        let project = ScreenshotProject(displaySize: CGSize(width: item.displayWidth, height: item.displayHeight), annotations: annotations)
        do {
            var metadata = item
            metadata.updatedAt = Date()
            if completed { metadata.state = .completed }
            let stored = try await store.saveProject(project, item: metadata)
            guard let refreshed = items.firstIndex(where: { $0.id == id }) else { return }
            items[refreshed] = stored
            items.sort { $0.updatedAt > $1.updatedAt }
            await pruneAndPersist()
            statusMessage = nil
            notifyObservers()
        } catch {
            statusMessage = "草稿更新失败：\(error.localizedDescription)"
            notifyObservers()
        }
    }

    private func pruneAndPersist() async {
        var removed = items.filter { ScreenshotHistoryRetentionRules.isExpired(updatedAt: $0.updatedAt) }.map(\.id)
        items.removeAll { ScreenshotHistoryRetentionRules.isExpired(updatedAt: $0.updatedAt) }
        while ScreenshotHistoryRetentionRules.exceedsCapacity(
            itemCount: items.count,
            totalBytes: items.reduce(Int64(0), { $0 + $1.byteCount })
        ) {
            if let item = items.popLast() { removed.append(item.id) } else { break }
        }
        if !removed.isEmpty { await store.remove(removed) }
        try? await store.saveIndex(items)
    }

    private func saveIndex() async { try? await store.saveIndex(items) }

    private func failCreation(id: UUID, error: Error) {
        pendingCreations[id] = nil
        items.removeAll { $0.id == id }
        statusMessage = "草稿保存失败：\(error.localizedDescription)"
        notifyObservers()
    }

    private func notifyObservers() {
        observers.values.forEach { $0() }
    }

    nonisolated private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    nonisolated private static func thumbnailData(from imageData: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 280
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return pngData(image)
    }
}
