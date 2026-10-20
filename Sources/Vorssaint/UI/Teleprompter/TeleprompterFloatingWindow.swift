// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

final class TeleprompterPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        if TeleprompterService.shared.overlayMode == .fullscreen {
            TeleprompterService.shared.overlayMode = .floating
            TeleprompterService.shared.savePreferences()
            TeleprompterFloatingWindowController.shared.show()
        } else {
            super.cancelOperation(sender)
        }
    }
}

final class TeleprompterFloatingWindowController: NSWindowController {
    static let shared = TeleprompterFloatingWindowController()

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

        panel.contentView = NSHostingView(rootView: TeleprompterFloatingContentView())

        self.init(window: panel)
    }

    func show(screen: NSScreen? = nil) {
        guard let panel = window as? NSPanel else { return }
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        let w = CGFloat(TeleprompterService.shared.windowWidth)
        let h = CGFloat(TeleprompterService.shared.windowHeight)
        if let frame = targetScreen?.visibleFrame {
            let currentX = panel.frame.origin.x
            let currentY = panel.frame.origin.y
            let x = currentX > 0 ? currentX : frame.midX - w / 2
            let y = currentY > 0 ? currentY : frame.midY - h / 2
            panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        }
        panel.level = .floating
        panel.orderFrontRegardless()
    }

    func showFullscreen(screen: NSScreen? = nil) {
        guard let panel = window as? NSPanel else { return }
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        if let frame = targetScreen?.frame {
            panel.setFrame(frame, display: true)
        }
        panel.level = .screenSaver
        panel.orderFrontRegardless()
    }

    func showAtNotch(screen: NSScreen? = nil) {
        guard let panel = window as? NSPanel else { return }
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        if let frame = targetScreen?.frame {
            let width: CGFloat = max(460, CGFloat(TeleprompterService.shared.windowWidth))
            let height: CGFloat = max(200, CGFloat(TeleprompterService.shared.windowHeight))
            let x = frame.midX - width / 2
            let y = frame.maxY - height - 8
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
        panel.level = .screenSaver
        panel.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }
}

struct TeleprompterFloatingContentView: View {
    @ObservedObject private var service = TeleprompterService.shared
    @ObservedObject private var recognizer = TeleprompterService.shared.speechRecognizer

    var body: some View {
        ZStack {
            // Frosted glass background
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .cornerRadius(18)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )

            VStack(spacing: 8) {
                // Top control bar
                HStack(spacing: 8) {
                    Button {
                        service.toggle()
                    } label: {
                        Image(systemName: service.isRunning && !service.isPaused ? "pause.fill" : "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.18))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Text(service.guidanceMode.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))

                    Spacer()

                    // Mini live waveform
                    if service.isRunning && !service.isPaused {
                        HStack(spacing: 1.5) {
                            ForEach(recognizer.audioLevels.suffix(20).indices, id: \.self) { idx in
                                let lvl = recognizer.audioLevels[idx]
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(service.highlightColor.color)
                                    .frame(width: 2, height: max(2, lvl * 14))
                            }
                        }
                        .frame(height: 14)
                    }

                    Button {
                        service.stop()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)

                // Live speech scroll content
                SpeechScrollView(
                    words: service.currentWords,
                    highlightedCharCount: recognizer.recognizedCharCount,
                    font: service.fontFamily.nsFont(ofSize: service.fontSize.pointSize),
                    highlightColor: service.highlightColor.color,
                    onWordTap: { offset in
                        service.jumpTo(charOffset: offset)
                    },
                    smoothScroll: service.guidanceMode != .wordTracking,
                    smoothWordProgress: service.timerWordProgress,
                    isListening: service.isRunning && !service.isPaused,
                    paragraphBreakBeforeWordIndices: paragraphBreakWordIndices(in: service.currentScript)
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
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
