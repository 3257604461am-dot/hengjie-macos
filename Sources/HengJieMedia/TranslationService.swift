import Combine
import Foundation
import HengJieCore
import SwiftUI
import Translation

public struct TranslationOutput: Sendable {
    public let sourceLanguage: TextLanguage
    public let targetLanguage: TextLanguage
    public let translatedText: String

    public init(sourceLanguage: TextLanguage, targetLanguage: TextLanguage, translatedText: String) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.translatedText = translatedText
    }
}

public enum TranslationProgress: Sendable {
    case checkingAvailability
    case preparingLanguages
    case translating
}

@available(macOS 15.0, *)
@MainActor
public final class TranslationService: ObservableObject {
    @Published fileprivate var configuration: TranslationSession.Configuration?
    fileprivate var pendingText = ""
    private var pendingSource: TextLanguage?
    private var pendingTarget: TextLanguage?
    private var pendingNeedsPreparation = false
    private var pendingProgress: ((TranslationProgress) -> Void)?
    private var configuredSource: TextLanguage?
    private var configuredTarget: TextLanguage?
    private var continuation: CheckedContinuation<TranslationOutput, Error>?
    private var generation = 0

    public init() {}

    public func translate(
        _ text: String,
        from source: TextLanguage,
        to target: TextLanguage,
        progress: @escaping (TranslationProgress) -> Void
    ) async throws -> TranslationOutput {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TranslationServiceError.nothingToTranslate }
        guard source != target else { throw TranslationServiceError.sameLanguage }

        progress(.checkingAvailability)
        let status = await LanguageAvailability().status(from: source.localeLanguage, to: target.localeLanguage)
        try Task.checkCancellation()
        guard status != .unsupported else { throw TranslationServiceError.unsupportedPair }

        cancel()
        generation += 1
        pendingText = value
        pendingSource = source
        pendingTarget = target
        pendingNeedsPreparation = status == .supported
        pendingProgress = progress

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            if configuredSource == source, configuredTarget == target, configuration != nil {
                configuration?.invalidate()
            } else {
                configuredSource = source
                configuredTarget = target
                configuration = TranslationSession.Configuration(source: source.localeLanguage, target: target.localeLanguage)
            }
        }
    }

    public func cancel() {
        generation += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    fileprivate func perform(using session: TranslationSession) async {
        guard continuation != nil,
              let source = pendingSource,
              let target = pendingTarget else { return }
        let requestGeneration = generation
        let text = pendingText
        let needsPreparation = pendingNeedsPreparation
        let progress = pendingProgress
        do {
            if needsPreparation {
                progress?(.preparingLanguages)
                do { try await session.prepareTranslation() }
                catch { throw TranslationServiceError.languagePreparationFailed(error.localizedDescription) }
            }
            progress?(.translating)
            let response = try await session.translate(text)
            complete(
                .success(TranslationOutput(sourceLanguage: source, targetLanguage: target, translatedText: response.targetText)),
                generation: requestGeneration
            )
        } catch {
            complete(.failure(TranslationServiceError.map(error)), generation: requestGeneration)
        }
    }

    private func complete(_ result: Result<TranslationOutput, Error>, generation requestGeneration: Int) {
        guard requestGeneration == generation, let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

@available(macOS 15.0, *)
public struct TranslationSessionHost: View {
    @ObservedObject var service: TranslationService

    public init(service: TranslationService) {
        self.service = service
    }

    public var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(service.configuration) { session in
                await service.perform(using: session)
            }
    }
}

public enum TranslationServiceError: LocalizedError {
    case nothingToTranslate
    case sameLanguage
    case unsupportedSource
    case unsupportedTarget
    case unsupportedPair
    case unableToIdentifyLanguage
    case languagePreparationFailed(String)
    case languagePackNotInstalled
    case systemFailure(String)

    @available(macOS 15.0, *)
    static func map(_ error: Error) -> TranslationServiceError {
        if let known = error as? TranslationServiceError { return known }
        if TranslationError.unsupportedSourceLanguage ~= error { return .unsupportedSource }
        if TranslationError.unsupportedTargetLanguage ~= error { return .unsupportedTarget }
        if TranslationError.unsupportedLanguagePairing ~= error { return .unsupportedPair }
        if TranslationError.unableToIdentifyLanguage ~= error { return .unableToIdentifyLanguage }
        if TranslationError.nothingToTranslate ~= error { return .nothingToTranslate }
        if #available(macOS 26.0, *), TranslationError.notInstalled ~= error { return .languagePackNotInstalled }
        return .systemFailure(error.localizedDescription)
    }

    public var errorDescription: String? {
        switch self {
        case .nothingToTranslate: "没有可翻译的文字。"
        case .sameLanguage: "原文语言和目标语言相同，请选择其他语言。"
        case .unsupportedSource: "系统不支持当前原文语言。"
        case .unsupportedTarget: "系统不支持当前目标语言。"
        case .unsupportedPair: "系统不支持当前语言组合。"
        case .unableToIdentifyLanguage: "系统无法确定原文语言，请手动选择后重试。"
        case let .languagePreparationFailed(reason): "语言包未下载、下载被取消或准备失败：\(reason)"
        case .languagePackNotInstalled: "所需语言包尚未安装，请允许系统下载后重试。"
        case let .systemFailure(reason): "系统翻译服务失败：\(reason)"
        }
    }
}
