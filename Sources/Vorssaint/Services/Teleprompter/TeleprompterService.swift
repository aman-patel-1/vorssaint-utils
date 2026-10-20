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

    let speechRecognizer = SpeechRecognizer()
    let remoteServer = TeleprompterServer()

    private var autoScrollTimer: Timer?
    private var words: [String] = []
    private var cancellables = Set<AnyCancellable>()

    var currentScript: String {
        if !pages.isEmpty && currentPageIndex < pages.count {
            return pages[currentPageIndex]
        }
        return text
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
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        if let savedText = defaults.string(forKey: DefaultsKey.teleprompterScriptText), !savedText.isEmpty {
            text = savedText
        }
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
    }

    func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(text, forKey: DefaultsKey.teleprompterScriptText)
        defaults.set(guidanceMode.rawValue, forKey: DefaultsKey.teleprompterGuidanceMode)
        defaults.set(overlayMode.rawValue, forKey: DefaultsKey.teleprompterOverlayMode)
        defaults.set(scrollSpeed, forKey: DefaultsKey.teleprompterScrollSpeed)
        defaults.set(fontSize.rawValue, forKey: DefaultsKey.teleprompterFontSize)
        defaults.set(fontFamily.rawValue, forKey: DefaultsKey.teleprompterFontFamily)
        defaults.set(highlightColor.rawValue, forKey: DefaultsKey.teleprompterHighlightColor)
        defaults.set(speechLocale, forKey: DefaultsKey.teleprompterSpeechLanguage)
        defaults.set(selectedMicUID, forKey: DefaultsKey.teleprompterSelectedMicUID)
        defaults.set(remoteServerEnabled, forKey: DefaultsKey.teleprompterRemoteServerEnabled)
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

        if remoteServerEnabled {
            if !remoteServer.isRunning {
                remoteServer.start()
            }
            remoteServer.showContent(
                speechRecognizer: speechRecognizer,
                words: words,
                totalCharCount: script.count,
                hasNextPage: currentPageIndex < pages.count - 1
            )
        }

        if overlayMode == .floating {
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
        floatingWindowVisible = false
        TeleprompterFloatingWindowController.shared.hide()
    }

    func jumpTo(charOffset: Int) {
        speechRecognizer.jumpTo(charOffset: charOffset)
    }

    func nextPage() {
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
        if remoteServerEnabled {
            remoteServer.updateContent(
                words: words,
                totalCharCount: script.count,
                hasNextPage: currentPageIndex < pages.count - 1
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
        if let first = extracted.first {
            text = first
        }
    }
}
