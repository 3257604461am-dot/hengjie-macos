import AppKit
import UniformTypeIdentifiers

enum ImageExport {
    static func copy(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @MainActor
    static func save(_ image: NSImage, format: String) throws {
        let panel = NSSavePanel()
        let isJPEG = format.lowercased() == "jpeg" || format.lowercased() == "jpg"
        panel.allowedContentTypes = [isJPEG ? .jpeg : .png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "横截 \(formatter.string(from: Date())).\(isJPEG ? "jpg" : "png")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: isJPEG ? .jpeg : .png, properties: isJPEG ? [.compressionFactor: 0.92] : [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }
}
