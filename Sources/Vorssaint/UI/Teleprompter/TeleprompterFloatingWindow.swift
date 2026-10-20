// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

final class TeleprompterPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        super.cancelOperation(sender)
    }
}

final class TeleprompterFloatingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TeleprompterFloatingWindowController()
    private var hasPlacedFloatingWindow = false

    convenience init() {
        let panel = TeleprompterPanel(
            contentRect: NSRect(x: 200, y: 300, width: 380, height: 220),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 280, height: 140)
        panel.standardWindowButton(.closeButton)?.isHidden = true

        panel.contentView = NSHostingView(rootView: TeleprompterFloatingContentView())

        self.init(window: panel)
        panel.delegate = self
    }

    func show(screen: NSScreen? = nil) {
        guard let panel = window as? NSPanel else { return }
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        if let visibleFrame = targetScreen?.visibleFrame {
            let width = min(max(panel.minSize.width, CGFloat(TeleprompterService.shared.windowWidth)), visibleFrame.width)
            let height = min(max(panel.minSize.height, CGFloat(TeleprompterService.shared.windowHeight)), visibleFrame.height)
            let priorFrame = panel.frame
            let priorCenter = NSPoint(x: priorFrame.midX, y: priorFrame.midY)
            let canRestorePosition = hasPlacedFloatingWindow && visibleFrame.contains(priorCenter)
            let x = canRestorePosition
                ? min(max(priorFrame.minX, visibleFrame.minX), visibleFrame.maxX - width)
                : visibleFrame.midX - width / 2
            let y = canRestorePosition
                ? min(max(priorFrame.minY, visibleFrame.minY), visibleFrame.maxY - height)
                : visibleFrame.midY - height / 2
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
        hasPlacedFloatingWindow = true
        panel.sharingType = TeleprompterService.shared.hideFromScreenShare ? .none : .readOnly
        panel.level = .floating
        panel.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        if TeleprompterService.shared.isRunning {
            TeleprompterService.shared.stop()
        } else {
            TeleprompterService.shared.floatingWindowVisible = false
        }
    }

    func showAtNotch(screen: NSScreen? = nil) {
        guard let panel = window as? NSPanel else { return }
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        if let frame = targetScreen?.frame {
            let width = min(max(460, CGFloat(TeleprompterService.shared.windowWidth)), frame.width)
            let height = min(max(200, CGFloat(TeleprompterService.shared.windowHeight)), frame.height)
            let x = frame.midX - width / 2
            let y = frame.maxY - height - 8
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
        panel.sharingType = TeleprompterService.shared.hideFromScreenShare ? .none : .readOnly
        panel.level = .screenSaver
        panel.orderFrontRegardless()
    }

    func updateFrame() {
        guard let panel = window as? NSPanel, panel.isVisible else { return }
        guard TeleprompterService.shared.overlayMode == .floating else { return }
        let currentFrame = panel.frame
        let center = NSPoint(x: currentFrame.midX, y: currentFrame.midY)
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
        guard let visibleFrame = targetScreen?.visibleFrame else { return }
        let w = min(max(panel.minSize.width, CGFloat(TeleprompterService.shared.windowWidth)), visibleFrame.width)
        let h = min(max(panel.minSize.height, CGFloat(TeleprompterService.shared.windowHeight)), visibleFrame.height)
        var frame = panel.frame
        let dw = w - frame.size.width
        let dh = h - frame.size.height
        frame.origin.x -= dw / 2
        frame.origin.y -= dh / 2
        frame.size = NSSize(width: w, height: h)
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - w)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - h)
        panel.setFrame(frame, display: true, animate: true)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

struct TeleprompterFloatingContentView: View {
    @ObservedObject private var service = TeleprompterService.shared
    @ObservedObject private var recognizer = TeleprompterService.shared.speechRecognizer

    private var pageCount: Int { max(1, service.pages.count) }

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .opacity(max(0.2, 1.0 - service.overlayTransparency))

            VStack(spacing: service.isRunning ? 4 : 8) {
                header

                SpeechScrollView(
                    words: service.currentWords,
                    highlightedCharCount: recognizer.recognizedCharCount,
                    font: service.fontFamily.nsFont(ofSize: service.fontSize.pointSize),
                    highlightColor: service.highlightColor.color,
                    cueColor: service.cueColor.color,
                    cueUnreadOpacity: service.cueBrightness.alpha * 0.35,
                    cueReadOpacity: service.cueBrightness.alpha,
                    onWordTap: { offset in
                        service.jumpTo(charOffset: offset)
                    },
                    smoothScroll: service.guidanceMode != .wordTracking,
                    smoothWordProgress: service.timerWordProgress,
                    isListening: service.isRunning && !service.isPaused,
                    paragraphBreakBeforeWordIndices: service.showParagraphDividers ? paragraphBreakWordIndices(in: service.currentScript) : [],
                    readingPosition: service.readingPosition,
                    showLastSpokenWords: service.showLastSpokenWords
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 2)

                footer
            }
            .padding(.horizontal, 12)
            .padding(.top, service.isRunning && !service.showElapsedTime ? 2 : 10)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .onChange(of: service.windowWidth) { _, _ in
            TeleprompterFloatingWindowController.shared.updateFrame()
        }
        .onChange(of: service.windowHeight) { _, _ in
            TeleprompterFloatingWindowController.shared.updateFrame()
        }
    }

    @ViewBuilder private var header: some View {
        if service.isRunning {
            if service.showElapsedTime {
                HStack {
                    Spacer(minLength: 0)
                    Text(service.formattedElapsedTime)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Elapsed time")
                        .accessibilityValue(service.formattedElapsedTime)
                }
                .frame(height: 16)
            } else {
                Color.clear.frame(height: 0)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(service.highlightColor.color)
                    .frame(width: 26, height: 26)
                    .background(service.highlightColor.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Teleprompter")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    Text("Ready")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
            }
            .frame(minHeight: 28)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if service.isRunning && !service.isPaused && (recognizer.isStarting || recognizer.isListening) {
                liveWaveform
            } else if !service.isRunning || service.isPaused {
                HStack(spacing: 5) {
                    Circle()
                        .fill(service.isPaused ? Color.orange : service.highlightColor.color)
                        .frame(width: 6, height: 6)
                    Text(!service.isRunning ? "Ready" : service.isPaused ? "Paused" : service.guidanceMode.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if service.isRunning && service.autoNextPage && pageCount > 1 {
                Button {
                    service.previousPage()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(service.currentPageIndex == 0)
                .help("Previous page")
                .accessibilityLabel("Previous page")

                Button {
                    service.nextPage()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(service.currentPageIndex >= pageCount - 1)
                .help("Next page")
                .accessibilityLabel("Next page")
            }

            Button {
                service.toggle()
            } label: {
                Image(systemName: !service.isRunning || service.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 30, height: 30)
                    .background(service.highlightColor.color, in: Circle())
            }
            .buttonStyle(.plain)
            .help(!service.isRunning ? "Start teleprompter" : service.isPaused ? "Resume teleprompter" : "Pause teleprompter")
            .accessibilityLabel(!service.isRunning ? "Start teleprompter" : service.isPaused ? "Resume teleprompter" : "Pause teleprompter")

            Button {
                service.closeFloatingWindow()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(Color.red.opacity(0.24), in: Circle())
            }
            .buttonStyle(.plain)
            .help(service.isRunning ? "Stop and close teleprompter" : "Close teleprompter")
            .accessibilityLabel(service.isRunning ? "Stop and close teleprompter" : "Close teleprompter")
        }
        .frame(minHeight: 30)
    }

    private var liveWaveform: some View {
        let levels = Array(recognizer.audioLevels.suffix(20))
        return HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                let level = pow(levels[index], 0.6)
                RoundedRectangle(cornerRadius: 1)
                    .fill(service.highlightColor.color.opacity(0.9))
                    .frame(width: 2, height: max(3, level * 16))
            }
        }
        .frame(height: 18)
        .accessibilityLabel("Listening")
    }

}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
