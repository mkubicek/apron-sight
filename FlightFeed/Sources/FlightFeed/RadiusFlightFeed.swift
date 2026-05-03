import Foundation

/// A long-running, polling subscription to a `FlightProvider` for one region.
///
/// Provides an `AsyncStream<FlightSnapshot>` callers can `for await` on. The
/// feed handles transient errors (logged via `errorHandler`), backs off on
/// `429 rate limited`, and continues polling until cancelled.
///
/// Polling cadence note: the OpenSky anonymous tier strongly suggests
/// no faster than 10s. Authenticated users can go to ~5s. This feed clamps to
/// `minPollInterval`.
public final class RadiusFlightFeed: @unchecked Sendable {

    public typealias ErrorHandler = @Sendable (any Error) -> Void

    private let provider: any FlightProvider
    private let region: RadiusRegion
    private let pollInterval: TimeInterval
    private let minPollInterval: TimeInterval
    private let errorHandler: ErrorHandler?

    public init(
        provider: any FlightProvider,
        region: RadiusRegion,
        pollInterval: TimeInterval = 10,
        minPollInterval: TimeInterval = 5,
        errorHandler: ErrorHandler? = nil
    ) {
        self.provider = provider
        self.region = region
        self.pollInterval = max(pollInterval, minPollInterval)
        self.minPollInterval = minPollInterval
        self.errorHandler = errorHandler
    }

    /// Begin polling. The returned stream terminates when the consumer stops
    /// iterating or the underlying task is cancelled.
    public func snapshots() -> AsyncStream<FlightSnapshot> {
        AsyncStream { continuation in
            let task = Task { [provider, region, pollInterval, minPollInterval, errorHandler] in
                while !Task.isCancelled {
                    let cycleStart = Date()
                    var nextDelay = pollInterval
                    do {
                        let snapshot = try await provider.snapshot(for: region)
                        continuation.yield(snapshot)
                    } catch let error as FlightFeedError {
                        errorHandler?(error)
                        if case .rateLimited(let retry) = error, let retry {
                            nextDelay = max(retry, minPollInterval)
                        }
                    } catch {
                        errorHandler?(error)
                    }

                    let elapsed = Date().timeIntervalSince(cycleStart)
                    let sleep = max(nextDelay - elapsed, minPollInterval)
                    try? await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
