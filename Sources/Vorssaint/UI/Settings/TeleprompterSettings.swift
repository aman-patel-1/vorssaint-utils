// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreImage.CIFilterBuiltins
import Speech
import SwiftUI

struct TeleprompterSettings: View {
    @ObservedObject private var service = TeleprompterService.shared
    @ObservedObject private var l10n = L10n.shared

    @State private var inputDevices: [AudioInputDevice] = AudioInputDevice.allInputDevices()
    @State private var importErrorMessage: String?
    @State private var showingImportError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Guidance Mode Card
                SettingsCard(title: "Guidance Mode") {
                    Picker("Mode", selection: $service.guidanceMode) {
                        ForEach(GuidanceMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: service.guidanceMode) { _ in
                        service.savePreferences()
                    }

                    Text(service.guidanceMode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if service.guidanceMode != .wordTracking {
                        Divider()
                        HStack {
                            Text("Scroll Speed")
                            Spacer()
                            Text(String(format: locale: .current, "%.1f words/sec", service.scrollSpeed))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $service.scrollSpeed, in: 0.5...8.0, step: 0.5) {
                            Text("Speed")
                        }
                        .onChange(of: service.scrollSpeed) { _ in
                            service.savePreferences()
                        }
                    }
                }

                // Overlay & Display Card
                SettingsCard(title: "Display & Overlay") {
                    Picker("Placement", selection: $service.overlayMode) {
                        ForEach(TeleprompterOverlayMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: service.overlayMode) { _ in
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
                        .onChange(of: service.fontFamily) { _ in
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
                        .onChange(of: service.fontSize) { _ in
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

                // Speech & Microphone Card
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
                        .onChange(of: service.selectedMicUID) { _ in
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
                        .onChange(of: service.speechLocale) { _ in
                            service.savePreferences()
                        }
                    }
                }

                // Presentation & Notes Import Card
                SettingsCard(title: "Import Script") {
                    Text("Import slides and presenter notes directly from a PowerPoint (.pptx) file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Import PowerPoint (.pptx)...") {
                        chooseAndImportPPTX()
                    }
                    .buttonStyle(.bordered)
                }

                // Remote Connection Card
                SettingsCard(title: "Remote Prompter (Phone / Tablet / Browser)") {
                    Toggle("Enable Local Network Remote", isOn: $service.remoteServerEnabled)
                        .onChange(of: service.remoteServerEnabled) { enabled in
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
                            Text("Open in any browser on the same Wi-Fi network:")
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
                                    .frame(width: 140, height: 140)
                                    .padding(8)
                                    .background(Color.white)
                                    .cornerRadius(12)
                            }
                        }
                        .padding(.top, 4)
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
