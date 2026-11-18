import Foundation

/// Caps how many Garmin requests are in flight at once. Requests that wait for a slot get it in arrival order.
actor ConnectRequestLimiter {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    /// Runs `body` in a slot, waiting while `limit` requests are running.
    func run<T>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        // `release` hands its slot over, so `running` already counts this request when it resumes.
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// Runs `attempt`, and runs it again after Garmin answers HTTP 429. The wait is the Retry-After Garmin sent, else 2 s
/// doubled after each failed attempt. After `attempts` tries the last rate limit is thrown; other errors are thrown at
/// once.
func retryingWhenRateLimited<T>(attempts: Int = 6,
                                sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                                _ attempt: () async throws -> T) async throws -> T {
    for failures in 0..<attempts - 1 {
        do {
            return try await attempt()
        } catch GarminConnectError.rateLimited(let retryAfter) {
            try await sleep(.seconds(retryAfter ?? Double(2 << failures)))
        }
    }
    return try await attempt()
}
