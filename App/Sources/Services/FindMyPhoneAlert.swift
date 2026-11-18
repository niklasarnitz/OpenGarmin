import AVFoundation
import Observation
import UIKit
import UserNotifications

/// Rings the phone while the watch runs Find my phone. A loud beep loops through the `.playback` session, so it is
/// heard with the ring switch on silent and while the app is in the background (the `audio` background mode). In the
/// foreground the app also shows a full-screen alert and vibrates; in the background a time-sensitive notification
/// opens it. Ringing stops when the watch cancels, when the user taps Stop, or after the time the watch asked for.
@MainActor
@Observable
final class FindMyPhoneAlert {
    private(set) var isRinging = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var hapticTask: Task<Void, Never>?

    private static let notificationID = "com.niklasarnitz.opengarmin.find-my-phone"
    /// How long the phone rings when the watch gives no duration.
    private static let defaultSeconds = 60

    func update(started: Bool, seconds: Int) {
        started ? start(seconds: seconds) : stop()
    }

    func stop() {
        guard isRinging else { return }
        isRinging = false
        stopTask?.cancel()
        hapticTask?.cancel()
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    private func start(seconds: Int) {
        stop()
        isRinging = true
        playSound()
        postNotification()
        hapticTask = Task {
            let haptics = UINotificationFeedbackGenerator()
            while !Task.isCancelled {
                haptics.notificationOccurred(.warning)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let duration = seconds > 0 ? seconds : Self.defaultSeconds
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func playSound() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback)
            try session.setActive(true)
        } catch {
            // Another app's audio may refuse to be interrupted from the background; mixing in still rings.
            try? session.setCategory(.playback, options: .mixWithOthers)
            try? session.setActive(true)
        }
        player = try? AVAudioPlayer(data: Self.beepWAV)
        player?.numberOfLoops = -1
        player?.volume = 1
        player?.play()
    }

    private func postNotification() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your watch is looking for your phone")
        content.body = String(localized: "Open OpenGarmin to stop the sound.")
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    /// One second of sound as a 16-bit mono WAV: three short high beeps, then silence, so the loop is easy to locate.
    private static let beepWAV: Data = {
        let rate = 44_100
        var samples = [Int16](repeating: 0, count: rate)
        for beep in 0..<3 {
            let start = beep * rate / 6
            let length = rate / 10
            let frequency = beep == 1 ? 2_637.0 : 2_093.0
            for i in 0..<length {
                // A short fade in and out keeps the beep from clicking.
                let envelope = min(1, Double(min(i, length - i)) / 200)
                let value = sin(2 * .pi * frequency * Double(i) / Double(rate)) * envelope
                samples[start + i] = Int16(value * Double(Int16.max) * 0.9)
            }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        for sample in samples { append(sample) }
        return data
    }()
}
