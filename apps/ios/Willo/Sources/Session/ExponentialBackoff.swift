import Foundation

/// Exponential backoff calculator for connection retries
struct ExponentialBackoff {
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    let multiplier: Double
    let jitter: Double

    init(
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 60.0,
        multiplier: Double = 2.0,
        jitter: Double = 0.1
    ) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.jitter = jitter
    }

    func delay(for attempt: Int) -> TimeInterval {
        let exponentialDelay = baseDelay * pow(multiplier, Double(attempt - 1))
        let cappedDelay = min(exponentialDelay, maxDelay)

        // Add jitter to prevent thundering herd
        let jitterRange = cappedDelay * jitter
        let randomJitter = Double.random(in: -jitterRange...jitterRange)

        return max(0, cappedDelay + randomJitter)
    }
}
