// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Based on Textream by Fatih Kadir Akın (MIT License)

import AppKit
import SwiftUI

private let paragraphDividerExtraSpacing: CGFloat = 14
private let paragraphDividerDotSize: CGFloat = 3
private let paragraphDividerDotSpacing: CGFloat = 5
private let paragraphDividerDotOpacity: Double = 0.16

// MARK: - Paragraph Breaks

func paragraphBreakWordIndices(in text: String) -> Set<Int> {
    let normalized = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

    var result = Set<Int>()
    var wordCount = 0
    var hasContent = false
    var hasPendingBreak = false

    for (index, line) in lines.enumerated() {
        let lineWords = splitTextIntoWords(String(line))
        if !lineWords.isEmpty {
            if hasContent && hasPendingBreak {
                result.insert(wordCount)
            }
            wordCount += lineWords.count
            hasContent = true
            hasPendingBreak = false
        }
        if index < lines.count - 1, hasContent {
            hasPendingBreak = true
        }
    }
    return result
}

// MARK: - Word Item Model

struct WordItem: Identifiable {
    let id: Int
    let word: String
    let charOffset: Int
    let isAnnotation: Bool
}

// MARK: - Preference Key

struct WordYPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Speech Scroll View

struct SpeechScrollView: View {
    let words: [String]
    let highlightedCharCount: Int
    var font: NSFont = .systemFont(ofSize: 18, weight: .semibold)
    var highlightColor: Color = .yellow
    var cueColor: Color = .white
    var cueUnreadOpacity: Double = 0.25
    var cueReadOpacity: Double = 0.5
    var onWordTap: ((Int) -> Void)? = nil
    var smoothScroll: Bool = false
    var smoothWordProgress: Double = 0
    var isListening: Bool = true
    var paragraphBreakBeforeWordIndices: Set<Int> = []

    @State private var scrollOffset: CGFloat = 0
    @State private var wordYPositions: [Int: CGFloat] = [:]
    @State private var containerHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            WordFlowLayout(
                words: words,
                highlightedCharCount: highlightedCharCount,
                font: font,
                highlightColor: highlightColor,
                cueColor: cueColor,
                cueUnreadOpacity: cueUnreadOpacity,
                cueReadOpacity: cueReadOpacity,
                highlightWords: !smoothScroll,
                paragraphBreakBeforeWordIndices: paragraphBreakBeforeWordIndices,
                containerWidth: geo.size.width,
                viewportHeight: geo.size.height,
                scrollOffset: scrollOffset,
                onWordTap: onWordTap
            )
            .coordinateSpace(name: "WordFlowLayout")
            .onPreferenceChange(WordYPreferenceKey.self) { positions in
                wordYPositions = positions
                recalculateTracking(containerHeight: containerHeight)
            }
            .offset(y: scrollOffset)
            .animation(smoothScroll ? .linear(duration: 0.08) : .easeOut(duration: 0.35), value: scrollOffset)
            .onChange(of: geo.size.height) { _, newHeight in
                containerHeight = newHeight
                recalculateTracking(containerHeight: newHeight)
            }
            .onChange(of: highlightedCharCount) {
                if !smoothScroll {
                    recalculateTracking(containerHeight: containerHeight)
                }
            }
            .onChange(of: smoothWordProgress) {
                if smoothScroll {
                    recalculateTracking(containerHeight: containerHeight)
                }
            }
            .onAppear {
                containerHeight = geo.size.height
                recalculateTracking(containerHeight: geo.size.height)
            }
        }
        .clipped()
    }

    private func activeWordIndex() -> Int {
        var cumulative = 0
        for (i, w) in words.enumerated() {
            cumulative += w.count + 1
            if cumulative > highlightedCharCount {
                return i
            }
        }
        return max(0, words.count - 1)
    }

    private func recalculateTracking(containerHeight: CGFloat) {
        guard containerHeight > 0 else { return }
        let center = containerHeight * 0.45

        if smoothScroll {
            let wordIdx = Int(smoothWordProgress)
            let fraction = smoothWordProgress - Double(wordIdx)
            let clamped = max(0, min(wordIdx, words.count - 1))
            guard let wordY = wordYPositions[clamped] else { return }
            let nextY = wordYPositions[clamped + 1] ?? wordY
            let interp = wordY + (nextY - wordY) * CGFloat(fraction)
            scrollOffset = center - interp
        } else {
            let wordIdx = activeWordIndex()
            if let wordY = wordYPositions[wordIdx] {
                scrollOffset = center - wordY
            }
        }
    }
}

// MARK: - Word Flow Layout

struct WordFlowLayout: View {
    let words: [String]
    let highlightedCharCount: Int
    var font: NSFont
    var highlightColor: Color
    var cueColor: Color
    var cueUnreadOpacity: Double
    var cueReadOpacity: Double
    var highlightWords: Bool = true
    var paragraphBreakBeforeWordIndices: Set<Int> = []
    var containerWidth: CGFloat
    var viewportHeight: CGFloat
    var scrollOffset: CGFloat
    var onWordTap: ((Int) -> Void)?

    private let lineSpacing: CGFloat = 8

    private func buildItems() -> [WordItem] {
        var items: [WordItem] = []
        var charOffset = 0
        let annotationFlags = SpeechTextAlignment.annotationFlags(for: words)

        for (index, word) in words.enumerated() {
            let isAnnotation = annotationFlags.indices.contains(index)
                ? annotationFlags[index]
                : (word.hasPrefix("[") && word.hasSuffix("]"))
            items.append(WordItem(
                id: index,
                word: word,
                charOffset: charOffset,
                isAnnotation: isAnnotation
            ))
            charOffset += word.count + 1
        }
        return items
    }

    private func buildLines(items: [WordItem]) -> [[WordItem]] {
        guard containerWidth > 0 else { return [items] }
        var lines: [[WordItem]] = []
        var currentLine: [WordItem] = []
        var lineWidth: CGFloat = 0

        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width

        for item in items {
            let wordWidth = (item.word as NSString).size(withAttributes: [.font: font]).width
            let isParagraphBreak = paragraphBreakBeforeWordIndices.contains(item.id)

            if isParagraphBreak && !currentLine.isEmpty {
                lines.append(currentLine)
                currentLine = [item]
                lineWidth = wordWidth + spaceWidth
                continue
            }

            if lineWidth + wordWidth > containerWidth && !currentLine.isEmpty {
                lines.append(currentLine)
                currentLine = [item]
                lineWidth = wordWidth + spaceWidth
            } else {
                currentLine.append(item)
                lineWidth += wordWidth + spaceWidth
            }
        }
        if !currentLine.isEmpty {
            lines.append(currentLine)
        }
        return lines
    }

    var body: some View {
        let items = buildItems()
        let lines = buildLines(items: items)

        VStack(alignment: .leading, spacing: lineSpacing) {
            ForEach(lines.indices, id: \.self) { lineIdx in
                let line = lines[lineIdx]
                let beginsParagraph = line.first.map { paragraphBreakBeforeWordIndices.contains($0.id) } ?? false

                HStack(spacing: 0) {
                    ForEach(line) { item in
                        wordView(for: item)
                            .background(
                                GeometryReader { wordGeo in
                                    Color.clear.preference(
                                        key: WordYPreferenceKey.self,
                                        value: [item.id: wordGeo.frame(in: .named("WordFlowLayout")).midY]
                                    )
                                }
                            )
                    }
                }
                .padding(.top, beginsParagraph ? paragraphDividerExtraSpacing : 0)
            }
        }
        .frame(width: containerWidth, alignment: .leading)
    }

    @ViewBuilder
    private func wordView(for item: WordItem) -> some View {
        let charsIntoWord = highlightedCharCount - item.charOffset
        let isRead = charsIntoWord >= item.word.count
        let isReading = !isRead && charsIntoWord > 0

        Button {
            onWordTap?(item.charOffset)
        } label: {
            Text(item.word + " ")
                .font(Font(font))
                .italic(item.isAnnotation)
                .foregroundStyle(
                    item.isAnnotation
                        ? cueColor.opacity(isRead ? cueReadOpacity : cueUnreadOpacity)
                        : (isRead || isReading) ? highlightColor : Color.white.opacity(0.3)
                )
        }
        .buttonStyle(.plain)
    }
}
