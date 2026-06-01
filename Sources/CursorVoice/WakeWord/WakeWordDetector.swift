import Foundation
import Speech
import AVFoundation

/// Continuous speech recognition that fires `onDetect` when the wake phrase
/// appears in a partial transcript. Requires mic + speech recognition perms.
/// Auto-restarts every ~55s (SFSpeechRecognitionTask has a ~1min ceiling).
final class WakeWordDetector {
    var onDetect: (() -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var phrase: String = "hey cursor"
    private var phraseTokens: [String] = ["hey", "cursor"]
    private var isRunning = false
    private var restartTimer: Timer?

    func start(phrase: String) {
        let normalized = phrase.lowercased().trimmingCharacters(in: .whitespaces)
        self.phrase = normalized
        self.phraseTokens = normalized.split(separator: " ").map(String.init)
        NSLog("WakeWord: requested with phrase=\(normalized)")

        // Need both speech-recognition + microphone authorization.
        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            NSLog("WakeWord: speech auth status=\(speechStatus.rawValue)")
            guard speechStatus == .authorized else {
                NSLog("WakeWord: NOT authorized for speech recognition — bailing")
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                NSLog("WakeWord: mic granted=\(micGranted)")
                guard micGranted else { return }
                DispatchQueue.main.async { self?.spinUp() }
            }
        }
    }

    func stop() {
        isRunning = false
        restartTimer?.invalidate()
        restartTimer = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            NSLog("WakeWord: stopped")
        }
    }

    private func spinUp() {
        guard !isRunning else { return }
        let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let rec = rec else {
            NSLog("WakeWord: no recognizer for en-US")
            return
        }
        guard rec.isAvailable else {
            NSLog("WakeWord: recognizer not available; will retry in 4s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.spinUp() }
            return
        }
        // Prefer on-device but accept server if it's the only option.
        let preferOnDevice = rec.supportsOnDeviceRecognition
        recognizer = rec

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = preferOnDevice
        request = req
        NSLog("WakeWord: starting (onDevice=\(preferOnDevice))")

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Defensive: AVAudioEngine sometimes hands back a 0Hz format briefly
        // right after a permission grant. Retry if that happens.
        guard format.sampleRate > 0 else {
            NSLog("WakeWord: input format invalid (sr=\(format.sampleRate)); retry")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.spinUp() }
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("WakeWord: engine.start() failed: \(error)")
            return
        }

        var lastLogged = ""
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString.lowercased()
                if text != lastLogged && !text.isEmpty {
                    NSLog("WakeWord: heard \"\(text)\"")
                    lastLogged = text
                }
                if self.matches(text) {
                    NSLog("WakeWord: MATCH in \"\(text)\"")
                    self.onDetect?()
                    self.cycle()
                }
            }
            if let error = error {
                let nsErr = error as NSError
                // Code 1110 = "no speech detected" / 203 = "retry" — these are normal.
                if nsErr.code != 1110 && nsErr.code != 203 {
                    NSLog("WakeWord: recognition error \(nsErr.code): \(nsErr.localizedDescription)")
                }
                self.cycle()
            }
        }

        isRunning = true
        NSLog("WakeWord: live, listening for \"\(phrase)\"")
        restartTimer = Timer.scheduledTimer(withTimeInterval: 55, repeats: true) { [weak self] _ in
            self?.cycle()
        }
    }

    /// Loose match: every token of the phrase appears in order somewhere in the text.
    /// Handles "hey, cursor" vs "hey cursor" vs "hey there cursor" etc.
    private func matches(_ text: String) -> Bool {
        guard !phraseTokens.isEmpty else { return false }
        var idx = 0
        for word in text.split(whereSeparator: { !$0.isLetter }) {
            if word.lowercased() == phraseTokens[idx] {
                idx += 1
                if idx == phraseTokens.count { return true }
            }
        }
        return false
    }

    private func cycle() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.spinUp()
        }
    }
}
