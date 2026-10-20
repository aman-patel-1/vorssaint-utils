// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Based on Textream by Fatih Kadir Akın (MIT License)

import AppKit
import SwiftUI

struct HighlightingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 16, weight: .regular)
    var highlightRange: NSRange? = nil
    @Binding var caretPosition: Int?
    @Binding var editorCaretPosition: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = font
        textView.delegate = context.coordinator
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        context.coordinator.textView = textView

        textView.string = text
        context.coordinator.applyHighlighting(textView)
        updateWritingDirection(textView, text: text)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
            context.coordinator.applyHighlighting(textView)
        }
        updateWritingDirection(textView, text: text)

        if let range = highlightRange, range.location + range.length <= textView.string.count {
            context.coordinator.applyBumpHighlight(textView, range: range)
        }

        if let pos = caretPosition, pos <= textView.string.count {
            let caretRange = NSRange(location: pos, length: 0)
            textView.setSelectedRange(caretRange)
            textView.scrollRangeToVisible(caretRange)
            DispatchQueue.main.async {
                self.caretPosition = nil
            }
        }
    }

    private func updateWritingDirection(_ textView: NSTextView, text: String) {
        switch textBaseDirection(in: text) {
        case .rightToLeft:
            textView.baseWritingDirection = .rightToLeft
        case .leftToRight:
            textView.baseWritingDirection = .leftToRight
        case .natural:
            textView.baseWritingDirection = .natural
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightingTextEditor
        weak var textView: NSTextView?

        private static let annotationPattern = try? NSRegularExpression(
            pattern: "\\[[^\\]]+\\]",
            options: []
        )

        init(_ parent: HighlightingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.updateWritingDirection(textView, text: textView.string)
            applyHighlighting(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let pos = textView.selectedRange().location
            if parent.editorCaretPosition != pos {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.editorCaretPosition = pos
                }
            }
        }

        private var bumpTimer: Timer?

        func applyBumpHighlight(_ textView: NSTextView, range: NSRange) {
            guard let textStorage = textView.textStorage else { return }
            guard range.length > 0, range.location + range.length <= textStorage.length else { return }

            let bumpColor = NSColor.controlAccentColor.withAlphaComponent(0.15)
            textStorage.beginEditing()
            textStorage.addAttribute(.backgroundColor, value: bumpColor, range: range)
            textStorage.endEditing()

            bumpTimer?.invalidate()
            bumpTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                self.applyHighlighting(textView)
            }
        }

        func applyHighlighting(_ textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: textStorage.length)
            let text = textStorage.string
            let selectedRanges = textView.selectedRanges

            textStorage.beginEditing()
            let defaultAttributes: [NSAttributedString.Key: Any] = [
                .font: parent.font,
                .foregroundColor: NSColor.labelColor
            ]
            textStorage.setAttributes(defaultAttributes, range: fullRange)

            if let pattern = Self.annotationPattern {
                let matches = pattern.matches(in: text, options: [], range: fullRange)
                for match in matches {
                    let annotationAttributes: [NSAttributedString.Key: Any] = [
                        .font: NSFontManager.shared.convert(parent.font, toHaveTrait: .italicFontMask),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.08)
                    ]
                    textStorage.addAttributes(annotationAttributes, range: match.range)
                }
            }

            textStorage.endEditing()
            textView.selectedRanges = selectedRanges
        }
    }
}
