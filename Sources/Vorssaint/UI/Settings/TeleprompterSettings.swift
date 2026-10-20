// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Based on Textream by Fatih Kadir Akın (MIT License)

import AppKit
import CoreImage.CIFilterBuiltins
import Speech
import SwiftUI

// MARK: - Haptic Feedback Performer

private func triggerHaptic() {
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
}

// MARK: - Inline Info / Tooltip Badge

struct InfoTip: View {
    let text: String

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .help(text)
    }
}

// MARK: - Circular Color Pickers (Radial Menu Style)

struct TeleprompterHighlightColorPicker: View {
    @Binding var selection: TeleprompterHighlightColorPreset
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 7) {
            ForEach(TeleprompterHighlightColorPreset.allCases) { item in
                Button {
                    selection = item
                    triggerHaptic()
                } label: {
                    ZStack {
                        Circle()
                            .fill(item.color)
                            .frame(width: 16, height: 16)
                        if selection == item {
                            Circle()
                                .strokeBorder(Color.white.opacity(colorScheme == .light ? 0.9 : 0.8), lineWidth: 2)
                                .frame(width: 12, height: 12)
                            Circle()
                                .strokeBorder(item.color, lineWidth: 1.5)
                                .frame(width: 20, height: 20)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(item.label)
                .accessibilityLabel(item.label)
            }
        }
    }
}

struct TeleprompterCueColorPicker: View {
    @Binding var selection: TeleprompterCueColorPreset
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 7) {
            ForEach(TeleprompterCueColorPreset.allCases) { item in
                Button {
                    selection = item
                    triggerHaptic()
                } label: {
                    ZStack {
                        Circle()
                            .fill(item.color)
                            .frame(width: 16, height: 16)
                        if selection == item {
                            Circle()
                                .strokeBorder(Color.white.opacity(colorScheme == .light ? 0.9 : 0.8), lineWidth: 2)
                                .frame(width: 12, height: 12)
                            Circle()
                                .strokeBorder(item.color, lineWidth: 1.5)
                                .frame(width: 20, height: 20)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(item.label)
                .accessibilityLabel(item.label)
            }
        }
    }
}

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
    @AppStorage(DefaultsKey.teleprompterShortcutEnabled) private var teleprompterShortcutEnabled = true
    @AppStorage(DefaultsKey.teleprompterShortcut) private var teleprompterShortcutRaw =
        GlobalShortcut.teleprompterDefault.storageValue

    @State private var inputDevices: [AudioInputDevice] = AudioInputDevice.allInputDevices()
    @State private var editingPageIndex: Int? = nil
    @State private var editingPageText: String = ""
    @State private var originalPageText: String = ""
    @State private var pageToDelete: Int? = nil
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

                HStack {
                    Text("Global Shortcut")
                    Spacer()
                    ShortcutRecorderButton(
                        shortcut: GlobalShortcut(storageValue: teleprompterShortcutRaw) ?? .teleprompterDefault,
                        isEnabled: teleprompterEnabled && teleprompterShortcutEnabled,
                        waitingTitle: l10n.s.shortcutPressKeys,
                        invalidAction: { },
                        captureAction: { saved in
                            teleprompterShortcutRaw = saved.storageValue
                            service.syncWithPreferences()
                        }
                    )
                    .frame(width: 108)
                    .disabled(!teleprompterEnabled || !teleprompterShortcutEnabled)

                    Toggle("", isOn: $teleprompterShortcutEnabled)
                        .labelsHidden()
                        .onChange(of: teleprompterShortcutEnabled) { _, _ in
                            service.syncWithPreferences()
                        }
                        .disabled(!teleprompterEnabled)
                }
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
                .onChange(of: service.fontFamily) { _, _ in service.savePreferences() }

                Picker("Font Size", selection: $service.fontSize) {
                    ForEach(TeleprompterFontSizePreset.allCases) { size in
                        Text("\(size.label) (\(Int(size.pointSize)) pt)").tag(size)
                    }
                }
                .onChange(of: service.fontSize) { _, _ in service.savePreferences() }

                HStack {
                    Text("Highlight Color")
                    Spacer()
                    TeleprompterHighlightColorPicker(selection: $service.highlightColor)
                        .onChange(of: service.highlightColor) { _, _ in service.savePreferences() }
                }

                HStack {
                    Text("Cue Color")
                    Spacer()
                    TeleprompterCueColorPicker(selection: $service.cueColor)
                        .onChange(of: service.cueColor) { _, _ in service.savePreferences() }
                }

                Picker("Cue Brightness", selection: $service.cueBrightness) {
                    ForEach(TeleprompterCueBrightness.allCases) { bright in
                        Text(bright.label).tag(bright)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: service.cueBrightness) { _, _ in
                    triggerHaptic()
                    service.savePreferences()
                }
            } header: {
                Text("Appearance")
            }
            .disabled(!teleprompterEnabled)

            // MARK: - 4. Guidance Section
            Section {
                HStack {
                    HStack(spacing: 4) {
                        Text("Tracking Mode")
                        InfoTip(text: "Word Tracking highlights words as you speak; Classic auto-scrolls at steady pace; Voice-Activated pauses on silence.")
                    }
                    Spacer()
                    Picker("", selection: $service.guidanceMode) {
                        ForEach(GuidanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: service.guidanceMode) { _, _ in
                        triggerHaptic()
                        service.savePreferences()
                    }
                }

                if service.guidanceMode != .wordTracking {
                    HStack(spacing: 12) {
                        Text("Scroll Speed")
                            .frame(width: 110, alignment: .leading)
                        Slider(value: $service.scrollSpeed, in: 1.0...6.0, step: 0.1)
                            .onChange(of: service.scrollSpeed) { _, _ in
                                triggerHaptic()
                                service.savePreferences()
                            }
                        Text(String(format: "%.1fx", service.scrollSpeed))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                }

                Picker("Speech Language", selection: $service.speechLocale) {
                    ForEach(SpeechLocaleSupport.supportedLocales, id: \.identifier) { loc in
                        Text(Locale.current.localizedString(forIdentifier: loc.identifier) ?? loc.identifier)
                            .tag(loc.identifier)
                    }
                }
                .onChange(of: service.speechLocale) { _, _ in service.savePreferences() }

                Picker("Microphone", selection: $service.selectedMicUID) {
                    Text("System Default").tag("")
                    ForEach(inputDevices) { dev in
                        Text(dev.name).tag(dev.uid)
                    }
                }
                .onChange(of: service.selectedMicUID) { _, _ in service.savePreferences() }
            } header: {
                Text("Guidance")
            }
            .disabled(!teleprompterEnabled)

            // MARK: - 5. Reading Section
            Section {
                HStack {
                    HStack(spacing: 4) {
                        Text("Reading Position")
                        InfoTip(text: "Anchor position of the active reading line within the teleprompter window.")
                    }
                    Spacer()
                    Picker("", selection: $service.readingPosition) {
                        ForEach(TeleprompterReadingPosition.allCases) { pos in
                            Text(pos.label).tag(pos)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: service.readingPosition) { _, _ in
                        triggerHaptic()
                        service.savePreferences()
                    }
                }

                Toggle("Show paragraph dividers", isOn: $service.showParagraphDividers)
                    .onChange(of: service.showParagraphDividers) { _, _ in service.savePreferences() }

                Toggle("Show last spoken word", isOn: $service.showLastSpokenWords)
                    .onChange(of: service.showLastSpokenWords) { _, _ in service.savePreferences() }

                HStack {
                    Toggle("Keep screen awake while teleprompter is active", isOn: $service.keepScreenAwake)
                        .onChange(of: service.keepScreenAwake) { _, _ in service.savePreferences() }
                    Spacer()
                    InfoTip(text: "Prevents the display from sleeping during an active teleprompter session using an IOKit power assertion.")
                }
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
                .onChange(of: service.overlayMode) { _, _ in
                    triggerHaptic()
                    service.savePreferences()
                }

                HStack {
                    HStack(spacing: 4) {
                        Text("Display Target")
                        InfoTip(text: "Follow Mouse displays the prompter on the monitor where your cursor is; Fixed Display keeps it locked to a single screen.")
                    }
                    Spacer()
                    Picker("", selection: $service.displayTargetMode) {
                        ForEach(TeleprompterDisplayTargetMode.allCases) { tm in
                            Text(tm.label).tag(tm)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: service.displayTargetMode) { _, _ in
                        triggerHaptic()
                        service.savePreferences()
                    }
                }

                HStack(spacing: 12) {
                    Text("Window Width")
                        .frame(width: 110, alignment: .leading)
                    Slider(value: $service.windowWidth, in: 300...900, step: 10)
                        .onChange(of: service.windowWidth) { _, _ in
                            triggerHaptic()
                            service.savePreferences()
                        }
                    Text("\(Int(service.windowWidth)) px")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }

                HStack(spacing: 12) {
                    Text("Window Height")
                        .frame(width: 110, alignment: .leading)
                    Slider(value: $service.windowHeight, in: 120...600, step: 10)
                        .onChange(of: service.windowHeight) { _, _ in
                            triggerHaptic()
                            service.savePreferences()
                        }
                    Text("\(Int(service.windowHeight)) px")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }

                HStack(spacing: 12) {
                    Text("Transparency")
                        .frame(width: 110, alignment: .leading)
                    Slider(value: $service.overlayTransparency, in: 0.0...0.5, step: 0.05)
                        .onChange(of: service.overlayTransparency) { _, _ in
                            triggerHaptic()
                            service.savePreferences()
                        }
                    Text("\(Int(service.overlayTransparency * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }

                Toggle("Show elapsed time", isOn: $service.showElapsedTime)
                    .onChange(of: service.showElapsedTime) { _, _ in service.savePreferences() }

                HStack {
                    Toggle("Hide from screen sharing", isOn: $service.hideFromScreenShare)
                        .onChange(of: service.hideFromScreenShare) { _, _ in service.savePreferences() }
                    Spacer()
                    InfoTip(text: "Sets window sharing to none, ensuring your script remains completely invisible during Zoom, Teams, and Google Meet screen presentations.")
                }

                Toggle("Auto next page", isOn: $service.autoNextPage)
                    .onChange(of: service.autoNextPage) { _, _ in service.savePreferences() }
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
                .onChange(of: service.externalDisplayMode) { _, _ in
                    triggerHaptic()
                    service.savePreferences()
                }

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
                        .onChange(of: service.externalScreenID) { _, _ in service.savePreferences() }
                    }

                    if service.externalDisplayMode == .mirror {
                        HStack {
                            HStack(spacing: 4) {
                                Text("Mirror Axis")
                                InfoTip(text: "Invert text orientation for reflective beam splitter glass rigs.")
                            }
                            Spacer()
                            Picker("", selection: $service.externalMirrorAxis) {
                                ForEach(ExternalMirrorAxis.allCases) { axis in
                                    Text(axis.label).tag(axis)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 220)
                            .onChange(of: service.externalMirrorAxis) { _, _ in
                                triggerHaptic()
                                service.savePreferences()
                            }
                        }
                    }
                }
            } header: {
                Text("External Display")
            }
            .disabled(!teleprompterEnabled)

            // MARK: - 8. Remote Control Section
            Section {
                HStack {
                    Toggle("Enable Browser Remote", isOn: $service.remoteServerEnabled)
                        .onChange(of: service.remoteServerEnabled) { _, on in
                            service.savePreferences()
                            if on {
                                service.remoteServer.start()
                            } else {
                                service.remoteServer.stop()
                            }
                        }
                    Spacer()
                    InfoTip(text: "Control scroll speed, play/pause, and pagination wirelessly from any mobile or desktop browser on your local network.")
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
                HStack {
                    Toggle("Enable Director Server", isOn: $service.directorServerEnabled)
                        .onChange(of: service.directorServerEnabled) { _, on in
                            service.savePreferences()
                            if on {
                                service.directorServer.start()
                            } else {
                                service.directorServer.stop()
                            }
                        }
                    Spacer()
                    InfoTip(text: "Live studio production server for live multi-client script editing and prompting.")
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
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        confirmingReset = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                            Text("Reset Teleprompter Settings")
                        }
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .confirmationDialog(
                    "Reset Teleprompter Settings?",
                    isPresented: $confirmingReset,
                    titleVisibility: .visible
                ) {
                    Button("Reset to Defaults", role: .destructive) {
                        service.resetSettings()
                        triggerHaptic()
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
        .confirmationDialog(
            "Delete Page \((pageToDelete ?? 0) + 1)?",
            isPresented: Binding(
                get: { pageToDelete != nil },
                set: { if !$0 { pageToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Page", role: .destructive) {
                if let idx = pageToDelete {
                    deletePage(at: idx)
                    triggerHaptic()
                }
                pageToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pageToDelete = nil
            }
        } message: {
            Text("Are you sure you want to delete this page? This action cannot be undone.")
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
                triggerHaptic()
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
                    Label("Duplicate Page", systemImage: "doc.on.doc")
                }

                Divider()

                Button(role: .destructive) {
                    pageToDelete = index
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
            triggerHaptic()
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
            originalPageText = service.pages[index]

            PageEditorWindowController.shared.show(
                pageIndex: index,
                text: Binding(
                    get: { editingPageText },
                    set: { editingPageText = $0 }
                ),
                service: service,
                dictation: dictation,
                onCancel: {
                    closePageEditor(save: false)
                },
                onDone: {
                    closePageEditor(save: true)
                }
            )
        }
    }

    private func closePageEditor(save: Bool) {
        if save, let idx = editingPageIndex, idx < service.pages.count {
            service.pages[idx] = editingPageText
            service.savePreferences()
        } else if !save, let idx = editingPageIndex, idx < service.pages.count {
            if originalPageText.isEmpty && editingPageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && service.pages.count > 1 {
                service.removePage(at: idx)
            }
        }
        editingPageIndex = nil
    }

    private func addNewPage() {
        service.addPage()
        let newIdx = max(0, service.pages.count - 1)
        editingPageIndex = newIdx
        editingPageText = service.pages[newIdx]
        originalPageText = ""
        triggerHaptic()

        PageEditorWindowController.shared.show(
            pageIndex: newIdx,
            text: Binding(
                get: { editingPageText },
                set: { editingPageText = $0 }
            ),
            service: service,
            dictation: dictation,
            onCancel: {
                closePageEditor(save: false)
            },
            onDone: {
                closePageEditor(save: true)
            }
        )
    }

    private func duplicatePage(at index: Int) {
        guard index < pagesList.count else { return }
        if service.pages.isEmpty {
            service.pages = [service.text]
        }
        let copy = service.pages[index]
        service.pages.insert(copy, at: index + 1)
        service.savePreferences()
        triggerHaptic()
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
                    triggerHaptic()
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
                    triggerHaptic()
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
                triggerHaptic()
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

// MARK: - Dedicated Page Editor Window Controller (Movable & Resizable)

final class PageEditorWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PageEditorWindowController()

    private var onDoneCallback: (() -> Void)?
    private var onCancelCallback: (() -> Void)?
    private var isDismissing: Bool = false

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 540, height: 400)
        panel.maxSize = NSSize(width: 920, height: 820)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        self.init(window: panel)
        panel.delegate = self
    }

    func show(
        pageIndex: Int,
        text: Binding<String>,
        service: TeleprompterService,
        dictation: DictationManager,
        onCancel: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self.isDismissing = false
        self.onCancelCallback = onCancel
        self.onDoneCallback = onDone

        let contentView = PageEditorDialog(
            pageIndex: pageIndex,
            text: text,
            service: service,
            dictation: dictation,
            onCancel: { [weak self] in
                guard let self = self, !self.isDismissing else { return }
                self.isDismissing = true
                self.window?.orderOut(nil)
                onCancel()
            },
            onDone: { [weak self] in
                guard let self = self, !self.isDismissing else { return }
                self.isDismissing = true
                self.window?.orderOut(nil)
                onDone()
            }
        )

        window?.contentView = NSHostingView(rootView: contentView)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if !isDismissing {
            isDismissing = true
            onCancelCallback?()
        }
    }
}

// MARK: - Dedicated Page Editor Dialog (macOS Component Action Dialog)

struct PageEditorDialog: View {
    let pageIndex: Int
    @Binding var text: String
    @ObservedObject var service: TeleprompterService
    @ObservedObject var dictation: DictationManager
    var onCancel: () -> Void
    var onDone: () -> Void

    @State private var caretPosition: Int? = nil
    @State private var editorCaretPosition: Int = 0
    @State private var dictationHighlightRange: NSRange? = nil
    @State private var highlightClearTimer: Timer?
    @State private var isHoveringControls: Bool = false

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
            // MARK: - Top Header Row: Window Buttons, Centered Title, Cue & Dictate on Right
            ZStack {
                // Centered Page Title
                Text("Page \(pageIndex + 1) Script & Notes")
                    .font(.system(size: 13, weight: .semibold))

                HStack(spacing: 12) {
                    // macOS traffic lights style dots
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color(red: 1.0, green: 0.38, blue: 0.35))
                            .frame(width: 12, height: 12)
                            .overlay(
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(Color.black.opacity(0.55))
                                    .opacity(isHoveringControls ? 1 : 0)
                            )
                            .onTapGesture {
                                onCancel()
                            }
                            .help("Close & Discard")

                        Circle()
                            .fill(Color(red: 1.0, green: 0.76, blue: 0.2))
                            .frame(width: 12, height: 12)
                            .overlay(
                                Image(systemName: "minus")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(Color.black.opacity(0.55))
                                    .opacity(isHoveringControls ? 1 : 0)
                            )
                            .onTapGesture {
                                PageEditorWindowController.shared.window?.miniaturize(nil)
                            }
                            .help("Minimize")

                        Circle()
                            .fill(Color(red: 0.2, green: 0.8, blue: 0.35))
                            .frame(width: 12, height: 12)
                            .overlay(
                                Image(systemName: "plus")
                                    .font(.system(size: 6, weight: .bold))
                                    .foregroundStyle(Color.black.opacity(0.55))
                                    .opacity(isHoveringControls ? 1 : 0)
                            )
                            .onTapGesture {
                                PageEditorWindowController.shared.window?.zoom(nil)
                            }
                            .help("Zoom")
                    }
                    .onHover { isHoveringControls = $0 }

                    Spacer()

                    // Top Right: Cue Menu & Dictate Button
                    HStack(spacing: 8) {
                        Menu {
                            Button("[PAUSE]") { insertCue("PAUSE") }
                            Button("[LOOK AT CAMERA]") { insertCue("LOOK AT CAMERA") }
                            Button("[SPEED UP]") { insertCue("SPEED UP") }
                            Button("[SLOW DOWN]") { insertCue("SLOW DOWN") }
                            Button("[SMILE]") { insertCue("SMILE") }
                            Button("[TAKE A BREATH]") { insertCue("TAKE A BREATH") }
                        } label: {
                            Label("Cue", systemImage: "sparkles")
                        }
                        .menuStyle(.borderedButton)
                        .controlSize(.small)

                        Button {
                            toggleDictation()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                                    .foregroundStyle(dictation.isRecording ? .red : .primary)
                                Text(dictation.isRecording ? "Listening" : "Dictate")
                                if dictation.isRecording {
                                    DictationWaveformView(levels: dictation.audioLevels)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // MARK: - Text Area with Native Vertical Scrollbar
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

            // MARK: - Bottom Bar: Words, Characters, Reading Time on Left; Cancel & Done on Right
            HStack(spacing: 16) {
                HStack(spacing: 14) {
                    HStack(spacing: 4) {
                        Image(systemName: "text.word.spacing")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("\(wordsCount) words")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "character")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("\(text.count) characters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("\(estimatedReadingTimeText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("Cancel") {
                        if dictation.isRecording {
                            stopDictation()
                        }
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Done") {
                        if dictation.isRecording {
                            stopDictation()
                        }
                        onDone()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 540, idealWidth: 660, maxWidth: 920, minHeight: 400, idealHeight: 520, maxHeight: 820)
    }

    private func insertCue(_ cue: String) {
        let caret = min(editorCaretPosition, text.count)
        let insertion = " [\(cue)] "
        text.insert(contentsOf: insertion, at: text.index(text.startIndex, offsetBy: caret))
        caretPosition = caret + insertion.count
        triggerHaptic()
    }

    private func toggleDictation() {
        if dictation.isRecording {
            stopDictation()
        } else {
            startDictation()
        }
        triggerHaptic()
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
