import AppKit
import HengJieCore
import ImageIO
import UniformTypeIdentifiers

enum ImageExport {
    static func copy(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @MainActor
    static func copy(_ image: CGImage, displaySize: CGSize) {
        copy(NSImage(cgImage: image, size: displaySize))
    }

    @MainActor
    static func saveAsync(_ image: CGImage, format: String) async throws -> Bool {
        guard let request = destination(format: format) else { return false }
        let trace = PerformanceTrace.begin("ImageExport")
        defer { PerformanceTrace.end("ImageExport", trace) }
        try await Task.detached(priority: .userInitiated) {
            try encode(image, to: request.url, type: request.type)
        }.value
        return true
    }

    @MainActor
    private static func destination(format: String) -> (url: URL, type: UTType)? {
        let panel = NSSavePanel()
        let isJPEG = format.lowercased() == "jpeg" || format.lowercased() == "jpg"
        panel.allowedContentTypes = [isJPEG ? .jpeg : .png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "横截 \(formatter.string(from: Date())).\(isJPEG ? "jpg" : "png")"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, isJPEG ? .jpeg : .png)
    }

    nonisolated private static func encode(_ image: CGImage, to url: URL, type: UTType) throws {
        let options: [CFString: Any] = type == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.92]
            : [:]
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
