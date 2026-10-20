// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

struct NotchTeleprompterView: View {
    @ObservedObject private var service = TeleprompterService.shared
    @ObservedObject private var recognizer = TeleprompterService.shared.speechRecognizer
    @ObservedObject private var l10n = L10n.shared
    var size: CGSize

    @State private var showingEditor = false
    @State private var editingText = ""
    @State private var dummyCaret: Int? = nil
    @State private var dummyEditorCaret: Int = 0

    var body: some View {
        VStack(spacing: 8) {
            // Header: controls & status
            HStack(spacing: 12) {
                // Play / Pause Toggle
                Button {
                    service.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: service.isRunning && !service.isPaused ? "pause.fill" : "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(service.isRunning && !service.isPaused ? "Pause" : "Start")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                // Mode Indicator
                HStack(spacing: 4) {
                    Image(systemName: service.guidanceMode.icon)
                        .font(.system(size: 11))
                    Text(service.guidanceMode.label)
                        .font(.system(size: 11, weight: .regular))
                }
                .foregroundStyle(.white.opacity(0.7))

                Spacer()

                // Live Audio Waveform
                if service.isRunning && !service.isPaused {
                    HStack(spacing: 1.5) {
                        ForEach(recognizer.audioLevels.indices, id: \.self) { idx in
                            let lvl = recognizer.audioLevels[idx]
                            RoundedRectangle(cornerRadius: 1)
                                .fill(service.highlightColor.color.opacity(0.8))
                                .frame(width: 2, height: max(3, lvl * 18))
                        }
                    }
                    .frame(height: 18)
                }

                // Page indicator (if multiple pages)
                if !service.pages.isEmpty {
                    Text("\(service.currentPageIndex + 1)/\(service.pages.count)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }

                // Edit Script Button
                Button {
                    editingText = service.text
                    showingEditor = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Edit Teleprompter Script")
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            // Prompter Script Display
            ZStack {
                SpeechScrollView(
                    words: service.currentWords,
                    highlightedCharCount: recognizer.recognizedCharCount,
                    font: service.fontFamily.nsFont(ofSize: service.fontSize.pointSize),
                    highlightColor: service.highlightColor.color,
                    onWordTap: { charOffset in
                        service.jumpTo(charOffset: charOffset)
                    },
                    smoothScroll: service.guidanceMode != .wordTracking,
                    isListening: service.isRunning && !service.isPaused,
                    paragraphBreakBeforeWordIndices: paragraphBreakWordIndices(in: service.currentScript)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)

                // Soft fade mask at top and bottom edges
                VStack {
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 16)
                    .allowsHitTesting(false)

                    Spacer()

                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 16)
                    .allowsHitTesting(false)
                }
            }
            .frame(height: max(100, size.height - 75))

            // Footer bar
            HStack(spacing: 12) {
                if !service.pages.isEmpty {
                    Button {
                        service.previousPage()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .disabled(service.currentPageIndex == 0)

                    Button {
                        service.nextPage()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .disabled(service.currentPageIndex >= service.pages.count - 1)
                }

                Text("\(service.totalWordCount) words")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))

                Spacer()

                if let err = recognizer.error {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.red.opacity(0.9))
                        .lineLimit(1)
                }

                // Speed indicator if auto-scroll
                if service.guidanceMode != .wordTracking {
                    Text(String(format: "%.1f w/s", service.scrollSpeed))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .sheet(isPresented: $showingEditor) {
            VStack(spacing: 12) {
                HStack {
                    Text("Edit Script")
                        .font(.headline)
                    Spacer()
                    Button("Done") {
                        service.text = editingText
                        service.savePreferences()
                        showingEditor = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                .padding(.top)

                HighlightingTextEditor(
                    text: $editingText,
                    font: .systemFont(ofSize: 15),
                    caretPosition: $dummyCaret,
                    editorCaretPosition: $dummyEditorCaret
                )
                .padding(8)
                .background(Color(NSColor.textBackgroundColor).opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .frame(width: 480, height: 320)
        }
    }
}
