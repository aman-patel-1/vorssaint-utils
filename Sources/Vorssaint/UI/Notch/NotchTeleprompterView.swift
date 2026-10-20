// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

struct NotchTeleprompterView: View {
    @ObservedObject private var service = TeleprompterService.shared
    @ObservedObject private var recognizer = TeleprompterService.shared.speechRecognizer
    @ObservedObject private var l10n = L10n.shared
    var size: CGSize

    @State private var showingPageCards: Bool = false
    @State private var dragStartHeight: Double = -1

    private var pagesList: [String] {
        if service.pages.isEmpty {
            return [service.text]
        }
        return service.pages
    }

    private var totalWords: Int {
        pagesList.reduce(0) { $0 + splitTextIntoWords($1).count }
    }

    private var totalEstimatedReadingTimeText: String {
        let words = totalWords
        guard words > 0 else { return "0s" }
        let seconds = Int(Double(words) / 130.0 * 60.0)
        let mins = seconds / 60
        let remSecs = seconds % 60
        return mins > 0 ? "~\(mins)m \(remSecs)s" : "~\(remSecs)s"
    }

    var body: some View {
        VStack(spacing: 0) {
            if service.isRunning && !showingPageCards {
                activePrompterView
            } else {
                pageCardsStudioView
            }

            // Vertical Resize Handle
            VStack(spacing: 0) {
                Spacer().frame(height: 2)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 36, height: 4)
                Spacer().frame(height: 4)
            }
            .frame(height: 10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartHeight < 0 {
                            dragStartHeight = Double(service.windowHeight)
                        }
                        let newHeight = dragStartHeight + Double(value.translation.height)
                        service.windowHeight = max(180, min(650, newHeight))
                    }
                    .onEnded { _ in
                        dragStartHeight = -1
                        service.savePreferences()
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    // MARK: - 1. Page Cards Studio View (When stopped or toggled)

    private var pageCardsStudioView: some View {
        VStack(spacing: 8) {
            // Header Bar
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: AppFeature.teleprompter.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(service.highlightColor.color)

                    Text("Script Studio")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)

                    Text("\(pagesList.count) \(pagesList.count == 1 ? "page" : "pages")")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }

                Spacer()

                // Timer & Word Summary on Right Side
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text(totalEstimatedReadingTimeText)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.white.opacity(0.75))

                    HStack(spacing: 4) {
                        Image(systemName: "text.word.spacing")
                            .font(.system(size: 10))
                        Text("\(totalWords)w")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.6))

                    // If currently running in background, allow jumping back to live view
                    if service.isRunning {
                        Button {
                            showingPageCards = false
                        } label: {
                            HStack(spacing: 4) {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                                Text("Live")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.2))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    // Add Page Button
                    Button {
                        addNewPage()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                            Text("Page")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.14))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Add New Page")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 2)

            // Scrollable List of Pages (Calendar / Agenda Card Style)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 8) {
                    ForEach(pagesList.indices, id: \.self) { idx in
                        pageCard(index: idx, content: pagesList[idx])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func pageCard(index: Int, content: String) -> some View {
        let isSelected = index == service.currentPageIndex
        let words = splitTextIntoWords(content).count
        let seconds = Int(Double(words) / 130.0 * 60.0)
        let mins = seconds / 60
        let remSecs = seconds % 60
        let timeStr = mins > 0 ? "~\(mins)m \(remSecs)s" : "~\(remSecs)s"
        let snippet = previewSnippet(content)

        return HStack(spacing: 12) {
            // Click card body to select page
            Button {
                service.jumpToPage(index: index)
                triggerHaptic()
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(isSelected ? service.highlightColor.color : Color.white.opacity(0.25))
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Page \(index + 1)")
                                .font(.system(size: 13, weight: isSelected ? .bold : .semibold))
                                .foregroundStyle(isSelected ? .white : .white.opacity(0.85))

                            Text("\(words) words • \(timeStr)")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.55))
                        }

                        Text(snippet.isEmpty ? "Empty page" : snippet)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            // Action Buttons: Edit and Play/Start
            HStack(spacing: 7) {
                // Edit button (opens PageEditorDialog)
                Button {
                    openEditor(for: index)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Edit Page \(index + 1)")

                // Start / Play button
                Button {
                    service.jumpToPage(index: index)
                    if !service.isRunning {
                        service.start()
                    } else if service.isPaused {
                        service.resume()
                    }
                    showingPageCards = false
                    triggerHaptic()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 26, height: 26)
                        .background(service.highlightColor.color)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Start Prompter from Page \(index + 1)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? service.highlightColor.color.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            openEditor(for: index)
        }
    }

    // MARK: - 2. Active Prompter View (While speaking/scrolling)

    private var activePrompterView: some View {
        VStack(spacing: 8) {
            // Header: controls & status
            HStack(spacing: 12) {
                // Play / Pause Toggle
                Button {
                    service.toggle()
                    triggerHaptic()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: service.isRunning && !service.isPaused ? "pause.fill" : "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(service.isRunning && !service.isPaused ? "Pause" : "Resume")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                // Stop Button
                Button {
                    service.stop()
                    showingPageCards = true
                    triggerHaptic()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 24, height: 24)
                        .background(Color.red.opacity(0.25))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Stop Teleprompter")

                // Live Audio Waveform
                if service.isRunning && !service.isPaused {
                    HStack(spacing: 2) {
                        ForEach(0..<min(20, recognizer.audioLevels.count), id: \.self) { idx in
                            let lvl = recognizer.audioLevels[idx]
                            let normalized = pow(lvl, 0.6)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(service.highlightColor.color.opacity(0.85))
                                .frame(width: 2, height: max(3.5, normalized * 18))
                        }
                    }
                    .frame(height: 18)
                }

                Spacer()

                // Stopwatch Elapsed Time on Right Side
                if service.showElapsedTime && service.isRunning {
                    HStack(spacing: 4) {
                        Image(systemName: "stopwatch")
                            .font(.system(size: 9))
                        Text(service.formattedElapsedTime)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }

                // Page indicator
                if pagesList.count > 1 {
                    Text("\(service.currentPageIndex + 1)/\(pagesList.count)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }

                // Pages List Button (switch to cards studio view)
                Button {
                    showingPageCards = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("View Script Pages")

                // Edit Script Button
                Button {
                    openEditor(for: service.currentPageIndex)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Edit Page in Full Studio")
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            // Prompter Script Display with Live Real-time Appearance Updates
            ZStack {
                SpeechScrollView(
                    words: service.currentWords,
                    highlightedCharCount: recognizer.recognizedCharCount,
                    font: service.fontFamily.nsFont(ofSize: service.fontSize.pointSize),
                    highlightColor: service.highlightColor.color,
                    cueColor: service.cueColor.color,
                    cueUnreadOpacity: service.cueBrightness.alpha * 0.35,
                    cueReadOpacity: service.cueBrightness.alpha,
                    onWordTap: { charOffset in
                        service.jumpTo(charOffset: charOffset)
                    },
                    smoothScroll: service.guidanceMode != .wordTracking,
                    smoothWordProgress: service.timerWordProgress,
                    isListening: service.isRunning && !service.isPaused,
                    paragraphBreakBeforeWordIndices: service.showParagraphDividers ? paragraphBreakWordIndices(in: service.currentScript) : [],
                    readingPosition: service.readingPosition,
                    showLastSpokenWords: service.showLastSpokenWords
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
                if pagesList.count > 1 {
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
                    .disabled(service.currentPageIndex >= pagesList.count - 1)
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
                    Text(String(format: "%.1fx speed", service.scrollSpeed))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Helpers

    private func previewSnippet(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count > 80 {
            return clean.prefix(80) + "..."
        }
        return clean
    }

    private func openEditor(for index: Int) {
        if service.pages.isEmpty {
            service.pages = [service.text]
        }
        guard index < service.pages.count else { return }
        let currentText = service.pages[index]

        PageEditorWindowController.shared.show(
            pageIndex: index,
            initialText: currentText,
            service: service,
            dictation: service.dictationManager,
            onCancel: { },
            onDone: { newText in
                if service.pages.isEmpty {
                    service.text = newText
                    service.pages = [newText]
                } else if index < service.pages.count {
                    service.pages[index] = newText
                    if index == service.currentPageIndex {
                        service.text = newText
                    }
                }
                service.savePreferences()
            }
        )
    }

    private func addNewPage() {
        if service.pages.isEmpty {
            service.pages = [service.text]
        }
        let newPageIndex = service.pages.count
        service.pages.append("")
        service.currentPageIndex = newPageIndex
        service.savePreferences()
        openEditor(for: newPageIndex)
    }

    private func triggerHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }
}
