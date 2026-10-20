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
                    .frame(width: 2.5, height: max(4, levels[idx] * 20))
            }
        }
        .frame(height: 20)
    }
}

// MARK: - Teleprompter Settings View

struct TeleprompterSettings: View {
    @ObservedObject private var service = TeleprompterService.shared
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var dictation = TeleprompterService.shared.dictationManager

    @AppStorage(DefaultsKey.teleprompterEnabled) private var teleprompterEnabled = true

    @State private var inputDevices: [AudioInputDevice] = AudioInputDevice.allInputDevices()
    @State private var editingPageIndex: Int? = nil
    @State private var editingPageText: String = ""
    @State private var confirmingReset = false
    @State private var showingImportError = false
    @State private var importErrorMessage: String? = nil

    private var strings: TeleprompterStrings {
        FeatureStrings.teleprompter(l10n.language)
    }

    private var pagesList: [String] {
        if service.pages.isEmpty {
            return [service.text]
        }
        return service.pages
    }

    var body: some View {
        Form {
            // MARK: - 1. Master Section
            Section {
                Toggle(strings.title, isOn: $teleprompterEnabled)
                Text(strings.hubDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(strings.title)
            }

            // MARK: - 2. Script Studio & Notes Section
            Section {
                ForEach(pagesList.indices, id: \.self) { idx in
                    pageRow(index: idx)
                }

                HStack(spacing: 10) {
                    Button {
                        addNewPage()
                    } label: {
                        Label("Add Page", systemImage: "plus")
                    }

                    Button {
                        chooseAndImportPPTX()
                    } label: {
                        Label("Import .pptx...", systemImage: "doc.badge.plus")
                    }

                    Spacer()

                    // Right-aligned start prompter controls in the second row
                    HStack(spacing: 8) {
                        Button {
                            service.toggle()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: service.isRunning && !service.isPaused ? "pause.fill" : "play.fill")
                                Text(service.isRunning && !service.isPaused ? strings.pause : (service.isRunning ? strings.resume : strings.start))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(service.isRunning && !service.isPaused ? .orange : .accentColor)

                        if service.isRunning {
                            Button {
                                service.stop()
                            } label: {
                                Label(strings.stop, systemImage: "stop.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.top, 4)
            } header: {
                Text("Script Studio & Notes")
            }
            .disabled(!teleprompterEnabled)

            // MARK: - 3. Appearance Section
            Section {
                Picker("Font Family", selection: $service.fontFamily) {
                    ForEach(TeleprompterFontFamilyPreset.allCases) { family in
                        Text(family.label).tag(family)
                    }
                }
                .onChange(of: service.fontFamily) { _ in service.savePreferences() }

                Picker("Font Size", selection: $service.fontSize) {
                    ForEach(TeleprompterFontSizePreset.allCases) { size in
                        Text("\(size.label) (\(Int(size.pointSize)) pt)").tag(size)
                    }
                }
                .onChange(of: service.fontSize) { _ in service.savePreferences() }

                Picker("Highlight Color", selection: $service.highlightColor) {
                    ForEach(TeleprompterHighlightColorPreset.allCases) { col in
                        HStack(spacing: 6) {
                            Circle().fill(col.color).frame(width: 10, height: 10)
                            Text(col.label)
                        }
                        .tag(col)
                    }
                }
                .onChange(of: service.highlightColor) { _ in service.savePreferences() }

                Picker("Cue Color", selection: $service.cueColor) {
                    ForEach(TeleprompterCueColorPreset.allCases) { cueCol in
                        HStack(spacing: 6) {
                            Circle().fill(cueCol.color).frame(width: 10, height: 10)
                            Text(cueCol.label)
                        }
                        .tag(cueCol)
                    }
                }
                .onChange(of: service.cueColor) { _ in service.savePreferences() }

                Picker("Cue Brightness", selection: $service.cueBrightness) {
                    ForEach(TeleprompterCueBrightness.allCases) { bright in
                        Text(bright.label).tag(bright)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: service.cueBrightness) { _ in service.savePreferences() }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Window Width")
                        Spacer()
                        Text("\(Int(service.windowWidth)) px")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $service.windowWidth, in: 300...900, step: 10)
                        .onChange(of: service.windowWidth) { _ in service.savePreferences() }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Window Height")
                        Spacer()
                        Text("\(Int(service.windowHeight)) px")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $service.windowHeight, in: 120...600, step: 10)
                        .onChange(of: service.windowHeight) { _ in service.savePreferences() }
                }
            } header: {
                Text("Appearance")
            }
            .disabled(!teleprompterEnabled)

            // MARK: - 4. Guidance Section
            Section {
                Picker("Tracking Mode", selection: $service.guidanceMode) {
                    ForEach(GuidanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: service.guidanceMode) { _ in service.savePreferences() }

                if service.guidanceMode != .wordTracking {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Scroll Speed")
                            Spacer()
                            Text(String(format: "%.1fx", service.scrollSpeed))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $service.scrollSpeed, in: 1.0...6.0, step: 0.1)
                            .onChange(of: service.scrollSpeed) { _ in service.savePreferences() }
                    }
                }

                Picker("Speech Language", selection: $service.speechLocale) {
                    ForEach(SpeechLocaleSupport.supportedLocales, id: \.identifier) { loc in
                        Text(Locale.current.localizedString(forIdentifier: loc.identifier) ?? loc.identifier)
                            .tag(loc.identifier)
                    }
                }
                .onChange(of: service.speechLocale) { _ in service.savePreferences() }

                Picker("Microphone", selection: $service.selectedMicUID) {
                    Text("System Default").tag("")
                    ForEach(inputDevices) { dev in
                        Text(dev.name).tag(dev.uid)
                    }
                }
                .onChange(of: service.selectedMicUID) { _ in service.savePreferences() }
            } header: {
                Text("Guidance")
            }
            .disabled(!teleprompterEnabled)

            // MARK: - 5. Reading Section
            Section {
                Picker("Reading Position", selection: $service.readingPosition) {
                    ForEach(TeleprompterReadingPosition.allCases) { pos in
                        Text(pos.label).tag(pos)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: service.readingPosition) { _ in service.savePreferences() }

                Toggle("Show paragraph dividers", isOn: $service.showParagraphDividers)
                    .onChange(of: service.showParagraphDividers) { _ in service.savePreferences() }

                Toggle("Show last spoken word", isOn: $service.showLastSpokenWords)
                    .onChange(of: service.showLastSpokenWords) { _ in service.savePreferences() }

                Toggle("Keep screen awake while teleprompter is active", isOn: $service.keepScreenAwake)
                    .onChange(of: service.keepScreenAwake) { _ in service.savePreferences() }
            } header: {
                Text("Reading")
            }
            .disabled(!teleprompterEnabled)

            // MARK: - 6. Teleprompter Window & Display Section
            Section {
                Picker("Window Placement", selection: $service.overlayMode) {
                    ForEach(TeleprompterOverlayMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: service.overlayMode) { _ in service.savePreferences() }

                Picker("Display Target", selection: $service.displayTargetMode) {
                    ForEach(TeleprompterDisplayTargetMode.allCases) { tm in
                        Text(tm.label).tag(tm)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: service.displayTargetMode) { _ in service.savePreferences() }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Window Transparency")
                        Spacer()
                        Text("\(Int((service.overlayTransparency) * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $service.overlayTransparency, in: 0.0...0.5, step: 0.05)
                        .onChange(of: service.overlayTransparency) { _ in service.savePreferences() }
                }

                Toggle("Show elapsed time", isOn: $service.showElapsedTime)
                    .onChange(of: service.showElapsedTime) { _ in service.savePreferences() }

                Toggle("Hide from screen sharing", isOn: $service.hideFromScreenShare)
                    .onChange(of: service.hideFromScreenShare) { _ in service.savePreferences() }

                Toggle("Auto next page", isOn: $service.autoNextPage)
                    .onChange(of: service.autoNextPage) { _ in service.savePreferences() }
            } header: {
                Text("Teleprompter Window & Display")
            }
            .disabled(!teleprompterEnabled)

            // MARK: - 7. External Display Section
            Section {
                Picker("Mode", selection: $service.externalDisplayMode) {
                    ForEach(ExternalDisplayMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: service.externalDisplayMode) { _ in service.savePreferences() }

                if service.externalDisplayMode != .off {
                    let externalScreens = NSScreen.screens.filter { $0 != NSScreen.main }
                    if externalScreens.isEmpty {
                        Text("No external display detected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Target Screen", selection: $service.externalScreenID) {
                            ForEach(externalScreens, id: \.displayID) { scr in
                                Text(scr.localizedName).tag(scr.displayID)
                            }
                        }
                        .onChange(of: service.externalScreenID) { _ in service.savePreferences() }
                    }

                    if service.externalDisplayMode == .mirror {
                        Picker("Mirror Axis", selection: $service.externalMirrorAxis) {
                            ForEach(ExternalMirrorAxis.allCases) { axis in
                                Text(axis.label).tag(axis)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: service.externalMirrorAxis) { _ in service.savePreferences() }
                    }
                }
            } header: {
                Text("External Display")
            }
            .disabled(!teleprompterEnabled)

            // MARK: - 8. Remote Control Section
            Section {
                Toggle("Enable Browser Remote", isOn: $service.remoteServerEnabled)
                    .onChange(of: service.remoteServerEnabled) { _, on in
                        service.savePreferences()
                        if on {
                            service.remoteServer.start()
                        } else {
                            service.remoteServer.stop()
                        }
                    }

                if service.remoteServerEnabled {
                    remoteViewerDetails
                }
            } header: {
                Text("Remote Control")
            }
            .disabled(!teleprompterEnabled)

            // MARK: - 9. Director Studio Section
            Section {
                Toggle("Enable Director Server", isOn: $service.directorServerEnabled)
                    .onChange(of: service.directorServerEnabled) { _, on in
                        service.savePreferences()
                        if on {
                            service.directorServer.start()
                        } else {
                            service.directorServer.stop()
                        }
                    }

                if service.directorServerEnabled {
                    directorStudioDetails
                }
            } header: {
                Text("Director Studio")
            }
            .disabled(!teleprompterEnabled)

            // MARK: - 10. Reset Section
            Section {
                Button(role: .destructive) {
                    confirmingReset = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset Teleprompter Settings")
                    }
                }
                .confirmationDialog(
                    "Reset Teleprompter Settings?",
                    isPresented: $confirmingReset,
                    titleVisibility: .visible
                ) {
                    Button("Reset to Defaults", role: .destructive) {
                        service.resetSettings()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will reset all appearance, guidance, reading, display, and server settings to their defaults. Your scripts and pages will not be deleted.")
                }
            } header: {
                Text("Reset")
            }
            .disabled(!teleprompterEnabled)
        }
        .formStyle(.grouped)
        .onAppear {
            inputDevices = AudioInputDevice.allInputDevices()
        }
        .sheet(isPresented: Binding(
            get: { editingPageIndex != nil },
            set: { if !$0 { closePageEditor() } }
        )) {
            if let idx = editingPageIndex {
                PageEditorDialog(
                    pageIndex: idx,
                    text: $editingPageText,
                    service: service,
                    dictation: dictation,
                    onDone: { closePageEditor() }
                )
            }
        }
        .alert("Import Failed", isPresented: $showingImportError) {
            Button("OK") { }
        } message: {
            Text(importErrorMessage ?? "Could not extract presenter notes.")
        }
    }

    // MARK: - Page Row Component

    private func pageRow(index: Int) -> some View {
        let isSelected = index == service.currentPageIndex
        let pageContent = (index < pagesList.count) ? pagesList[index] : ""
        let snippet = previewSnippet(pageContent)

        return HStack(spacing: 12) {
            Button {
                service.jumpToPage(index: index)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Page \(index + 1)")
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)

                        Text(snippet.isEmpty ? "Empty page" : snippet)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Menu {
                Button {
                    openPageEditor(index: index)
                } label: {
                    Label("Edit Page...", systemImage: "pencil")
                }

                Button {
                    duplicatePage(at: index)
                } label: {
                    Label("Duplicate Page", systemImage: "plus.square.on.square")
                }

                Divider()

                Button(role: .destructive) {
                    deletePage(at: index)
                } label: {
                    Label("Delete Page", systemImage: "trash")
                }
                .disabled(pagesList.count <= 1)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button("Edit") {
                openPageEditor(index: index)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            openPageEditor(index: index)
        }
        .onTapGesture(count: 1) {
            service.jumpToPage(index: index)
        }
    }

    private func previewSnippet(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count > 65 {
            return clean.prefix(65) + "..."
        }
        return clean
    }

    // MARK: - Page Actions

    private func openPageEditor(index: Int) {
        if service.pages.isEmpty {
            service.pages = [service.text]
        }
        if index < service.pages.count {
            editingPageIndex = index
            editingPageText = service.pages[index]
        }
    }

    private func closePageEditor() {
        if let idx = editingPageIndex, idx < service.pages.count {
            service.pages[idx] = editingPageText
            service.savePreferences()
        }
        editingPageIndex = nil
    }

    private func addNewPage() {
        service.addPage()
        let newIdx = max(0, service.pages.count - 1)
        editingPageIndex = newIdx
        editingPageText = service.pages[newIdx]
    }

    private func duplicatePage(at index: Int) {
        guard index < pagesList.count else { return }
        if service.pages.isEmpty {
            service.pages = [service.text]
        }
        let copy = service.pages[index]
        service.pages.insert(copy, at: index + 1)
        service.savePreferences()
    }

    private func deletePage(at index: Int) {
        service.removePage(at: index)
    }

    // MARK: - Remote Details

    @ViewBuilder
    private var remoteViewerDetails: some View {
        let ip = TeleprompterServer.localIPAddress() ?? "localhost"
        let urlStr = "http://\(ip):\(service.remoteServer.httpPort)"

        VStack(alignment: .leading, spacing: 8) {
            Text("Connect from any device on your local network:")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(urlStr)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urlStr, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let qr = generateQRCode(from: urlStr) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 110, height: 110)
                    .padding(6)
                    .background(Color.white)
                    .cornerRadius(8)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var directorStudioDetails: some View {
        let ip = TeleprompterServer.localIPAddress() ?? "localhost"
        let urlStr = "http://\(ip):\(service.directorServer.httpPort)"

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(urlStr)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urlStr, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(service.directorServer.connectedClients > 0 ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text("\(service.directorServer.connectedClients) connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let qr = generateQRCode(from: urlStr) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 110, height: 110)
                    .padding(6)
                    .background(Color.white)
                    .cornerRadius(8)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - PPTX Import & QR Generation

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
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 120, height: 120))
    }
}

// MARK: - Dedicated Page Editor Dialog

struct PageEditorDialog: View {
    let pageIndex: Int
    @Binding var text: String
    @ObservedObject var service: TeleprompterService
    @ObservedObject var dictation: DictationManager
    var onDone: () -> Void

    @State private var caretPosition: Int? = nil
    @State private var editorCaretPosition: Int = 0
    @State private var dictationHighlightRange: NSRange? = nil
    @State private var highlightClearTimer: Timer?

    @State private var segmentStart: Int = 0
    @State private var segmentLength: Int = 0
    @State private var segmentNeedsSeparator: Bool = false
    @State private var spokenSkipOffset: Int = 0
    @State private var lastRawSpokenLength: Int = 0

    private var wordsCount: Int {
        splitTextIntoWords(text).count
    }

    private var estimatedReadingTimeText: String {
        let words = wordsCount
        guard words > 0 else { return "0s" }
        let seconds = Int(Double(words) / 130.0 * 60.0)
        let mins = seconds / 60
        let remSecs = seconds % 60
        return mins > 0 ? "~\(mins)m \(remSecs)s" : "~\(remSecs)s"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 12) {
                Text("Page \(pageIndex + 1) Script")
                    .font(.headline)

                Menu {
                    Button("[PAUSE]") { insertCue("PAUSE") }
                    Button("[LOOK AT CAMERA]") { insertCue("LOOK AT CAMERA") }
                    Button("[SPEED UP]") { insertCue("SPEED UP") }
                    Button("[SLOW DOWN]") { insertCue("SLOW DOWN") }
                    Button("[SMILE]") { insertCue("SMILE") }
                    Button("[TAKE A BREATH]") { insertCue("TAKE A BREATH") }
                } label: {
                    Label("Insert Cue", systemImage: "sparkles")
                }
                .menuStyle(.borderedButton)

                Button {
                    toggleDictation()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                            .foregroundStyle(dictation.isRecording ? .red : .primary)
                        Text(dictation.isRecording ? "Listening..." : "Dictate")
                        if dictation.isRecording {
                            DictationWaveformView(levels: dictation.audioLevels)
                        }
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Done") {
                    if dictation.isRecording {
                        stopDictation()
                    }
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Highlighting Text Editor with Undo, Cut, Copy, Paste
            HighlightingTextEditor(
                text: $text,
                font: service.fontFamily.nsFont(ofSize: service.fontSize.pointSize),
                highlightRange: dictationHighlightRange,
                cueColor: service.cueColor.nsColor,
                cueAlpha: service.cueBrightness.alpha,
                caretPosition: $caretPosition,
                editorCaretPosition: $editorCaretPosition
            )
            .padding(12)
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            // Shifted statistics bar (0 word, reading time, characters)
            HStack(spacing: 20) {
                HStack(spacing: 5) {
                    Image(systemName: "text.word.spacing")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("\(wordsCount) words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 5) {
                    Image(systemName: "character")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("\(text.count) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("\(estimatedReadingTimeText) est. reading time")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 580, idealWidth: 640, minHeight: 460, idealHeight: 520)
    }

    private func insertCue(_ cue: String) {
        let caret = min(editorCaretPosition, text.count)
        let insertion = " [\(cue)] "
        text.insert(contentsOf: insertion, at: text.index(text.startIndex, offsetBy: caret))
        caretPosition = caret + insertion.count
    }

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

            let newChars = segmentLength - prevLen
            if newChars > 0 {
                let highlightStart = segmentStart + prevLen
                dictationHighlightRange = NSRange(location: highlightStart, length: newChars)
            }

            caretPosition = segmentStart + segmentLength

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
        let caret = min(editorCaretPosition, text.count)
        spokenSkipOffset = lastRawSpokenLength
        let charBefore = caret > 0 ? text[text.index(text.startIndex, offsetBy: caret - 1)] : "\n"
        segmentNeedsSeparator = !(charBefore == " " || charBefore == "\n" || caret == 0)
        segmentStart = caret
        segmentLength = 0
    }
}
