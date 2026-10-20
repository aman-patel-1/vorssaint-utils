// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Based on Textream by Fatih Kadir Akın (MIT License)

import AppKit
import Combine
import Foundation
import IOKit.pwr_mgt
import SwiftUI

@MainActor
final class TeleprompterService: ObservableObject {
    static let shared = TeleprompterService()
    static let scrollSpeedRange = 0.25...3.0
    static let notchWindowWidthRange = 420.0...1000.0
    static let floatingWindowWidthRange = 320.0...1000.0
    static let notchWindowHeightRange = 220.0...640.0
    static let floatingWindowHeightRange = 180.0...800.0

    static func windowWidthRange(for mode: TeleprompterOverlayMode) -> ClosedRange<Double> {
        mode == .notch ? notchWindowWidthRange : floatingWindowWidthRange
    }

    static func windowHeightRange(for mode: TeleprompterOverlayMode) -> ClosedRange<Double> {
        mode == .notch ? notchWindowHeightRange : floatingWindowHeightRange
    }

    @Published var isRunning: Bool = false {
        didSet { UserDefaults.standard.set(isRunning, forKey: DefaultsKey.teleprompterIsRunning) }
    }
    /// Shows a sample through the real notch prompter UI without starting a session.
    @Published private(set) var isPreviewingInNotch = false
    @Published private(set) var isPreviewingFloating = false
    @Published private(set) var previewWordProgress: Double = 0
    @Published private(set) var previewPageIndex = 0
    @Published var isPaused: Bool = false
    @Published var text: String = "Welcome to Vorssaint Teleprompter.\n\nRead your script naturally while on camera. Words highlight in real time as you speak, powered by 100% on-device speech recognition."
    @Published var pages: [String] = []
    @Published var currentPageIndex: Int = 0
    @Published var readPages: Set<Int> = []
    @Published var pendingAddPageInSettings = false
    @Published var pendingEditPageIndexInSettings: Int?

    @Published var guidanceMode: GuidanceMode = .wordTracking {
        didSet {
            guard oldValue != guidanceMode, isRunning else { return }
            autoScrollTimer?.invalidate()
            autoScrollTimer = nil
            speechRecognizer.stop()
            if isPaused {
                restartSpeechOnResume = guidanceMode != .classic
                return
            }
            if guidanceMode == .classic {
                startAutoScrollTimer()
            } else {
                speechRecognizer.start(with: currentScript)
                startAutoScrollTimerIfNeeded()
            }
        }
    }
    @Published var overlayMode: TeleprompterOverlayMode = .notch
    @Published var scrollSpeed: Double = 2.5 {
        didSet {
            let bounded = Self.clampedScrollSpeed(scrollSpeed)
            if bounded != scrollSpeed { scrollSpeed = bounded }
        }
    }
    @Published var fontSize: TeleprompterFontSizePreset = .sm
    @Published var fontFamily: TeleprompterFontFamilyPreset = .sans
    @Published var highlightColor: TeleprompterHighlightColorPreset = .yellow
    @Published var cueColor: TeleprompterCueColorPreset = .yellow
    @Published var cueBrightness: TeleprompterCueBrightness = .medium
    @Published var windowWidth: Double = 560.0 {
        didSet {
            let range = Self.windowWidthRange(for: overlayMode)
            let bounded = min(range.upperBound, max(range.lowerBound, windowWidth))
            if bounded != windowWidth { windowWidth = bounded }
            if bounded != oldValue { updateNotchSurfaceSize() }
        }
    }
    @Published var windowHeight: Double = 280.0 {
        didSet {
            let range = Self.windowHeightRange(for: overlayMode)
            let bounded = min(range.upperBound, max(range.lowerBound, windowHeight))
            if bounded != windowHeight { windowHeight = bounded }
            if bounded != oldValue { updateNotchSurfaceSize() }
        }
    }
    @Published var readingPosition: TeleprompterReadingPosition = .centered
    @Published var displayTargetMode: TeleprompterDisplayTargetMode = .followMouse
    @Published var showParagraphDividers: Bool = false
    @Published var showLastSpokenWords: Bool = true
    @Published var keepScreenAwake: Bool = true
    @Published var showElapsedTime: Bool = true
    @Published var hideFromScreenShare: Bool = true
    @Published var autoNextPage: Bool = false
    @Published var overlayTransparency: Double = 0.15
    @Published var speechLocale: String = "en-US"
    @Published var selectedMicUID: String = ""
    @Published var remoteServerEnabled: Bool = false
    @Published var floatingWindowVisible: Bool = false
    @Published var timerWordProgress: Double = 0

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
    private let hotkey = QuickToolHotkey(id: 90)
    private var sleepAssertionID: IOPMAssertionID = 0
    private var elapsedTimer: Timer?
    private var notchPreviewIdleTask: Task<Void, Never>?
    private var previewProgressTimer: Timer?
    private var restoreFloatingAfterNotchPreview = false
    private var restartSpeechOnResume = false

    static let previewPages = [
        "A quick brown fox jumps over the quiet fence, then follows the winding path toward the river. [PAUSE] The morning light catches every leaf as the breeze moves softly through the trees.",
        "Take a slow breath, look toward the camera, and let the next idea arrive naturally. [LOOK AT CAMERA] Speak clearly, keep a comfortable pace, and leave a little space between each thought.",
        "When the story reaches its final point, pause for a moment before continuing. A steady rhythm makes every sentence easier to follow. [SMILE]"
    ]
    static let previewScript = previewPages.joined(separator: "\n\n")
    var previewCurrentScript: String { Self.previewPages[previewPageIndex] }

    @Published var sessionStartTime: Date? = nil
    @Published var elapsedSeconds: Int = 0

    var formattedElapsedTime: String {
        let mins = elapsedSeconds / 60
        let secs = elapsedSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    static func clampedScrollSpeed(_ speed: Double) -> Double {
        speed.isFinite ? min(scrollSpeedRange.upperBound, max(scrollSpeedRange.lowerBound, speed)) : 2.5
    }

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
        UserDefaults.standard.set(false, forKey: DefaultsKey.teleprompterIsRunning)
        loadPreferences()
        setupObservers()
        syncWithPreferences()
    }

    func syncWithPreferences() {
        loadPreferences()

        let shortcut = GlobalShortcut.saved(for: DefaultsKey.teleprompterShortcut, fallback: .teleprompterDefault)
        let isEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.teleprompterEnabled)
        let shortcutEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.teleprompterShortcutEnabled)
        hotkey.onPress = { [weak self] in
            self?.toggle()
        }
        hotkey.sync(enabled: isEnabled && shortcutEnabled, shortcut: shortcut, storageKey: DefaultsKey.teleprompterShortcut)

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
        if let cueStr = defaults.string(forKey: DefaultsKey.teleprompterCueColor),
           let cc = TeleprompterCueColorPreset(rawValue: cueStr) {
            cueColor = cc
        }
        if let brightStr = defaults.string(forKey: DefaultsKey.teleprompterCueBrightness),
           let cb = TeleprompterCueBrightness(rawValue: brightStr) {
            cueBrightness = cb
        }
        let w = defaults.double(forKey: DefaultsKey.teleprompterWidth)
        if w > 0 {
            let range = Self.windowWidthRange(for: overlayMode)
            windowWidth = min(range.upperBound, max(range.lowerBound, w))
        }
        let h = defaults.double(forKey: DefaultsKey.teleprompterHeight)
        if h > 0 {
            let range = Self.windowHeightRange(for: overlayMode)
            windowHeight = min(range.upperBound, max(range.lowerBound, h))
        }
        if let posStr = defaults.string(forKey: DefaultsKey.teleprompterReadingPosition),
           let rp = TeleprompterReadingPosition(rawValue: posStr) {
            readingPosition = rp
        }
        if let targetStr = defaults.string(forKey: DefaultsKey.teleprompterDisplayTargetMode),
           let tm = TeleprompterDisplayTargetMode(rawValue: targetStr) {
            displayTargetMode = tm
        }
        showParagraphDividers = defaults.bool(forKey: DefaultsKey.teleprompterShowParagraphDividers)
        if defaults.object(forKey: DefaultsKey.teleprompterShowLastSpokenWords) != nil {
            showLastSpokenWords = defaults.bool(forKey: DefaultsKey.teleprompterShowLastSpokenWords)
        }
        if defaults.object(forKey: DefaultsKey.teleprompterKeepScreenAwake) != nil {
            keepScreenAwake = defaults.bool(forKey: DefaultsKey.teleprompterKeepScreenAwake)
        }
        if defaults.object(forKey: DefaultsKey.teleprompterShowElapsedTime) != nil {
            showElapsedTime = defaults.bool(forKey: DefaultsKey.teleprompterShowElapsedTime)
        }
        if defaults.object(forKey: DefaultsKey.teleprompterHideFromScreenShare) != nil {
            hideFromScreenShare = defaults.bool(forKey: DefaultsKey.teleprompterHideFromScreenShare)
        }
        autoNextPage = defaults.bool(forKey: DefaultsKey.teleprompterAutoNextPage)
        if defaults.object(forKey: DefaultsKey.teleprompterOverlayTransparency) != nil {
            overlayTransparency = defaults.double(forKey: DefaultsKey.teleprompterOverlayTransparency)
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
        loadPlacementProfile(for: overlayMode)
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
        defaults.set(cueColor.rawValue, forKey: DefaultsKey.teleprompterCueColor)
        defaults.set(cueBrightness.rawValue, forKey: DefaultsKey.teleprompterCueBrightness)
        defaults.set(windowWidth, forKey: DefaultsKey.teleprompterWidth)
        defaults.set(windowHeight, forKey: DefaultsKey.teleprompterHeight)
        defaults.set(readingPosition.rawValue, forKey: DefaultsKey.teleprompterReadingPosition)
        defaults.set(displayTargetMode.rawValue, forKey: DefaultsKey.teleprompterDisplayTargetMode)
        defaults.set(showParagraphDividers, forKey: DefaultsKey.teleprompterShowParagraphDividers)
        defaults.set(showLastSpokenWords, forKey: DefaultsKey.teleprompterShowLastSpokenWords)
        defaults.set(keepScreenAwake, forKey: DefaultsKey.teleprompterKeepScreenAwake)
        defaults.set(showElapsedTime, forKey: DefaultsKey.teleprompterShowElapsedTime)
        defaults.set(hideFromScreenShare, forKey: DefaultsKey.teleprompterHideFromScreenShare)
        defaults.set(autoNextPage, forKey: DefaultsKey.teleprompterAutoNextPage)
        defaults.set(overlayTransparency, forKey: DefaultsKey.teleprompterOverlayTransparency)
        defaults.set(speechLocale, forKey: DefaultsKey.teleprompterSpeechLanguage)
        defaults.set(selectedMicUID, forKey: DefaultsKey.teleprompterSelectedMicUID)
        defaults.set(remoteServerEnabled, forKey: DefaultsKey.teleprompterRemoteServerEnabled)
        defaults.set(directorServerEnabled, forKey: DefaultsKey.teleprompterDirectorServerEnabled)
        defaults.set(externalDisplayMode.rawValue, forKey: DefaultsKey.teleprompterExternalDisplayMode)
        defaults.set(externalMirrorAxis.rawValue, forKey: DefaultsKey.teleprompterExternalDisplayMirrorAxis)
        defaults.set(Int(externalScreenID), forKey: DefaultsKey.teleprompterExternalScreenID)
        savePlacementProfile(for: overlayMode)
    }

    private func placementProfileKey(_ key: String, mode: TeleprompterOverlayMode) -> String {
        "\(key).surface.\(mode.rawValue)"
    }

    private func savePlacementProfile(for mode: TeleprompterOverlayMode) {
        let defaults = UserDefaults.standard
        func set(_ value: Any, _ key: String) {
            defaults.set(value, forKey: placementProfileKey(key, mode: mode))
        }
        set(fontFamily.rawValue, DefaultsKey.teleprompterFontFamily)
        set(fontSize.rawValue, DefaultsKey.teleprompterFontSize)
        set(highlightColor.rawValue, DefaultsKey.teleprompterHighlightColor)
        set(cueColor.rawValue, DefaultsKey.teleprompterCueColor)
        set(cueBrightness.rawValue, DefaultsKey.teleprompterCueBrightness)
        set(guidanceMode.rawValue, DefaultsKey.teleprompterGuidanceMode)
        set(scrollSpeed, DefaultsKey.teleprompterScrollSpeed)
        set(readingPosition.rawValue, DefaultsKey.teleprompterReadingPosition)
        set(windowWidth, DefaultsKey.teleprompterWidth)
        set(windowHeight, DefaultsKey.teleprompterHeight)
        set(overlayTransparency, DefaultsKey.teleprompterOverlayTransparency)
        set(hideFromScreenShare, DefaultsKey.teleprompterHideFromScreenShare)
        set(speechLocale, DefaultsKey.teleprompterSpeechLanguage)
        set(selectedMicUID, DefaultsKey.teleprompterSelectedMicUID)
    }

    private func loadPlacementProfile(for mode: TeleprompterOverlayMode) {
        let defaults = UserDefaults.standard
        let guidanceKey = placementProfileKey(DefaultsKey.teleprompterGuidanceMode, mode: mode)
        guard defaults.object(forKey: guidanceKey) != nil else { return }
        func string(_ key: String) -> String? {
            defaults.string(forKey: placementProfileKey(key, mode: mode))
        }
        func number(_ key: String) -> Double? {
            let storedKey = placementProfileKey(key, mode: mode)
            return defaults.object(forKey: storedKey) == nil ? nil : defaults.double(forKey: storedKey)
        }
        func bool(_ key: String, fallback: Bool) -> Bool {
            let storedKey = placementProfileKey(key, mode: mode)
            return defaults.object(forKey: storedKey) == nil ? fallback : defaults.bool(forKey: storedKey)
        }
        if let raw = string(DefaultsKey.teleprompterFontFamily), let value = TeleprompterFontFamilyPreset(rawValue: raw) { fontFamily = value }
        if let raw = string(DefaultsKey.teleprompterFontSize), let value = TeleprompterFontSizePreset(rawValue: raw) { fontSize = value }
        if let raw = string(DefaultsKey.teleprompterHighlightColor), let value = TeleprompterHighlightColorPreset(rawValue: raw) { highlightColor = value }
        if let raw = string(DefaultsKey.teleprompterCueColor), let value = TeleprompterCueColorPreset(rawValue: raw) { cueColor = value }
        if let raw = string(DefaultsKey.teleprompterCueBrightness), let value = TeleprompterCueBrightness(rawValue: raw) { cueBrightness = value }
        if let raw = string(DefaultsKey.teleprompterGuidanceMode), let value = GuidanceMode(rawValue: raw) { guidanceMode = value }
        if let value = number(DefaultsKey.teleprompterScrollSpeed) { scrollSpeed = Self.clampedScrollSpeed(value) }
        if let raw = string(DefaultsKey.teleprompterReadingPosition), let value = TeleprompterReadingPosition(rawValue: raw) { readingPosition = value }
        if let value = number(DefaultsKey.teleprompterWidth) { windowWidth = value }
        if let value = number(DefaultsKey.teleprompterHeight) { windowHeight = value }
        if let value = number(DefaultsKey.teleprompterOverlayTransparency) { overlayTransparency = value }
        hideFromScreenShare = bool(DefaultsKey.teleprompterHideFromScreenShare, fallback: hideFromScreenShare)
        if let locale = string(DefaultsKey.teleprompterSpeechLanguage) { speechLocale = locale }
        if let mic = string(DefaultsKey.teleprompterSelectedMicUID) { selectedMicUID = mic }
    }

    /// Resets all teleprompter options to defaults, preserving user scripts and pages.
    func resetSettings() {
        guidanceMode = .wordTracking
        overlayMode = .notch
        scrollSpeed = 2.5
        fontSize = .sm
        fontFamily = .sans
        highlightColor = .yellow
        cueColor = .yellow
        cueBrightness = .medium
        windowWidth = 560.0
        windowHeight = 280.0
        readingPosition = .centered
        displayTargetMode = .followMouse
        showParagraphDividers = false
        showLastSpokenWords = true
        keepScreenAwake = true
        showElapsedTime = true
        hideFromScreenShare = true
        autoNextPage = false
        overlayTransparency = 0.15
        externalDisplayMode = .off
        externalMirrorAxis = .horizontal
        remoteServerEnabled = false
        directorServerEnabled = false
        savePreferences()
        savePlacementProfile(for: .floating)
    }

    private func setupObservers() {
        speechRecognizer.$shouldAdvancePage
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.speechRecognizer.shouldAdvancePage = false
                if self.autoNextPage {
                    self.nextPage()
                }
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
        guard isRunning else { return }
        currentScript = newText
        words = splitTextIntoWords(newText)
        if isRunning && guidanceMode != .classic && !isPaused {
            speechRecognizer.start(with: newText)
        } else if isRunning && guidanceMode != .classic {
            restartSpeechOnResume = true
        }
        updateBroadcasts()
    }

    private func handleDirectorUpdateText(_ newText: String, charCount: Int) {
        guard isRunning else { return }
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

    /// Open the notch's ready state without starting a reading session.
    /// Starting playback then uses the selected appearance.
    func openPrompter() {
        endNotchPreview()
        presentNotchSurface()
    }

    /// Save the current surface's options, then restore the chosen surface's
    /// own appearance, guidance, reading, and size settings.
    func selectOverlayMode(_ mode: TeleprompterOverlayMode) {
        guard overlayMode != mode else { return }
        if isPreviewingInNotch || isPreviewingFloating { closeNotchPreview() }
        savePlacementProfile(for: overlayMode)
        overlayMode = mode
        loadPlacementProfile(for: mode)
        let widthRange = Self.windowWidthRange(for: mode)
        let heightRange = Self.windowHeightRange(for: mode)
        windowWidth = min(widthRange.upperBound, max(widthRange.lowerBound, windowWidth))
        windowHeight = min(heightRange.upperBound, max(heightRange.lowerBound, windowHeight))
        savePreferences()
    }

    /// Move an active session when the user changes its selected placement.
    func applyOverlayPlacement() {
        guard isRunning else { return }
        if overlayMode == .floating {
            presentFloatingSurface()
        } else {
            presentNotchSurface()
        }
    }

    private func presentNotchSurface() {
        updateNotchSurfaceSize()
        floatingWindowVisible = false
        TeleprompterFloatingWindowController.shared.hide()
        if NotchSupport.isEnabled() {
            NotchService.shared.open(.teleprompter)
        } else {
            floatingWindowVisible = true
            TeleprompterFloatingWindowController.shared.showAtNotch()
        }
    }

    private func presentFloatingSurface() {
        NotchService.shared.setTeleprompterSurfaceSize(nil)
        NotchService.shared.collapse()
        floatingWindowVisible = true
        TeleprompterFloatingWindowController.shared.show()
    }

    func previewInNotch(autoCloseAfter inactivityInterval: TimeInterval? = nil) {
        if isRunning {
            updateNotchSurfaceSize()
        } else {
            NotchService.shared.setTeleprompterSurfaceSize(
                overlayMode == .notch ? CGSize(width: windowWidth, height: windowHeight) : nil
            )
        }
        guard !isRunning else {
            if overlayMode == .floating { TeleprompterFloatingWindowController.shared.updateFrame() }
            return
        }
        if overlayMode == .floating {
            let isChangingSurface = !isPreviewingFloating
            if isChangingSurface {
                previewWordProgress = 0
                previewPageIndex = 0
            }
            isPreviewingInNotch = false
            isPreviewingFloating = true
            let shouldPresentWindow = isChangingSurface || !floatingWindowVisible
            if shouldPresentWindow {
                NotchService.shared.collapse()
                floatingWindowVisible = true
                TeleprompterFloatingWindowController.shared.show()
            } else {
                TeleprompterFloatingWindowController.shared.updateFrame()
            }
            startPreviewProgressTimerIfNeeded()
        } else {
            let isChangingSurface = !isPreviewingInNotch
            if isChangingSurface {
                previewWordProgress = 0
                previewPageIndex = 0
            }
            if isChangingSurface { restoreFloatingAfterNotchPreview = floatingWindowVisible }
            isPreviewingFloating = false
            isPreviewingInNotch = true
            if isChangingSurface || NotchService.shared.selected != .teleprompter || !NotchService.shared.expanded {
                presentNotchSurface()
            }
            startPreviewProgressTimerIfNeeded()
        }

        notchPreviewIdleTask?.cancel()
        guard let inactivityInterval else { return }
        notchPreviewIdleTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, inactivityInterval) * 1_000_000_000))
            } catch {
                return
            }
            guard let self, self.isPreviewingInNotch || self.isPreviewingFloating, !self.isRunning else { return }
            self.closeNotchPreview()
        }
    }

    func endNotchPreview() {
        let wasFloatingPreview = isPreviewingFloating
        notchPreviewIdleTask?.cancel()
        notchPreviewIdleTask = nil
        previewProgressTimer?.invalidate()
        previewProgressTimer = nil
        isPreviewingInNotch = false
        isPreviewingFloating = false
        restoreFloatingAfterNotchPreview = false
        NotchService.shared.setTeleprompterSurfaceSize(nil)
        if wasFloatingPreview && !isRunning {
            floatingWindowVisible = false
            TeleprompterFloatingWindowController.shared.hide()
        }
    }

    func closeNotchPreview() {
        let restoreFloating = restoreFloatingAfterNotchPreview && overlayMode == .floating
        let wasNotchPreview = isPreviewingInNotch
        endNotchPreview()
        if wasNotchPreview && NotchService.shared.selected == .teleprompter {
            NotchService.shared.backFromTeleprompter()
        }
        if restoreFloating { presentFloatingSurface() }
    }

    private func startPreviewProgressTimerIfNeeded() {
        guard previewProgressTimer == nil else { return }
        previewProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPreviewingInNotch || self.isPreviewingFloating else { return }
                let wordCount = max(1, splitTextIntoWords(self.previewCurrentScript).count)
                let next = self.previewWordProgress + self.scrollSpeed * 0.05
                self.previewWordProgress = next >= Double(wordCount) ? 0 : next
            }
        }
    }

    func previousPreviewPage() {
        guard previewPageIndex > 0 else { return }
        previewPageIndex -= 1
        previewWordProgress = 0
    }

    func nextPreviewPage() {
        guard previewPageIndex < Self.previewPages.count - 1 else { return }
        previewPageIndex += 1
        previewWordProgress = 0
    }

    private func updateNotchSurfaceSize() {
        guard overlayMode == .notch, isRunning || isPreviewingInNotch else {
            NotchService.shared.setTeleprompterSurfaceSize(nil)
            return
        }
        NotchService.shared.setTeleprompterSurfaceSize(
            CGSize(width: windowWidth, height: windowHeight)
        )
    }

    func closeFloatingWindow() {
        if isRunning {
            stop()
        } else {
            if isPreviewingFloating { endNotchPreview() }
            floatingWindowVisible = false
            TeleprompterFloatingWindowController.shared.hide()
        }
    }

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
        endNotchPreview()
        isRunning = true
        isPaused = false
        restartSpeechOnResume = false
        timerWordProgress = 0
        sessionStartTime = Date()
        elapsedSeconds = 0

        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, !self.isPaused else { return }
                self.elapsedSeconds += 1
            }
        }

        if keepScreenAwake {
            IOPMAssertionCreateWithName(
                "PreventUserIdleDisplaySleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Vorssaint Teleprompter Session" as CFString,
                &sleepAssertionID
            )
        }

        let script = currentScript
        words = splitTextIntoWords(script)

        if guidanceMode == .classic {
            speechRecognizer.stop()
            startAutoScrollTimer()
        } else {
            speechRecognizer.start(with: script)
            startAutoScrollTimerIfNeeded()
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
                mode: externalDisplayMode,
                mirrorAxis: externalMirrorAxis
            )
        }

        if overlayMode == .notch {
            presentNotchSurface()
        } else {
            presentFloatingSurface()
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
        if guidanceMode == .classic {
            startAutoScrollTimer()
        } else if restartSpeechOnResume {
            speechRecognizer.start(with: currentScript)
            restartSpeechOnResume = false
            startAutoScrollTimerIfNeeded()
        } else {
            speechRecognizer.resume()
            startAutoScrollTimerIfNeeded()
        }
    }

    func stop() {
        endNotchPreview()
        isRunning = false
        isPaused = false
        restartSpeechOnResume = false
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        sessionStartTime = nil
        elapsedSeconds = 0

        if sleepAssertionID != 0 {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }

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
        timerWordProgress = wordProgressForCharOffset(charOffset)
    }

    func nextPage() {
        if isRunning { readPages.insert(currentPageIndex) }
        guard !pages.isEmpty, currentPageIndex < pages.count - 1 else {
            stop()
            return
        }
        currentPageIndex += 1
        timerWordProgress = 0
        restartCurrentPage()
    }

    func previousPage() {
        guard !pages.isEmpty, currentPageIndex > 0 else { return }
        currentPageIndex -= 1
        timerWordProgress = 0
        restartCurrentPage()
    }

    private func restartCurrentPage() {
        let script = currentScript
        words = splitTextIntoWords(script)
        timerWordProgress = 0
        if !isRunning || isPaused {
            speechRecognizer.stop()
            if isRunning && isPaused && guidanceMode != .classic {
                restartSpeechOnResume = true
            }
        } else if guidanceMode == .classic {
            speechRecognizer.stop()
            startAutoScrollTimer()
        } else {
            speechRecognizer.start(with: script)
            startAutoScrollTimerIfNeeded()
        }

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
                mode: externalDisplayMode,
                mirrorAxis: externalMirrorAxis
            )
        }
    }

    // MARK: - Word Progress & Auto Scroll Helpers

    func charOffsetForWordProgress(_ progress: Double) -> Int {
        let wholeWord = Int(progress)
        let frac = progress - Double(wholeWord)
        var offset = 0
        let w = currentWords
        for i in 0..<min(wholeWord, w.count) {
            offset += w[i].count + 1
        }
        if wholeWord < w.count {
            offset += Int(Double(w[wholeWord].count) * frac)
        }
        return min(offset, currentScript.count)
    }

    func wordProgressForCharOffset(_ charOffset: Int) -> Double {
        var offset = 0
        let w = currentWords
        for (i, word) in w.enumerated() {
            let end = offset + word.count
            if charOffset <= end {
                let frac = Double(charOffset - offset) / Double(max(1, word.count))
                return Double(i) + frac
            }
            offset = end + 1
        }
        return Double(w.count)
    }

    // MARK: - Auto Scroll for Classic and Voice-Activated Modes

    private func startAutoScrollTimer() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, !self.isPaused else { return }
                self.tickAutoScroll()
            }
        }
    }

    private func startAutoScrollTimerIfNeeded() {
        if guidanceMode != .wordTracking { startAutoScrollTimer() }
    }

    private func tickAutoScroll() {
        guard !currentWords.isEmpty else { return }

        if guidanceMode == .voiceActivated {
            guard speechRecognizer.isSpeaking else { return }
        }

        let speed = scrollSpeed // words per second
        timerWordProgress += speed * 0.05
        let nextChar = charOffsetForWordProgress(timerWordProgress)
        speechRecognizer.recognizedCharCount = nextChar

        if timerWordProgress >= Double(currentWords.count) {
            if autoNextPage && currentPageIndex < pages.count - 1 {
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
        if let first = pages.first {
            text = first
        }
        savePreferences()
    }
}
