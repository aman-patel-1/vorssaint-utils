// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Based on Textream by Fatih Kadir Akın (MIT License)

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class TeleprompterService: ObservableObject {
    static let shared = TeleprompterService()

    @Published var isRunning: Bool = false
    @Published var isPaused: Bool = false
    @Published var text: String = "Welcome to Vorssaint Teleprompter.\n\nRead your script naturally while on camera. Words highlight in real time as you speak, powered by 100% on-device speech recognition."
    @Published var pages: [String] = []
    @Published var currentPageIndex: Int = 0
    @Published var readPages: Set<Int> = []

    @Published var guidanceMode: GuidanceMode = .wordTracking
    @Published var overlayMode: TeleprompterOverlayMode = .notch
    @Published var scrollSpeed: Double = 2.5
    @Published var fontSize: TeleprompterFontSizePreset = .sm
    @Published var fontFamily: TeleprompterFontFamilyPreset = .sans
    @Published var highlightColor: TeleprompterHighlightColorPreset = .yellow
    @Published var speechLocale: String = "en-US"
    @Published var selectedMicUID: String = ""
    @Published var remoteServerEnabled: Bool = false
    @Published var floatingWindowVisible: Bool = false

    // Director and External Display
    @Published var directorServerEnabled: Bool = false
    @Published var externalDisplayMode: ExternalDisplayMode = .off
    @Published var externalMirrorAxis: ExternalMirrorAxis = .horizontal
    @Published var externalScreenID: UInt32 = 0

    let speechRecognizer = SpeechRecognizer()
    let remoteServer = TeleprompterServer()
    let directorServer = DirectorServer()
    let dictationManager = DictationManager()
    let externalDisplayController = ExternalDisplayController()

    private var autoScrollTimer: Timer?
    private var words: [String] = []
    private var cancellables = Set<AnyCancellable>()

    var currentScript: String {
        get {
            if !pages.isEmpty && currentPageIndex < pages.count {
                return pages[currentPageIndex]
            }
            return text
        }
        set {
            if pages.isEmpty {
                text = newValue
            } else if currentPageIndex < pages.count {
                pages[currentPageIndex] = newValue
            }
            savePreferences()
        }
    }

    var currentWords: [String] {
        splitTextIntoWords(currentScript)
    }

    var totalWordCount: Int {
        currentWords.count
    }

    var activeWordIndex: Int {
        let charCount = speechRecognizer.recognizedCharCount
        var cumulative = 0
        for (index, word) in currentWords.enumerated() {
            cumulative += word.count + 1
            if cumulative > charCount {
                return index
            }
        }
        return max(0, currentWords.count - 1)
    }

    private init() {
        loadPreferences()
        setupObservers()
    }

    func syncWithPreferences() {
        loadPreferences()
        if remoteServerEnabled && !remoteServer.isRunning {
            remoteServer.start()
        } else if !remoteServerEnabled && remoteServer.isRunning {
            remoteServer.stop()
        }

        if directorServerEnabled && !directorServer.isRunning {
            directorServer.start()
        } else if !directorServerEnabled && directorServer.isRunning {
            directorServer.stop()
        }
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        if let savedText = defaults.string(forKey: DefaultsKey.teleprompterScriptText), !savedText.isEmpty {
            text = savedText
        }
        if let savedPages = defaults.stringArray(forKey: DefaultsKey.teleprompterPages), !savedPages.isEmpty {
            pages = savedPages
        }
        currentPageIndex = max(0, min(pages.isEmpty ? 0 : pages.count - 1, defaults.integer(forKey: DefaultsKey.teleprompterCurrentPageIndex)))

        if let modeStr = defaults.string(forKey: DefaultsKey.teleprompterGuidanceMode),
           let mode = GuidanceMode(rawValue: modeStr) {
            guidanceMode = mode
        }
        if let overlayStr = defaults.string(forKey: DefaultsKey.teleprompterOverlayMode),
           let ov = TeleprompterOverlayMode(rawValue: overlayStr) {
            overlayMode = ov
        }
        let speed = defaults.double(forKey: DefaultsKey.teleprompterScrollSpeed)
        if speed > 0 {
            scrollSpeed = speed
        }
        if let sizeStr = defaults.string(forKey: DefaultsKey.teleprompterFontSize),
           let size = TeleprompterFontSizePreset(rawValue: sizeStr) {
            fontSize = size
        }
        if let fontStr = defaults.string(forKey: DefaultsKey.teleprompterFontFamily),
           let family = TeleprompterFontFamilyPreset(rawValue: fontStr) {
            fontFamily = family
        }
        if let colorStr = defaults.string(forKey: DefaultsKey.teleprompterHighlightColor),
           let color = TeleprompterHighlightColorPreset(rawValue: colorStr) {
            highlightColor = color
        }
        if let locale = defaults.string(forKey: DefaultsKey.teleprompterSpeechLanguage), !locale.isEmpty {
            speechLocale = locale
        } else {
            speechLocale = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        }
        if let mic = defaults.string(forKey: DefaultsKey.teleprompterSelectedMicUID) {
            selectedMicUID = mic
        }
        remoteServerEnabled = defaults.bool(forKey: DefaultsKey.teleprompterRemoteServerEnabled)
        directorServerEnabled = defaults.bool(forKey: DefaultsKey.teleprompterDirectorServerEnabled)

        if let extModeStr = defaults.string(forKey: DefaultsKey.teleprompterExternalDisplayMode),
           let em = ExternalDisplayMode(rawValue: extModeStr) {
            externalDisplayMode = em
        }
        if let mirrorAxisStr = defaults.string(forKey: DefaultsKey.teleprompterExternalDisplayMirrorAxis),
           let ma = ExternalMirrorAxis(rawValue: mirrorAxisStr) {
            externalMirrorAxis = ma
        }
        externalScreenID = UInt32(defaults.integer(forKey: DefaultsKey.teleprompterExternalScreenID))
    }

    func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(text, forKey: DefaultsKey.teleprompterScriptText)
        if !pages.isEmpty {
            defaults.set(pages, forKey: DefaultsKey.teleprompterPages)
        }
        defaults.set(currentPageIndex, forKey: DefaultsKey.teleprompterCurrentPageIndex)
        defaults.set(guidanceMode.rawValue, forKey: DefaultsKey.teleprompterGuidanceMode)
        defaults.set(overlayMode.rawValue, forKey: DefaultsKey.teleprompterOverlayMode)
        defaults.set(scrollSpeed, forKey: DefaultsKey.teleprompterScrollSpeed)
        defaults.set(fontSize.rawValue, forKey: DefaultsKey.teleprompterFontSize)
        defaults.set(fontFamily.rawValue, forKey: DefaultsKey.teleprompterFontFamily)
        defaults.set(highlightColor.rawValue, forKey: DefaultsKey.teleprompterHighlightColor)
        defaults.set(speechLocale, forKey: DefaultsKey.teleprompterSpeechLanguage)
        defaults.set(selectedMicUID, forKey: DefaultsKey.teleprompterSelectedMicUID)
        defaults.set(remoteServerEnabled, forKey: DefaultsKey.teleprompterRemoteServerEnabled)
        defaults.set(directorServerEnabled, forKey: DefaultsKey.teleprompterDirectorServerEnabled)
        defaults.set(externalDisplayMode.rawValue, forKey: DefaultsKey.teleprompterExternalDisplayMode)
        defaults.set(externalMirrorAxis.rawValue, forKey: DefaultsKey.teleprompterExternalDisplayMirrorAxis)
        defaults.set(Int(externalScreenID), forKey: DefaultsKey.teleprompterExternalScreenID)
    }

    private func setupObservers() {
        speechRecognizer.$shouldAdvancePage
            .filter { $0 }
            .sink { [weak self] _ in
                self?.nextPage()
            }
            .store(in: &cancellables)

        speechRecognizer.$shouldDismiss
            .filter { $0 }
            .sink { [weak self] _ in
                self?.stop()
            }
            .store(in: &cancellables)

        // Director Server Callbacks
        directorServer.onSetText = { [weak self] newText in
            self?.handleDirectorSetText(newText)
        }

        directorServer.onUpdateText = { [weak self] newText, charCount in
            self?.handleDirectorUpdateText(newText, charCount: charCount)
        }

        directorServer.onStop = { [weak self] in
            self?.stop()
        }

        directorServer.onNextPage = { [weak self] in
            self?.nextPage()
        }

        directorServer.onPrevPage = { [weak self] in
            self?.previousPage()
        }
    }

    // MARK: - Director Server Command Handlers

    private func handleDirectorSetText(_ newText: String) {
        currentScript = newText
        words = splitTextIntoWords(newText)
        speechRecognizer.start(with: newText)
        updateBroadcasts()
    }

    private func handleDirectorUpdateText(_ newText: String, charCount: Int) {
        currentScript = newText
        words = splitTextIntoWords(newText)
        speechRecognizer.updateText(newText, preservingCharCount: charCount)
        updateBroadcasts()
    }

    private func updateBroadcasts() {
        let script = currentScript
        let hasNext = currentPageIndex < pages.count - 1
        if remoteServerEnabled {
            remoteServer.updateContent(words: words, totalCharCount: script.count, hasNextPage: hasNext)
        }
        if directorServerEnabled {
            directorServer.updateContent(words: words, totalCharCount: script.count)
        }
    }

    // MARK: - Multi-page Management

    func addPage() {
        if pages.isEmpty {
            pages = [text, ""]
            currentPageIndex = 1
        } else {
            pages.append("")
            currentPageIndex = pages.count - 1
        }
        savePreferences()
    }

    func removePage(at index: Int) {
        guard !pages.isEmpty, index >= 0, index < pages.count else { return }
        pages.remove(at: index)
        if pages.isEmpty {
            pages = [""]
            currentPageIndex = 0
        } else {
            currentPageIndex = min(currentPageIndex, pages.count - 1)
        }
        savePreferences()
    }

    func jumpToPage(index: Int) {
        guard !pages.isEmpty, index >= 0, index < pages.count else { return }
        currentPageIndex = index
        readPages.insert(index)
        savePreferences()
        if isRunning {
            restartCurrentPage()
        }
    }

    // MARK: - Playback Control

    func toggle() {
        if isRunning {
            if isPaused {
                resume()
            } else {
                pause()
            }
        } else {
            start()
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isPaused = false

        let script = currentScript
        words = splitTextIntoWords(script)

        if guidanceMode == .wordTracking {
            speechRecognizer.start(with: script)
        } else {
            speechRecognizer.start(with: script)
            startAutoScrollTimer()
        }

        let hasNext = currentPageIndex < pages.count - 1

        if remoteServerEnabled {
            if !remoteServer.isRunning {
                remoteServer.start()
            }
            remoteServer.showContent(
                speechRecognizer: speechRecognizer,
                words: words,
                totalCharCount: script.count,
                hasNextPage: hasNext
            )
        }

        if directorServerEnabled {
            if !directorServer.isRunning {
                directorServer.start()
            }
            directorServer.showContent(
                speechRecognizer: speechRecognizer,
                words: words,
                totalCharCount: script.count
            )
        }

        if externalDisplayMode != .off {
            externalDisplayController.show(
                speechRecognizer: speechRecognizer,
                words: words,
                script: script,
                font: fontFamily.nsFont(ofSize: fontSize.pointSize * 1.5),
                highlightColor: highlightColor.color,
                mode: externalDisplayMode,
                mirrorAxis: externalMirrorAxis
            )
        }

        if overlayMode == .notch {
            if NotchSupport.isEnabled() {
                NotchService.shared.open(.teleprompter, pinned: true)
            } else {
                TeleprompterFloatingWindowController.shared.showAtNotch()
            }
        } else if overlayMode == .floating {
            floatingWindowVisible = true
            TeleprompterFloatingWindowController.shared.show()
        }
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        speechRecognizer.stop()
    }

    func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        speechRecognizer.resume()
        if guidanceMode != .wordTracking {
            startAutoScrollTimer()
        }
    }

    func stop() {
        isRunning = false
        isPaused = false
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        speechRecognizer.stop()
        remoteServer.hideContent()
        directorServer.hideContent()
        externalDisplayController.dismiss()
        floatingWindowVisible = false
        TeleprompterFloatingWindowController.shared.hide()
        if NotchService.shared.expanded && NotchService.shared.selected == .teleprompter {
            NotchService.shared.collapse()
        }
        readPages.insert(currentPageIndex)
    }

    func jumpTo(charOffset: Int) {
        speechRecognizer.jumpTo(charOffset: charOffset)
    }

    func nextPage() {
        readPages.insert(currentPageIndex)
        guard !pages.isEmpty, currentPageIndex < pages.count - 1 else {
            stop()
            return
        }
        currentPageIndex += 1
        restartCurrentPage()
    }

    func previousPage() {
        guard !pages.isEmpty, currentPageIndex > 0 else { return }
        currentPageIndex -= 1
        restartCurrentPage()
    }

    private func restartCurrentPage() {
        let script = currentScript
        words = splitTextIntoWords(script)
        speechRecognizer.start(with: script)

        let hasNext = currentPageIndex < pages.count - 1
        if remoteServerEnabled {
            remoteServer.updateContent(
                words: words,
                totalCharCount: script.count,
                hasNextPage: hasNext
            )
        }
        if directorServerEnabled {
            directorServer.updateContent(
                words: words,
                totalCharCount: script.count
            )
        }
        if externalDisplayMode != .off {
            externalDisplayController.show(
                speechRecognizer: speechRecognizer,
                words: words,
                script: script,
                font: fontFamily.nsFont(ofSize: fontSize.pointSize * 1.5),
                highlightColor: highlightColor.color,
                mode: externalDisplayMode,
                mirrorAxis: externalMirrorAxis
            )
        }
    }

    // MARK: - Auto Scroll for Classic and Voice-Activated Modes

    private func startAutoScrollTimer() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, !self.isPaused else { return }
                self.tickAutoScroll()
            }
        }
    }

    private func tickAutoScroll() {
        let total = currentScript.count
        guard total > 0 else { return }

        if guidanceMode == .voiceActivated {
            guard speechRecognizer.isSpeaking else { return }
        }

        // scrollSpeed is in words/sec. In 0.1 sec, we advance (scrollSpeed * 0.1) words.
        let advanceCharRate = max(1.0, (Double(total) / Double(max(1, totalWordCount))) * (scrollSpeed * 0.1))
        let nextChar = min(total, speechRecognizer.recognizedCharCount + Int(advanceCharRate))
        speechRecognizer.recognizedCharCount = nextChar

        if nextChar >= total {
            if currentPageIndex < pages.count - 1 {
                nextPage()
            } else {
                stop()
            }
        }
    }

    // MARK: - Import Presentations

    func importPPTX(url: URL) throws {
        let extracted = try PresentationNotesExtractor.extractNotes(from: url)
        pages = extracted
        currentPageIndex = 0
        readPages.removeAll()
        if let first = extracted.first {
            text = first
        }
        savePreferences()
    }
}
