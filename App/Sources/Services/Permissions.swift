import CoreBluetooth
import CoreLocation
import EventKit
import Observation
import UserNotifications

enum AppPermission: CaseIterable, Identifiable {
    case bluetooth, health, notifications, location, calendar

    var id: Self { self }

    var title: String {
        switch self {
        case .bluetooth: "Bluetooth"
        case .health: "Apple Health"
        case .notifications: "Notifications"
        case .location: "Location"
        case .calendar: "Calendar"
        }
    }

    var reason: String {
        switch self {
        case .bluetooth: "Finds and keeps the connection to your watch."
        case .health: "Saves heart rate, sleep, steps and workouts, and reads your profile."
        case .notifications: "Lets the app tell you when the watch loses its connection."
        case .location: "Sends local weather and GPS satellite data to the watch."
        case .calendar: "Shows your next events on the watch."
        }
    }

    var symbol: String {
        switch self {
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .health: "heart.fill"
        case .notifications: "bell.badge.fill"
        case .location: "location.fill"
        case .calendar: "calendar"
        }
    }
}

/// Asks iOS for each permission and remembers which ones were answered.
@MainActor
@Observable
final class PermissionCenter {
    private(set) var answered: Set<AppPermission> = []

    func request(_ permission: AppPermission) async {
        switch permission {
        case .bluetooth:
            _ = CBCentralManager()  // Creating the manager is what shows the Bluetooth prompt.
        case .health:
            _ = await HealthStore.requestAccess()
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        case .location:
            await LocationProvider.shared.requestAuthorization()
        case .calendar:
            _ = try? await EKEventStore().requestFullAccessToEvents()
        }
        answered.insert(permission)
    }
}

/// One-shot location for weather, plus the when-in-use prompt.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private var authorizationWaiter: CheckedContinuation<Void, Never>?
    private var locationWaiter: CheckedContinuation<CLLocation?, Never>?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestAuthorization() async {
        guard manager.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { continuation in
            authorizationWaiter = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    func currentLocation() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            locationWaiter = continuation
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationWaiter?.resume()
            authorizationWaiter = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in
            locationWaiter?.resume(returning: location)
            locationWaiter = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            locationWaiter?.resume(returning: nil)
            locationWaiter = nil
        }
    }
}
