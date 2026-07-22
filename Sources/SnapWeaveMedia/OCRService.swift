import AppKit
import SnapWeaveCore
@preconcurrency import Vision

public struct OCRResult: Sendable {
    public let text: String
    public let detectedLanguage: TextLanguage?

    public init(text: String, detectedLanguage: TextLanguage?) {
        self.text = text
        self.detectedLanguage = detectedLanguage
    }
}

public enum OCRService {
    public static func recognize(_ image: CGImage, displaySize: CGSize? = nil) async throws -> OCRResult {
        try Task.checkCancellation()
        let preparedImage = downsampleIfNeeded(image, displaySize: displaySize)
        let text: String = try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let lines = (request.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "ja-JP", "en-US"]
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: preparedImage).perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return OCRResult(text: text, detectedLanguage: TextLanguage.detect(in: text))
    }

    public static func recognize(_ image: NSImage) async throws -> OCRResult {
        if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           let cgImage = bitmap.cgImage {
            return try await recognize(cgImage, displaySize: image.size)
        }
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return OCRResult(text: "", detectedLanguage: nil)
        }
        return try await recognize(cgImage, displaySize: image.size)
    }

    private static func downsampleIfNeeded(_ image: CGImage, displaySize: CGSize?) -> CGImage {
        guard let displaySize, displaySize.width > 0, displaySize.height > 0 else { return image }
        let scale = min(1, displaySize.width / CGFloat(image.width), displaySize.height / CGFloat(image.height))
        guard scale < 0.9 else { return image }
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
