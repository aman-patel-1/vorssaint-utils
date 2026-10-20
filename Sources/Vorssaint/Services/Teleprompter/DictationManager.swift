// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Based on Textream by Fatih Kadir Akın (MIT License)

import Accelerate
import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

// MARK: - Dictation Manager

final class DictationManager: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    @Published var error: String?

    /// Called on main thread with the latest recognized text for the current segment
    var onTextUpdate: ((String) -> Void)?
    /// Called on main thread when a new recognition segment begins (after silence or restart)
    var onNewSegment: (() -> Void)?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var configurationChangeObserver: Any?
    private var suppressConfigChange: Bool = false
    private var requestLock = NSLock()

    private var sessionGeneration: Int = 0

    // MARK: - Lifecycle

    func start() {
        guard !isRecording else { return }
        cleanup()
        sessionGeneration += 1
        error = nil

        // Check microphone authorization
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            error = "Microphone access denied. Enable Microphone access in System Settings → Privacy & Security."
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.requestSpeechAuthAndBegin()
                    } else {
                        self?.error = "Microphone access denied."
                    }
                }
            }
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        requestSpeechAuthAndBegin()
    }

    func stop() {
        isRecording = false
        cleanup()
    }

    private func cleanup() {
        requestLock.lock()
        defer { requestLock.unlock() }

        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationChangeObserver = nil
        }

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audioLevels = Array(repeating: 0, count: self.audioLevels.count)
        }
    }

    // MARK: - Speech Authorization & Setup

    private func requestSpeechAuthAndBegin() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                switch status {
                case .authorized:
                    self.beginSession()
                case .denied, .restricted:
                    self.error = "Speech recognition access denied. Enable Speech Recognition in System Settings."
                    self.isRecording = false
                case .notDetermined:
                    self.isRecording = false
                @unknown default:
                    self.isRecording = false
                }
            }
        }
    }

    private func beginSession() {
        let currentGen = sessionGeneration
        let localeId = UserDefaults.standard.string(forKey: DefaultsKey.teleprompterSpeechLanguage) ?? "en-US"
        let locale = Locale(identifier: localeId)

        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            error = "Speech recognizer unavailable for \(localeId)."
            return
        }

        guard recognizer.isAvailable else {
            error = "Speech recognition is temporarily unavailable."
            return
        }

        speechRecognizer = recognizer

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0 else {
            error = "Invalid audio hardware format."
            return
        }

        let captureFormat = speechCaptureFormat(for: hardwareFormat) ?? hardwareFormat
        let bufferSize = speechCaptureBufferSize(for: captureFormat)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        requestLock.lock()
        recognitionRequest = request
        requestLock.unlock()

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: captureFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.requestLock.lock()
            self.recognitionRequest?.append(buffer)
            self.requestLock.unlock()

            self.updateAudioLevels(from: buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            self.error = "Failed to start audio engine: \(error.localizedDescription)"
            cleanup()
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, taskError in
            guard let self else { return }
            guard self.sessionGeneration == currentGen else { return }

            if let result {
                let spoken = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.onTextUpdate?(spoken)
                }
            }

            if taskError != nil || result?.isFinal == true {
                // Segment completed or ended, restart if still recording
                DispatchQueue.main.async {
                    guard self.isRecording, self.sessionGeneration == currentGen else { return }
                    self.onNewSegment?()
                    self.restartRecognitionTask()
                }
            }
        }

        isRecording = true
        watchAudioConfiguration()
    }

    private func restartRecognitionTask() {
        guard isRecording, let recognizer = speechRecognizer else { return }

        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        requestLock.lock()
        recognitionRequest = request
        requestLock.unlock()

        let currentGen = sessionGeneration
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, taskError in
            guard let self else { return }
            guard self.sessionGeneration == currentGen else { return }

            if let result {
                let spoken = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.onTextUpdate?(spoken)
                }
            }

            if taskError != nil || result?.isFinal == true {
                DispatchQueue.main.async {
                    guard self.isRecording, self.sessionGeneration == currentGen else { return }
                    self.onNewSegment?()
                    self.restartRecognitionTask()
                }
            }
        }
    }

    private func updateAudioLevels(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let channelDataValue = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))

        var rms: Float = 0
        vDSP_rmsqv(channelDataValue, 1, &rms, vDSP_Length(buffer.frameLength))
        let level = CGFloat(min(1.0, max(0.0, Double(rms) * 5.0)))

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var levels = self.audioLevels
            levels.removeFirst()
            levels.append(level)
            self.audioLevels = levels
        }
    }

    private func watchAudioConfiguration() {
        if configurationChangeObserver != nil { return }
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording, !self.suppressConfigChange else { return }
            self.suppressConfigChange = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.suppressConfigChange = false
                if self.isRecording {
                    self.cleanup()
                    self.start()
                }
            }
        }
    }
}
