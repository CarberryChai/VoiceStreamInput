@preconcurrency import AVFoundation
import AppKit
@preconcurrency import Speech

enum SpeechPipelineError: LocalizedError {
    case speechPermissionDenied
    case microphonePermissionDenied
    case recognizerUnavailable
    case audioEngineStartFailed

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            return "未授予语音识别权限。"
        case .microphonePermissionDenied:
            return "未授予麦克风权限。"
        case .recognizerUnavailable:
            return "当前语言的语音识别器不可用。"
        case .audioEngineStartFailed:
            return "录音引擎启动失败。"
        }
    }
}

@MainActor
final class SpeechPipeline {
    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    private var onTranscript: ((String) -> Void)?
    private var onLevel: ((CGFloat) -> Void)?

    private var latestTranscript = ""
    private var smoothedLevel: Float = 0
    private var isRunning = false
    private var isStopping = false
    private var stopContinuation: CheckedContinuation<String, Never>?

    func primePermissions() async {
        _ = await requestSpeechPermissionIfNeeded()
        _ = await requestMicrophonePermissionIfNeeded()
    }

    func start(
        locale: Locale,
        onTranscript: @escaping (String) -> Void,
        onLevel: @escaping (CGFloat) -> Void
    ) async throws {
        guard await requestSpeechPermissionIfNeeded() else {
            throw SpeechPipelineError.speechPermissionDenied
        }

        guard await requestMicrophonePermissionIfNeeded() else {
            throw SpeechPipelineError.microphonePermissionDenied
        }

        resetSession()

        self.onTranscript = onTranscript
        self.onLevel = onLevel
        latestTranscript = ""
        smoothedLevel = 0
        isStopping = false

        let recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechPipelineError.recognizerUnavailable
        }

        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                self?.handleRecognition(result: result, error: error)
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handleAudioBuffer(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRunning = true
        } catch {
            resetSession()
            throw SpeechPipelineError.audioEngineStartFailed
        }
    }

    func stop() async -> String {
        guard isRunning || recognitionTask != nil else {
            return latestTranscript
        }

        isStopping = true
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()

        return await withCheckedContinuation { continuation in
            stopContinuation = continuation
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                finishIfNeeded()
            }
        }
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)

        guard let channelData = buffer.floatChannelData?[0] else {
            return
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return
        }

        var energy: Float = 0
        for index in 0..<frameCount {
            let sample = channelData[index]
            energy += sample * sample
        }

        let rms = sqrt(energy / Float(frameCount))
        let db = 20 * log10(rms + 0.000_01)
        let normalized = max(0, min(1, (db + 42) / 32))
        let smoothing: Float = normalized > smoothedLevel ? 0.4 : 0.15
        smoothedLevel += (normalized - smoothedLevel) * smoothing

        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(CGFloat(self?.smoothedLevel ?? 0))
        }
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let text = result?.bestTranscription.formattedString, !text.isEmpty {
            latestTranscript = text
            onTranscript?(text)
        }

        if error != nil, isStopping {
            finishIfNeeded()
            return
        }

        if result?.isFinal == true, isStopping {
            finishIfNeeded()
        }
    }

    private func finishIfNeeded() {
        guard let stopContinuation else {
            resetSession()
            return
        }

        let transcript = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        self.stopContinuation = nil
        stopContinuation.resume(returning: transcript)
        resetSession()
    }

    private func resetSession() {
        onLevel?(0)
        isRunning = false
        isStopping = false
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        recognizer = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine = AVAudioEngine()
    }

    private func requestSpeechPermissionIfNeeded() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}
