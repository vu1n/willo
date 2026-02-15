#if os(iOS)
import Foundation
import Speech
import AVFoundation
import UIKit

/// Manages voice input using Apple's Speech framework for on-device transcription
@MainActor
final class VoiceInputManager: ObservableObject {

    enum VoiceInputState: Equatable {
        case idle
        case requesting      // Requesting permissions
        case ready           // Ready to record
        case recording       // PTT mode - manual stop
        case continuous      // Continuous mode - auto-stop on silence
        case transcribing    // Processing speech
        case error(String)   // Error state with message
    }

    enum RecordingMode {
        case pushToTalk      // Manual start/stop
        case continuous      // Auto-send after silence
    }

    @Published private(set) var state: VoiceInputState = .idle
    @Published private(set) var transcript: String = ""
    @Published private(set) var isAvailable: Bool = false
    @Published private(set) var recordingMode: RecordingMode = .pushToTalk

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?

    /// Silence detection for continuous mode
    private var silenceTimer: Timer?
    private var lastTranscriptUpdateTime: Date = Date()
    private let silenceThreshold: TimeInterval = 1.5  // seconds of silence before auto-send

    /// Callback when transcription is finalized
    var onTranscriptionComplete: ((String) -> Void)?

    init() {
        // Initialize with default locale
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        audioEngine = AVAudioEngine()
    }

    // MARK: - Permissions

    /// Request speech recognition and microphone permissions
    func requestPermissions() async -> Bool {
        state = .requesting

        // Request speech recognition permission
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard speechStatus == .authorized else {
            state = .error("Speech recognition not authorized")
            return false
        }

        // Request microphone permission
        let micPermission: Bool
        if #available(iOS 17.0, *) {
            micPermission = await AVAudioApplication.requestRecordPermission()
        } else {
            let audioSession = AVAudioSession.sharedInstance()
            micPermission = await withCheckedContinuation { continuation in
                audioSession.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        guard micPermission else {
            state = .error("Microphone access not granted")
            return false
        }

        // Check if recognizer is available
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            state = .error("Speech recognition unavailable")
            return false
        }

        isAvailable = true
        state = .ready
        return true
    }

    // MARK: - Recording

    /// Start recording in push-to-talk mode
    func startRecording() async throws {
        try await startRecording(mode: .pushToTalk)
    }

    /// Start recording in continuous mode (auto-sends on silence)
    func startContinuousRecording() async throws {
        try await startRecording(mode: .continuous)
    }

    /// Start recording with specified mode
    private func startRecording(mode: RecordingMode) async throws {
        // Check if we're in a valid state to start recording
        switch state {
        case .ready, .idle, .error:
            break  // Valid states, continue
        default:
            throw VoiceInputError.invalidState
        }

        // Ensure we have permissions
        if !isAvailable {
            let granted = await requestPermissions()
            guard granted else {
                throw VoiceInputError.permissionDenied
            }
        }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            state = .error("Speech recognizer unavailable")
            throw VoiceInputError.recognizerUnavailable
        }

        recordingMode = mode
        state = mode == .continuous ? .continuous : .recording
        transcript = ""
        lastTranscriptUpdateTime = Date()

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw VoiceInputError.setupFailed
        }

        // Configure for on-device recognition if available
        if #available(iOS 13.0, *) {
            recognitionRequest.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        }
        recognitionRequest.shouldReportPartialResults = true

        // Get audio input
        guard let audioEngine = audioEngine else {
            throw VoiceInputError.setupFailed
        }

        let inputNode = audioEngine.inputNode

        // Start recognition task
        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }

                if let result = result {
                    let newTranscript = result.bestTranscription.formattedString
                    if newTranscript != self.transcript {
                        self.transcript = newTranscript
                        self.lastTranscriptUpdateTime = Date()
                    }
                }

                if let error = error {
                    print("[Voice] Recognition error: \(error)")
                    self.stopRecording(error: error.localizedDescription)
                } else if result?.isFinal == true {
                    self.stopRecording(error: nil)
                }
            }
        }

        // Configure audio tap
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()

        // Start silence detection for continuous mode
        if mode == .continuous {
            startSilenceDetection()
        }

        print("[Voice] Recording started in \(mode) mode")
    }

    // MARK: - Silence Detection (VAD)

    private func startSilenceDetection() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForSilence()
            }
        }
    }

    private func checkForSilence() {
        guard state == .continuous else {
            silenceTimer?.invalidate()
            return
        }

        let timeSinceLastUpdate = Date().timeIntervalSince(lastTranscriptUpdateTime)

        // Only trigger if we have some transcript and silence threshold passed
        if !transcript.isEmpty && timeSinceLastUpdate >= silenceThreshold {
            print("[Voice] Silence detected (\(timeSinceLastUpdate)s), auto-sending")
            stopRecording(error: nil)
        }
    }

    /// Stop recording and finalize transcription
    func stopRecording(error: String? = nil) {
        guard state == .recording || state == .continuous else { return }

        let wasRecording = state
        state = .transcribing

        // Stop silence detection
        silenceTimer?.invalidate()
        silenceTimer = nil

        // Stop audio engine
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)

        // End audio request
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        // Cancel task if needed
        recognitionTask?.cancel()
        recognitionTask = nil

        // Deactivate audio session
        try? AVAudioSession.sharedInstance().setActive(false)

        if let error = error {
            state = .error(error)
        } else if !transcript.isEmpty {
            // Successful transcription
            onTranscriptionComplete?(transcript)
            state = .ready
        } else {
            state = .ready
        }

        print("[Voice] Recording stopped (\(wasRecording)), transcript: \(transcript)")
    }

    /// Cancel recording without processing
    func cancelRecording() {
        silenceTimer?.invalidate()
        silenceTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false)

        transcript = ""
        state = .ready
    }

    // MARK: - Errors

    enum VoiceInputError: LocalizedError {
        case invalidState
        case permissionDenied
        case recognizerUnavailable
        case setupFailed

        var errorDescription: String? {
            switch self {
            case .invalidState:
                return "Voice input is not in a valid state"
            case .permissionDenied:
                return "Microphone or speech recognition permission denied"
            case .recognizerUnavailable:
                return "Speech recognizer is not available"
            case .setupFailed:
                return "Failed to setup audio recording"
            }
        }
    }
}

// MARK: - SwiftUI Voice Input Button

import SwiftUI

/// A button that shows voice input status and handles recording
/// - Tap: Push-to-talk mode (manual stop)
/// - Swipe up: Continuous mode (auto-sends on silence)
struct VoiceInputButton: View {
    @ObservedObject var voiceManager: VoiceInputManager
    let onText: (String) -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var showContinuousHint = false
    @State private var pulseAnimation = false

    private let swipeThreshold: CGFloat = 40
    private let buttonSize: CGFloat = 36

    var body: some View {
        ZStack {
            // Swipe hint indicator (shows when dragging up)
            if isDragging && dragOffset < -20 {
                VStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                    Text("AUTO")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(Color.terminalCyan)
                .offset(y: -50)
                .opacity(min(1, abs(dragOffset) / swipeThreshold))
            }

            // Main button
            ZStack {
                // Pulsing ring for continuous mode
                if voiceManager.state == .continuous {
                    Circle()
                        .stroke(Color.terminalCyan.opacity(0.5), lineWidth: 2)
                        .frame(width: buttonSize + 8, height: buttonSize + 8)
                        .scaleEffect(pulseAnimation ? 1.3 : 1.0)
                        .opacity(pulseAnimation ? 0 : 0.8)
                }

                // Background circle
                Circle()
                    .fill(backgroundColor)
                    .frame(width: buttonSize, height: buttonSize)

                // Continuous mode ring
                if voiceManager.state == .continuous {
                    Circle()
                        .stroke(Color.terminalCyan, lineWidth: 2)
                        .frame(width: buttonSize, height: buttonSize)
                }

                // Icon
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .offset(y: isDragging ? dragOffset : 0)
            .scaleEffect(isDragging ? 1.1 : 1.0)
        }
        .gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in
                    // Only track upward drags when not recording
                    if voiceManager.state == .ready || voiceManager.state == .idle {
                        isDragging = true
                        dragOffset = min(0, value.translation.height)  // Only up
                    }
                }
                .onEnded { value in
                    isDragging = false
                    if dragOffset < -swipeThreshold {
                        // Swipe up detected - start continuous mode
                        Task {
                            try? await voiceManager.startContinuousRecording()
                        }
                        // Haptic feedback
                        let impact = UIImpactFeedbackGenerator(style: .medium)
                        impact.impactOccurred()
                    }
                    dragOffset = 0
                }
        )
        .simultaneousGesture(
            TapGesture()
                .onEnded {
                    handleTap()
                }
        )
        .disabled(voiceManager.state == .requesting || voiceManager.state == .transcribing)
        .onAppear {
            voiceManager.onTranscriptionComplete = { text in
                onText(text)
            }
        }
        .onChange(of: voiceManager.state) { newState in
            if newState == .continuous {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                    pulseAnimation = true
                }
            } else {
                pulseAnimation = false
            }
        }
    }

    private func handleTap() {
        switch voiceManager.state {
        case .idle, .ready, .error:
            Task {
                try? await voiceManager.startRecording()
            }
            // Haptic feedback
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
        case .recording, .continuous:
            voiceManager.stopRecording()
        default:
            break
        }
    }

    private var iconName: String {
        switch voiceManager.state {
        case .idle, .ready:
            return "mic"
        case .requesting, .transcribing:
            return "waveform"
        case .recording:
            return "stop.fill"
        case .continuous:
            return "waveform"
        case .error:
            return "mic.slash"
        }
    }

    private var iconColor: Color {
        switch voiceManager.state {
        case .idle, .ready:
            return .textSecondary
        case .recording:
            return .terminalRed
        case .continuous:
            return .terminalCyan
        case .requesting, .transcribing:
            return .terminalAmber
        case .error:
            return .terminalRed.opacity(0.7)
        }
    }

    private var backgroundColor: Color {
        switch voiceManager.state {
        case .recording:
            return Color.terminalRed.opacity(0.2)
        case .continuous:
            return Color.terminalCyan.opacity(0.15)
        case .requesting, .transcribing:
            return Color.terminalAmber.opacity(0.15)
        default:
            return Color.bezelGray
        }
    }
}

// MARK: - Voice Transcript HUD

/// Floating heads-up display for voice transcript
struct VoiceTranscriptHUD: View {
    @ObservedObject var voiceManager: VoiceInputManager
    let onCancel: () -> Void

    @State private var pulseScale: CGFloat = 1.0
    @State private var waveformPhase: CGFloat = 0

    private var isActive: Bool {
        voiceManager.state == .recording || voiceManager.state == .continuous
    }

    private var accentColor: Color {
        voiceManager.state == .continuous ? .terminalCyan : .terminalAmber
    }

    var body: some View {
        if isActive {
            HStack(spacing: 12) {
                // Pulsing recording indicator
                ZStack {
                    // Outer pulse ring
                    Circle()
                        .stroke(accentColor.opacity(0.3), lineWidth: 2)
                        .frame(width: 24, height: 24)
                        .scaleEffect(pulseScale)
                        .opacity(2 - pulseScale)

                    // Inner solid dot
                    Circle()
                        .fill(accentColor)
                        .frame(width: 10, height: 10)

                    // Waveform bars for continuous mode
                    if voiceManager.state == .continuous {
                        HStack(spacing: 2) {
                            ForEach(0..<3, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(accentColor)
                                    .frame(width: 2, height: 6 + sin(waveformPhase + Double(i) * 0.8) * 4)
                            }
                        }
                    }
                }
                .frame(width: 28, height: 28)

                // Mode label
                Text(voiceManager.state == .continuous ? "AUTO" : "PTT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                // Transcript text
                Text(voiceManager.transcript.isEmpty ? "Listening..." : voiceManager.transcript)
                    .font(.willoMono(.subheadline))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Cancel button
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.textTertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(accentColor.opacity(0.4), lineWidth: 1)
                    }
                    .shadow(color: accentColor.opacity(0.2), radius: 8, y: 2)
            }
            .padding(.horizontal, 12)
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity.combined(with: .scale(scale: 0.95))
            ))
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        // Swipe down to cancel
                        if value.translation.height > 30 {
                            onCancel()
                        }
                    }
            )
            .onAppear {
                // Start pulse animation
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulseScale = 1.5
                }
                // Start waveform animation for continuous mode
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    waveformPhase = .pi * 2
                }
            }
        }
    }
}

#Preview {
    VStack(spacing: 30) {
        VoiceInputButton(voiceManager: VoiceInputManager()) { text in
            print("Transcribed: \(text)")
        }

        VStack(spacing: 4) {
            Text("Tap: Push-to-talk")
            Text("Swipe up: Continuous mode")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("HUD") {
    ZStack {
        Color.machineBlack.ignoresSafeArea()

        VStack {
            Spacer()
            VoiceTranscriptHUD(voiceManager: VoiceInputManager()) {
                print("Cancelled")
            }
            .padding(.bottom, 60)
        }
    }
    .preferredColorScheme(.dark)
}
#endif
