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

private final class AudioTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var smoothedLevel: Float = 0
    private var onLevel: ((CGFloat) -> Void)?

    init(
        recognitionRequest: SFSpeechAudioBufferRecognitionRequest,
        onLevel: @escaping (CGFloat) -> Void
    ) {
        self.recognitionRequest = recognitionRequest
        self.onLevel = onLevel
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else {
            append(buffer)
            return
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            append(buffer)
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

        lock.lock()
        recognitionRequest?.append(buffer)
        let smoothing: Float = normalized > smoothedLevel ? 0.4 : 0.15
        smoothedLevel += (normalized - smoothedLevel) * smoothing
        let level = smoothedLevel
        let onLevel = self.onLevel
        lock.unlock()

        if let onLevel {
            DispatchQueue.main.async {
                onLevel(CGFloat(level))
            }
        }
    }

    func clear() {
        lock.lock()
        recognitionRequest = nil
        onLevel = nil
        smoothedLevel = 0
        lock.unlock()
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        recognitionRequest?.append(buffer)
        lock.unlock()
    }
}

private func makeAudioTapHandler(_ audioTapState: AudioTapState) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, _ in
        audioTapState.process(buffer)
    }
}

@MainActor
final class SpeechPipeline {

    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var audioTapState: AudioTapState?

    private var onTranscript: ((String) -> Void)?
    private var onLevel: ((CGFloat) -> Void)?

    private var latestTranscript = ""
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
        let audioTapState = AudioTapState(recognitionRequest: request, onLevel: onLevel)
        self.audioTapState = audioTapState

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                self?.handleRecognition(result: result, error: error)
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: makeAudioTapHandler(audioTapState))

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
        audioTapState?.clear()
        audioTapState = nil
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
