import Foundation
import GarminModels
import GarminProtocol
import GarminTransport

// Realtime streams (heart rate, SpO2, stress, body battery, steps, calories, HRV, respiration, accelerometer). A stream
// runs while the app wants its metric: the session opens the metric's realtime service, starts it, and forwards each
// reading as `.live`. Only `stopLive` tells the watch to stop, so a stream that is replaced cannot stop its successor.

/// One realtime stream of a session: the task that reads it, and the channel that starts and stops it.
@MainActor
final class LiveStream {
    var task: Task<Void, Never>?
    var channel: (any GarminServiceChannel)?
}

extension GFDISession {
    /// Makes the watch stream exactly `metrics`: starts the new ones and stops the rest.
    func setLive(_ metrics: Set<LiveMetric>) {
        for metric in Array(liveStreams.keys) where !metrics.contains(metric) {
            stopLive(metric)
        }
        for metric in metrics where liveStreams[metric] == nil {
            startLive(metric)
        }
    }

    func stopAllLive() {
        for metric in Array(liveStreams.keys) {
            stopLive(metric)
        }
    }

    private func stopLive(_ metric: LiveMetric) {
        guard let stream = liveStreams.removeValue(forKey: metric) else { return }
        stream.task?.cancel()
        if let channel = stream.channel {
            Task { try? await channel.send(RealtimeReadings.stopPayload) }
        }
    }

    private func startLive(_ metric: LiveMetric) {
        // Realtime services need a link that can open them. Other links carry no live streams.
        guard let realtime = link as? GarminRealtimeLink else { return }
        let stream = LiveStream()
        liveStreams[metric] = stream
        stream.task = Task { [weak self] in
            defer {
                if self?.liveStreams[metric] === stream { self?.liveStreams[metric] = nil }
            }
            do {
                let channel = try await realtime.openRealtimeService(metric.serviceCode)
                stream.channel = channel
                // A stop that came while the service was opening leaves nothing to start.
                guard !Task.isCancelled else { return }
                try await channel.send(RealtimeReadings.startPayload)
                for await payload in channel.incoming {
                    if let reading = RealtimeReadings.parse(metric, payload) {
                        self?.output(.live(reading))
                    }
                }
            } catch {
                self?.output(.event(.log("Live \(metric.rawValue) stopped: \(error)")))
            }
        }
    }
}
