// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Based on Textream by Fatih Kadir Akın (MIT License)

import AppKit
import CoreImage.CIFilterBuiltins
import Speech
import SwiftUI

// MARK: - Inline Waveform for Dictation

struct DictationWaveformView: View {
    let levels: [CGFloat]
    var color: Color = .red

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<min(24, levels.count), id: \.self) { idx in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 2.5, height: max(4, levels[idx] * 22))
            }
        }
        .frame(height: 24)
    }
}

// MARK: - Teleprompter Settings View

struct TeleprompterSettings: View {
    @ObservedObject private var service = TeleprompterService.shared
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var dictation = TeleprompterService.shared.dictationManager

    @State private var inputDevices: [AudioInputDevice] = AudioInputDevice.allInputDevices()
    @State private var importErrorMessage: String?
    @State private var showingImportError = false

    // Dictation & Caret Tracking
    @State private var dictationHighlightRange: NSRange? = nil
    @State private var dictationCaretPosition: Int? = nil
    @State private var editorCaretPosition: Int = 0
    @State private var highlightClearTimer: Timer?

    @State private var segmentStart: Int = 0
    @State private var segmentLength: Int = 0
    @State private var segmentNeedsSeparator: Bool = false
    @State private var spokenSkipOffset: Int = 0
    @State private var lastRawSpokenLength: Int = 0

    // Tab for Remote Controls
    @State private var selectedRemoteTab: Int = 0

    private var scriptBinding: Binding<String> {
        Binding(
            get: { service.currentScript },
            set: { newValue in
                service.currentScript = newValue
            }
        )
    }

    private var estimatedReadingTimeText: String {
        let words = service.totalWordCount
        guard words > 0 else { return "0m 0s" }
        // Average speaking pace ~130 words per minute
        let seconds = Int(Double(words) / 130.0 * 60.0)
        let mins = seconds / 60
        let remSecs = seconds % 60
        return mins > 0 ? "~\(mins)m \(remSecs)s" : "~\(remSecs)s"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // MARK: 1. Script Studio & Notes
                SettingsCard(title: "Script Studio & Notes") {
                    // Header Bar: Play/Pause/Stop & Live Status
                    HStack(spacing: 12) {
                        Button {
                            service.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: service.isRunning && !service.isPaused ? "pause.fill" : "play.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(service.isRunning && !service.isPaused ? "Pause Prompter" : (service.isRunning ? "Resume" : "Start Prompter"))
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(service.isRunning && !service.isPaused ? .orange : .accentColor)

                        if service.isRunning {
                            Button {
                                service.stop()
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                        }

                        Spacer()

                        // Status Pill
                        HStack(spacing: 6) {
                            Circle()
                                .fill(service.isRunning ? (service.isPaused ? Color.yellow : Color.red) : Color.secondary.opacity(0.5))
                                .frame(width: 8, height: 8)

                            Text(service.isRunning ? (service.isPaused ? "Paused" : "Live (\(service.overlayMode.label))") : "Ready")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(service.isRunning ? .primary : .secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    }

                    Divider()

                    // Multi-page Tabs Bar
                    HStack(spacing: 8) {
                        if service.pages.isEmpty {
                            Text("Page 1")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(service.pages.indices, id: \.self) { idx in
                                        let isCurrent = idx == service.currentPageIndex
                                        let isRead = service.readPages.contains(idx)
                                        Button {
                                            service.jumpToPage(index: idx)
                                        } label: {
                                            HStack(spacing: 4) {
                                                Text("Page \(idx + 1)")
                                                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                                                if isRead {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 10, weight: .bold))
                                                        .foregroundStyle(.green)
                                                }
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(isCurrent ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
                                            .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        Button {
                            service.addPage()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .medium))
                                .padding(5)
                                .background(Color.secondary.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Add New Page")

                        if service.pages.count > 1 {
                            Button {
                                service.removePage(at: service.currentPageIndex)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red.opacity(0.8))
                                    .padding(5)
                                    .background(Color.secondary.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Delete Current Page")
                        }

                        Spacer()
                    }

                    // Dictation & Tools Bar
                    HStack(spacing: 12) {
                        Button {
                            toggleDictation()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(dictation.isRecording ? .red : .primary)
                                Text(dictation.isRecording ? "Listening..." : "Dictate")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(dictation.isRecording ? Color.red.opacity(0.15) : Color.secondary.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        if dictation.isRecording {
                            DictationWaveformView(levels: dictation.audioLevels, color: .red)
                        }

                        Spacer()

                        // Insert Annotation Menu
                        Menu {
                            Button("Insert [pause]") { insertAnnotation("[pause]") }
                            Button("Insert [smile]") { insertAnnotation("[smile]") }
                            Button("Insert [nod]") { insertAnnotation("[nod]") }
                            Button("Insert [wave]") { insertAnnotation("[wave]") }
                        } label: {
                            Label("Insert Cue", systemImage: "sparkles")
                                .font(.system(size: 12))
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 110)

                        // Clear Button
                        Button("Clear") {
                            service.currentScript = ""
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }

                    // Highlighting Text Editor Area
                    HighlightingTextEditor(
                        text: scriptBinding,
                        font: service.fontFamily.nsFont(ofSize: 15),
                        highlightRange: dictationHighlightRange,
                        caretPosition: $dictationCaretPosition,
                        editorCaretPosition: $editorCaretPosition
                    )
                    .frame(minHeight: 200, maxHeight: 360)
                    .padding(10)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )

                    // Footer Stats Bar
                    HStack(spacing: 16) {
                        Text("\(service.totalWordCount) words")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("Reading time: \(estimatedReadingTimeText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("\(service.currentScript.count) chars")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if let dictErr = dictation.error {
                            Text(dictErr)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                    }
                }

                // MARK: 2. Guidance Mode Card
                SettingsCard(title: "Guidance Mode") {
                    Picker("Mode", selection: $service.guidanceMode) {
                        ForEach(GuidanceMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: service.guidanceMode) {
                        service.savePreferences()
                    }

                    Text(service.guidanceMode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if service.guidanceMode != .wordTracking {
                        Divider()
                        VStack(spacing: 6) {
                            HStack {
                                Text("Scroll Speed")
                                Spacer()
                                Text(String(format: "%.1f words/sec", service.scrollSpeed))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $service.scrollSpeed, in: 0.5...8.0, step: 0.5)
                                .onChange(of: service.scrollSpeed) {
                                    service.savePreferences()
                                }
                        }
                    }
                }

                // MARK: 3. Overlay & Display Card
                SettingsCard(title: "Display & Overlay") {
                    Picker("Placement", selection: $service.overlayMode) {
                        ForEach(TeleprompterOverlayMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: service.overlayMode) {
                        service.savePreferences()
                    }

                    Divider()

                    HStack {
                        Text("Font Family")
                        Spacer()
                        Picker("", selection: $service.fontFamily) {
                            ForEach(TeleprompterFontFamilyPreset.allCases) { font in
                                Text(font.label).tag(font)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                        .onChange(of: service.fontFamily) {
                            service.savePreferences()
                        }
                    }

                    HStack {
                        Text("Font Size")
                        Spacer()
                        Picker("", selection: $service.fontSize) {
                            ForEach(TeleprompterFontSizePreset.allCases) { size in
                                Text(size.label).tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                        .onChange(of: service.fontSize) {
                            service.savePreferences()
                        }
                    }

                    HStack {
                        Text("Highlight Color")
                        Spacer()
                        HStack(spacing: 8) {
                            ForEach(TeleprompterHighlightColorPreset.allCases) { preset in
                                Circle()
                                    .fill(preset.color)
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.white, lineWidth: service.highlightColor == preset ? 2 : 0)
                                    )
                                    .onTapGesture {
                                        service.highlightColor = preset
                                        service.savePreferences()
                                    }
                            }
                        }
                    }
                }

                // MARK: 4. External Display (Second Screen / Prompter Glass)
                SettingsCard(title: "External Display & Mirroring") {
                    Picker("External Display Output", selection: $service.externalDisplayMode) {
                        ForEach(ExternalDisplayMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: service.externalDisplayMode) {
                        service.savePreferences()
                    }

                    Text("Project the teleprompter onto a second screen, projector, or teleprompter beam-splitter glass rig.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if service.externalDisplayMode != .off {
                        Divider()

                        HStack {
                            Text("Target Screen")
                            Spacer()
                            let externalScreens = NSScreen.screens.filter { $0 != NSScreen.main }
                            if externalScreens.isEmpty {
                                Text("No external display detected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("", selection: $service.externalScreenID) {
                                    ForEach(externalScreens, id: \.displayID) { scr in
                                        Text(scr.displayName).tag(scr.displayID)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 200)
                                .onChange(of: service.externalScreenID) {
                                    service.savePreferences()
                                }
                            }
                        }

                        if service.externalDisplayMode == .mirror {
                            HStack {
                                Text("Mirror Axis (Glass Reflection)")
                                Spacer()
                                Picker("", selection: $service.externalMirrorAxis) {
                                    ForEach(ExternalMirrorAxis.allCases) { axis in
                                        Text(axis.label).tag(axis)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 240)
                                .onChange(of: service.externalMirrorAxis) {
                                    service.savePreferences()
                                }
                            }
                        }
                    }
                }

                // MARK: 5. Microphone & Speech Card
                SettingsCard(title: "Microphone & Speech") {
                    HStack {
                        Text("Input Microphone")
                        Spacer()
                        Picker("", selection: $service.selectedMicUID) {
                            Text("System Default").tag("")
                            ForEach(inputDevices) { dev in
                                Text(dev.name).tag(dev.uid)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)
                        .onChange(of: service.selectedMicUID) {
                            service.savePreferences()
                        }
                    }

                    HStack {
                        Text("Speech Language")
                        Spacer()
                        Picker("", selection: $service.speechLocale) {
                            ForEach(SpeechLocaleSupport.supportedLocales, id: \.identifier) { loc in
                                Text(Locale.current.localizedString(forIdentifier: loc.identifier) ?? loc.identifier)
                                    .tag(loc.identifier)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)
                        .onChange(of: service.speechLocale) {
                            service.savePreferences()
                        }
                    }
                }

                // MARK: 6. Presentation & Notes Import Card
                SettingsCard(title: "Import Script & Slides") {
                    Text("Import slides and presenter notes directly from a PowerPoint (.pptx) file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Import PowerPoint (.pptx)...") {
                        chooseAndImportPPTX()
                    }
                    .buttonStyle(.bordered)
                }

                // MARK: 7. Remote Prompter & Director Studio
                SettingsCard(title: "Remote Controls & Director Studio") {
                    Picker("", selection: $selectedRemoteTab) {
                        Text("Viewer Remote (Phone / Web)").tag(0)
                        Text("Director Studio (Live Production)").tag(1)
                    }
                    .pickerStyle(.segmented)

                    if selectedRemoteTab == 0 {
                        // Viewer Remote
                        Toggle("Enable Browser Remote", isOn: $service.remoteServerEnabled)
                            .onChange(of: service.remoteServerEnabled) { _, enabled in
                                service.savePreferences()
                                if enabled {
                                    service.remoteServer.start()
                                } else {
                                    service.remoteServer.stop()
                                }
                            }

                        if service.remoteServerEnabled {
                            let ip = TeleprompterServer.localIPAddress() ?? "localhost"
                            let urlStr = "http://\(ip):\(service.remoteServer.httpPort)"

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Open in any phone, tablet, or secondary computer browser:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack {
                                    Text(urlStr)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)

                                    Button("Copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(urlStr, forType: .string)
                                    }
                                    .buttonStyle(.bordered)
                                }

                                if let qr = generateQRCode(from: urlStr) {
                                    Image(nsImage: qr)
                                        .interpolation(.none)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 130, height: 130)
                                        .padding(8)
                                        .background(Color.white)
                                        .cornerRadius(12)
                                }
                            }
                            .padding(.top, 4)
                        }
                    } else {
                        // Director Studio
                        Toggle("Enable Director Studio Server", isOn: $service.directorServerEnabled)
                            .onChange(of: service.directorServerEnabled) { _, enabled in
                                service.savePreferences()
                                if enabled {
                                    service.directorServer.start()
                                } else {
                                    service.directorServer.stop()
                                }
                            }

                        Text("Allows a remote director to view the live transcript, advance pages, and edit the presenter's script in real time from a phone or laptop.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if service.directorServerEnabled {
                            let ip = TeleprompterServer.localIPAddress() ?? "localhost"
                            let urlStr = "http://\(ip):\(service.directorServer.httpPort)"

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(urlStr)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)

                                    Button("Copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(urlStr, forType: .string)
                                    }
                                    .buttonStyle(.bordered)

                                    Spacer()

                                    Text("\(service.directorServer.connectedClients) connected")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                if let qr = generateQRCode(from: urlStr) {
                                    Image(nsImage: qr)
                                        .interpolation(.none)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 130, height: 130)
                                        .padding(8)
                                        .background(Color.white)
                                        .cornerRadius(12)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            inputDevices = AudioInputDevice.allInputDevices()
        }
        .alert("Import Failed", isPresented: $showingImportError) {
            Button("OK") { }
        } message: {
            Text(importErrorMessage ?? "Could not extract presenter notes.")
        }
    }

    // MARK: - Dictation Actions

    private func toggleDictation() {
        if dictation.isRecording {
            stopDictation()
        } else {
            startDictation()
        }
    }

    private func startDictation() {
        lastRawSpokenLength = 0
        spokenSkipOffset = 0
        beginNewSegment()

        dictation.onNewSegment = {
            lastRawSpokenLength = 0
            spokenSkipOffset = 0
            beginNewSegment()
        }

        dictation.onTextUpdate = { spokenText in
            lastRawSpokenLength = spokenText.count

            let effectiveText: String
            if spokenSkipOffset < spokenText.count {
                effectiveText = String(spokenText.suffix(spokenText.count - spokenSkipOffset))
            } else {
                effectiveText = ""
            }
            guard !effectiveText.isEmpty else { return }

            var text = service.currentScript
            let safeStart = min(segmentStart, text.count)
            let removeStart = text.index(text.startIndex, offsetBy: safeStart)
            let safeLen = min(segmentLength, text.count - safeStart)
            let removeEnd = text.index(removeStart, offsetBy: safeLen)
            text.removeSubrange(removeStart..<removeEnd)

            let sep = segmentNeedsSeparator ? " " : ""
            let newSegment = sep + effectiveText
            text.insert(contentsOf: newSegment, at: text.index(text.startIndex, offsetBy: min(segmentStart, text.count)))

            let prevLen = segmentLength
            segmentLength = newSegment.count
            service.currentScript = text

            let newChars = segmentLength - prevLen
            if newChars > 0 {
                let highlightStart = segmentStart + prevLen
                dictationHighlightRange = NSRange(location: highlightStart, length: newChars)
            }

            dictationCaretPosition = segmentStart + segmentLength

            highlightClearTimer?.invalidate()
            highlightClearTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                MainActor.assumeIsolated {
                    dictationHighlightRange = nil
                }
            }
        }

        dictation.start()
    }

    private func stopDictation() {
        highlightClearTimer?.invalidate()
        highlightClearTimer = nil
        dictationHighlightRange = nil
        dictation.stop()
    }

    private func beginNewSegment() {
        let text = service.currentScript
        let caret = min(editorCaretPosition, text.count)
        spokenSkipOffset = lastRawSpokenLength

        let charBefore = caret > 0 ? text[text.index(text.startIndex, offsetBy: caret - 1)] : "\n"
        segmentNeedsSeparator = !(charBefore == " " || charBefore == "\n" || caret == 0)
        segmentStart = caret
        segmentLength = 0
    }

    private func insertAnnotation(_ tag: String) {
        var text = service.currentScript
        let caret = min(editorCaretPosition, text.count)
        let insertion = " \(tag) "
        text.insert(contentsOf: insertion, at: text.index(text.startIndex, offsetBy: caret))
        service.currentScript = text
        dictationCaretPosition = caret + insertion.count
    }

    // MARK: - PPTX Import & QR Code

    private func chooseAndImportPPTX() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "pptx")].compactMap { $0 }

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try service.importPPTX(url: url)
            } catch {
                importErrorMessage = error.localizedDescription
                showingImportError = true
            }
        }
    }

    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 140, height: 140))
    }
}
