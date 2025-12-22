import Foundation

/// Detects terminal activity patterns to determine session state
///
/// This class analyzes terminal output to detect:
/// - Shell prompts (idle state)
/// - Continuous output (running state)
/// - Error patterns (error state)
/// - New output in background sessions (unread counter)
@MainActor
final class ActivityDetector {

    // MARK: - Configuration

    /// Maximum buffer size for recent output analysis
    private let bufferSize = 500

    /// Debounce interval to prevent rapid state changes
    private let debounceInterval: TimeInterval = 0.5

    /// Time threshold to consider a session "idle" after no output
    private let idleTimeout: TimeInterval = 2.0

    // MARK: - State

    /// Circular buffer of recent output
    private var outputBuffer: [UInt8] = []

    /// Timestamp of last output received
    private var lastOutputTime: Date?

    /// Timestamp of last state change
    private var lastStateChangeTime: Date?

    /// Current detected state
    private var currentState: ActivityState = .idle

    /// Debounce timer
    private var debounceTask: Task<Void, Never>?

    /// Idle timer
    private var idleTask: Task<Void, Never>?

    // MARK: - Patterns

    /// Common shell prompt patterns (for detecting command completion)
    private let promptPatterns: [Data] = [
        "$ ".data(using: .utf8)!,      // sh, bash
        "% ".data(using: .utf8)!,      // zsh, tcsh
        "> ".data(using: .utf8)!,      // cmd, PowerShell
        "# ".data(using: .utf8)!,      // root prompt
        "❯ ".data(using: .utf8)!,      // starship, oh-my-zsh
        "➜ ".data(using: .utf8)!,      // oh-my-zsh
    ]

    /// Error patterns (for detecting failures)
    private let errorPatterns: [String] = [
        "error:",
        "Error:",
        "ERROR:",
        "failed",
        "Failed",
        "FAILED",
        "fatal:",
        "Fatal:",
        "FATAL:",
        "panic:",
        "exception:",
        "Exception:",
    ]

    /// Exit code patterns (for detecting command failures)
    private let exitCodePattern = Data([0x1B, 0x5D, 0x37, 0x3B]) // OSC 7; (exit code notification)

    // MARK: - Output Analysis

    /// Process new terminal output
    /// - Parameter data: Raw terminal data
    /// - Returns: Detected activity state, or nil if no state change
    func processOutput(_ data: Data) -> ActivityState? {
        // Update last output time
        lastOutputTime = Date()

        // Cancel any pending idle timer since we have new output
        idleTask?.cancel()

        // Append to buffer (maintain size limit)
        let bytes = [UInt8](data)
        outputBuffer.append(contentsOf: bytes)
        if outputBuffer.count > bufferSize {
            outputBuffer.removeFirst(outputBuffer.count - bufferSize)
        }

        // Analyze patterns
        let detectedState = analyzeBuffer()

        // Check if state changed and debounce is satisfied
        if detectedState != currentState {
            let now = Date()
            if let lastChange = lastStateChangeTime,
               now.timeIntervalSince(lastChange) < debounceInterval {
                // Debounce - schedule update
                scheduleStateChange(to: detectedState)
                return nil
            } else {
                // Immediate update
                currentState = detectedState
                lastStateChangeTime = now
                scheduleIdleTimer()
                return detectedState
            }
        }

        // Schedule idle timer if running
        if case .running = currentState {
            scheduleIdleTimer()
        }

        return nil
    }

    /// Analyze the buffer to detect activity patterns
    private func analyzeBuffer() -> ActivityState {
        guard !outputBuffer.isEmpty else { return .idle }

        // Check for error patterns first (highest priority)
        if containsErrorPattern() {
            return .error
        }

        // Check for shell prompt (indicates command completed)
        if endsWithPrompt() {
            return .idle
        }

        // Check for continuous output (no prompt recently)
        if isContinuousOutput() {
            return .running
        }

        // Default to running if we have output but no clear prompt
        return .running
    }

    /// Check if buffer ends with a shell prompt
    private func endsWithPrompt() -> Bool {
        guard outputBuffer.count > 2 else { return false }

        // Look for prompt patterns at the end of buffer
        for pattern in promptPatterns {
            let patternBytes = [UInt8](pattern)
            guard patternBytes.count <= outputBuffer.count else { continue }

            let endIndex = outputBuffer.count
            let startIndex = endIndex - patternBytes.count
            let suffix = Array(outputBuffer[startIndex..<endIndex])

            if suffix == patternBytes {
                return true
            }
        }

        return false
    }

    /// Check if buffer contains error patterns
    private func containsErrorPattern() -> Bool {
        // Convert buffer to string for pattern matching
        guard let text = String(bytes: outputBuffer, encoding: .utf8) else {
            return false
        }

        // Look for error keywords in recent output
        let recentText = text.suffix(200) // Only check recent output

        for pattern in errorPatterns {
            if recentText.contains(pattern) {
                return true
            }
        }

        return false
    }

    /// Check if we're receiving continuous output (no prompts)
    private func isContinuousOutput() -> Bool {
        guard let lastOutput = lastOutputTime else { return false }

        // If we received output recently and no prompt, we're likely running a command
        let timeSinceLastOutput = Date().timeIntervalSince(lastOutput)
        return timeSinceLastOutput < 1.0 && !endsWithPrompt()
    }

    // MARK: - State Management

    /// Schedule a debounced state change
    private func scheduleStateChange(to newState: ActivityState) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(0.5 * 1_000_000_000))
            guard let self = self else { return }
            self.currentState = newState
            self.lastStateChangeTime = Date()
        }
    }

    /// Schedule idle timer to transition to idle after no output
    private func scheduleIdleTimer() {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.idleTimeout * 1_000_000_000))

            // Check if we should transition to idle
            if let lastOutput = self.lastOutputTime {
                let timeSinceOutput = Date().timeIntervalSince(lastOutput)
                if timeSinceOutput >= self.idleTimeout {
                    self.currentState = .idle
                    self.lastStateChangeTime = Date()
                }
            }
        }
    }

    /// Get current detected state
    func getCurrentState() -> ActivityState {
        return currentState
    }

    /// Reset detector state
    func reset() {
        outputBuffer.removeAll()
        lastOutputTime = nil
        lastStateChangeTime = nil
        currentState = .idle
        debounceTask?.cancel()
        idleTask?.cancel()
    }
}
