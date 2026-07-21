import AppKit
import HengJieCore
import HengJieMedia
import SwiftUI

@MainActor
final class OCRResultWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private static var retained: [OCRResultWindowController] = []

    private let sourceTextView = NSTextView()
    private let translationTextView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "正在识别文字…")
    private let sourcePopup = NSPopUpButton()
    private let targetPopup = NSPopUpButton()
    private let translateButton = NSButton(title: "翻译", target: nil, action: nil)
    private let retryButton = NSButton(title: "重新框选", target: nil, action: nil)
    private let copySourceButton = NSButton(title: "复制原文", target: nil, action: nil)
    private let copyTranslationButton = NSButton(title: "复制译文", target: nil, action: nil)
    private let copyBilingualButton = NSButton(title: "复制双语", target: nil, action: nil)
    private var detectedLanguage: TextLanguage?
    private var isSourceLanguageManual = false
    private var recognitionTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var retryHandler: (() -> Void)?
    private var translationService: AnyObject?
    private var translationHost: NSView?
    private var isClosed = false

    static func presentRecognizing(retryHandler: (() -> Void)? = nil) -> OCRResultWindowController {
        let controller = OCRResultWindowController(retryHandler: retryHandler)
        retained.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    init(retryHandler: (() -> Void)?) {
        self.retryHandler = retryHandler
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 700, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = "横截 — 提取文字"
        window.contentMinSize = CGSize(width: 600, height: 540)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        installTranslationBridgeIfAvailable()
    }

    required init?(coder: NSCoder) { nil }

    func recognize(_ image: NSImage) {
        guard !isClosed else { return }
        recognitionTask?.cancel()
        recognitionTask = Task { [weak self] in
            do {
                let result = try await OCRService.recognize(image)
                guard !Task.isCancelled, let self, !self.isClosed else { return }
                self.finish(with: result)
            } catch is CancellationError {
            } catch {
                guard let self, !self.isClosed else { return }
                self.fail(with: error)
            }
        }
    }

    func recognize(_ image: CGImage, displaySize: CGSize? = nil) {
        guard !isClosed else { return }
        recognitionTask?.cancel()
        recognitionTask = Task { [weak self] in
            do {
                let result = try await OCRService.recognize(image, displaySize: displaySize)
                guard !Task.isCancelled, let self, !self.isClosed else { return }
                self.finish(with: result)
            } catch is CancellationError {
            } catch {
                guard let self, !self.isClosed else { return }
                self.fail(with: error)
            }
        }
    }

    func finish(with result: OCRResult) {
        guard !isClosed else { return }
        isSourceLanguageManual = false
        sourcePopup.selectItem(at: 0)
        sourceTextView.string = result.text
        detectedLanguage = result.detectedLanguage
        updateAutomaticSourceTitle(result.detectedLanguage)
        sourceTextView.isEditable = true
        copySourceButton.isEnabled = !result.text.isEmpty
        if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusLabel.stringValue = "未识别到文字，请重新框选文字更清晰的区域。"
            retryButton.isHidden = retryHandler == nil
        } else {
            statusLabel.stringValue = "文字已提取，可直接编辑或复制。"
            if let language = result.detectedLanguage {
                targetPopup.selectItem(withTitle: language.defaultTarget.title)
            }
            updateTranslationAvailability()
        }
    }

    func fail(with error: Error) {
        guard !isClosed else { return }
        statusLabel.stringValue = "文字识别失败：\(error.localizedDescription)"
        updateAutomaticSourceTitle(nil)
        sourceTextView.isEditable = true
        retryButton.isHidden = retryHandler == nil
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        root.addArrangedSubview(statusLabel)

        root.addArrangedSubview(sectionLabel("提取的原文"))
        let sourceScroll = textScrollView(sourceTextView, editable: false)
        sourceScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        root.addArrangedSubview(sourceScroll)
        sourceScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        copySourceButton.target = self
        copySourceButton.action = #selector(copySource)
        retryButton.target = self
        retryButton.action = #selector(retrySelection)
        retryButton.isHidden = true
        let sourceActions = NSStackView(views: [copySourceButton, retryButton])
        sourceActions.spacing = 8
        root.addArrangedSubview(sourceActions)

        sourcePopup.addItems(withTitles: ["自动识别"] + TextLanguage.allCases.map(\.title))
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        targetPopup.addItems(withTitles: TextLanguage.allCases.map(\.title))
        targetPopup.selectItem(withTitle: TextLanguage.chinese.title)
        targetPopup.target = self
        targetPopup.action = #selector(targetChanged)
        translateButton.target = self
        translateButton.action = #selector(translate)
        let translationControls = NSStackView(views: [NSTextField(labelWithString: "原文语言"), sourcePopup, NSTextField(labelWithString: "翻译为"), targetPopup, translateButton])
        translationControls.alignment = .centerY
        translationControls.spacing = 8
        root.addArrangedSubview(translationControls)

        root.addArrangedSubview(sectionLabel("翻译结果"))
        let translationScroll = textScrollView(translationTextView, editable: false)
        translationScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        root.addArrangedSubview(translationScroll)
        translationScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        copyTranslationButton.target = self
        copyTranslationButton.action = #selector(copyTranslation)
        copyBilingualButton.target = self
        copyBilingualButton.action = #selector(copyBilingual)
        let translationActions = NSStackView(views: [copyTranslationButton, copyBilingualButton])
        translationActions.spacing = 8
        root.addArrangedSubview(translationActions)

        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        copySourceButton.isEnabled = false
        copyTranslationButton.isEnabled = false
        copyBilingualButton.isEnabled = false
        updateTranslationAvailability()
    }

    private func textScrollView(_ textView: NSTextView, editable: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isEditable = editable
        textView.isSelectable = true
        if textView === sourceTextView { textView.delegate = self }
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = CGSize(width: 8, height: 8)
        textView.frame = CGRect(x: 0, y: 0, width: 640, height: 180)
        textView.minSize = .zero
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = CGSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        return scroll
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        return label
    }

    private func installTranslationBridgeIfAvailable() {
        guard #available(macOS 15.0, *), let content = window?.contentView else { return }
        let service = TranslationService()
        let host = NSHostingView(rootView: TranslationSessionHost(service: service))
        host.frame = CGRect(x: -2, y: -2, width: 1, height: 1)
        host.isHidden = false
        content.addSubview(host)
        translationService = service
        translationHost = host
    }

    private func updateTranslationAvailability() {
        let source = currentSourceLanguage
        detectedLanguage = source
        if !isSourceLanguageManual { updateAutomaticSourceTitle(source) }
        let target = selectedTarget
        copyTranslationButton.isEnabled = !translationTextView.string.isEmpty
        copyBilingualButton.isEnabled = !sourceTextView.string.isEmpty && !translationTextView.string.isEmpty
        if #available(macOS 15.0, *) {
            translateButton.isEnabled = source != nil && source != target && !sourceTextView.string.isEmpty
            if source == target { statusLabel.stringValue = "目标语言与原文语言相同，请选择其他语言。" }
        } else {
            translateButton.title = "翻译需要 macOS 15+"
            translateButton.isEnabled = false
        }
    }

    private var selectedTarget: TextLanguage {
        TextLanguage.allCases.first { $0.title == targetPopup.titleOfSelectedItem } ?? .chinese
    }

    private var currentSourceLanguage: TextLanguage? {
        if isSourceLanguageManual, sourcePopup.indexOfSelectedItem > 0 {
            return TextLanguage.allCases[sourcePopup.indexOfSelectedItem - 1]
        }
        return TextLanguage.detect(in: sourceTextView.string)
    }

    private func updateAutomaticSourceTitle(_ language: TextLanguage?) {
        sourcePopup.item(at: 0)?.title = "自动（\(language?.title ?? "未识别")）"
    }

    @objc private func sourceChanged() {
        isSourceLanguageManual = sourcePopup.indexOfSelectedItem > 0
        if let source = currentSourceLanguage, source == selectedTarget {
            targetPopup.selectItem(withTitle: source.defaultTarget.title)
        }
        cancelTranslation(clearResult: true)
        statusLabel.stringValue = isSourceLanguageManual ? "已手动选择原文语言。" : "已恢复自动识别原文语言。"
        updateTranslationAvailability()
    }

    @objc private func targetChanged() {
        cancelTranslation(clearResult: true)
        statusLabel.stringValue = "目标语言已更改，可开始翻译。"
        updateTranslationAvailability()
    }

    func textDidChange(_ notification: Notification) {
        cancelTranslation(clearResult: true)
        if !isSourceLanguageManual { updateAutomaticSourceTitle(TextLanguage.detect(in: sourceTextView.string)) }
        statusLabel.stringValue = sourceTextView.string.isEmpty ? "请输入或重新提取文字。" : "原文已修改，可重新翻译。"
        updateTranslationAvailability()
    }

    private func cancelTranslation(clearResult: Bool) {
        translationTask?.cancel()
        if #available(macOS 15.0, *), let service = translationService as? TranslationService { service.cancel() }
        if clearResult { translationTextView.string = "" }
        translateButton.title = "翻译"
    }

    @objc private func translate() {
        let sourceText = sourceTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source = currentSourceLanguage else {
            statusLabel.stringValue = "无法识别原文语言，请手动选择中文、日语或英语。"
            return
        }
        let target = selectedTarget
        guard #available(macOS 15.0, *), let service = translationService as? TranslationService else { return }
        translationTask?.cancel()
        service.cancel()
        statusLabel.stringValue = "正在翻译为\(target.title)…"
        translateButton.title = "翻译"
        translateButton.isEnabled = false
        translationTask = Task { [weak self] in
            do {
                let output = try await service.translate(sourceText, from: source, to: target) { [weak self] progress in
                    guard let self else { return }
                    let direction = "\(source.title) → \(target.title)"
                    switch progress {
                    case .checkingAvailability: self.statusLabel.stringValue = "正在检查 \(direction) 语言包…"
                    case .preparingLanguages: self.statusLabel.stringValue = "正在准备 \(direction) 语言包，首次使用可能需要下载…"
                    case .translating: self.statusLabel.stringValue = "正在翻译 \(direction)…"
                    }
                }
                guard !Task.isCancelled, let self else { return }
                self.detectedLanguage = output.sourceLanguage
                self.translationTextView.string = output.translatedText
                self.statusLabel.stringValue = "翻译完成：\(output.sourceLanguage.title) → \(output.targetLanguage.title)。"
                self.updateTranslationAvailability()
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                self.statusLabel.stringValue = "翻译失败（\(source.title) → \(target.title)）：\(error.localizedDescription)"
                self.translateButton.title = "重试翻译"
                self.updateTranslationAvailability()
            }
        }
    }

    @objc private func retrySelection() {
        let handler = retryHandler
        close()
        handler?()
    }

    @objc private func copySource() { copy(sourceTextView.string) }
    @objc private func copyTranslation() { copy(translationTextView.string) }
    @objc private func copyBilingual() {
        copy("原文：\n\(sourceTextView.string)\n\n译文（\(selectedTarget.title)）：\n\(translationTextView.string)")
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusLabel.stringValue = "已复制到剪贴板。"
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        recognitionTask?.cancel()
        translationTask?.cancel()
        if #available(macOS 15.0, *), let service = translationService as? TranslationService { service.cancel() }
        Self.retained.removeAll { $0 === self }
    }
}
