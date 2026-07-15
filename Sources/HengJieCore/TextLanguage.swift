import Foundation
import NaturalLanguage

public enum TextLanguage: String, CaseIterable, Sendable {
    case chinese = "zh-Hans"
    case japanese = "ja"
    case english = "en"

    public var title: String {
        switch self {
        case .chinese: "简体中文"
        case .japanese: "日语"
        case .english: "英语"
        }
    }

    public var localeLanguage: Locale.Language { Locale.Language(identifier: rawValue) }

    public var defaultTarget: TextLanguage {
        switch self {
        case .chinese: .english
        case .japanese, .english: .chinese
        }
    }

    public static func detect(in text: String) -> TextLanguage? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageHints = [.simplifiedChinese: 0.34, .japanese: 0.33, .english: 0.33]
        recognizer.processString(value)
        switch recognizer.dominantLanguage {
        case .simplifiedChinese, .traditionalChinese: return .chinese
        case .japanese: return .japanese
        case .english: return .english
        default: return nil
        }
    }
}

