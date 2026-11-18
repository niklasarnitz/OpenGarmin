import Foundation
import SwiftUI
import GarminModels

/// Blaze is the only brand colour and marks every action. Each metric owns one colour, so charts read at a glance.
enum Palette {
    static let blaze = Color(red: 1.00, green: 0.36, blue: 0.12)
    static let ember = Color(red: 0.93, green: 0.28, blue: 0.24)
    static let lichen = Color(red: 0.66, green: 0.85, blue: 0.42)
    static let glacier = Color(red: 0.50, green: 0.72, blue: 0.85)
    static let dusk = Color(red: 0.45, green: 0.38, blue: 0.93)
    static let amber = Color(red: 0.96, green: 0.76, blue: 0.30)
}

extension Color {
    /// Warm paper in light mode, graphite in dark mode.
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.086, green: 0.094, blue: 0.110, alpha: 1)
            : UIColor(red: 0.957, green: 0.949, blue: 0.933, alpha: 1)
    })

    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.065)
            : UIColor(white: 1, alpha: 0.86)
    })
}

extension Font {
    /// Big numbers: rounded and compressed so values stay tall and legible, like a watch face.
    static func figure(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded).width(.compressed)
    }

    static let screenTitle = Font.system(.largeTitle, design: .default).weight(.heavy).width(.condensed)
    static let tileTitle = Font.system(.subheadline, design: .default).weight(.semibold)
}

extension View {
    /// Content surface. Glass is reserved for controls that float above content.
    func tile() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.surface, in: .rect(cornerRadius: 28, style: .continuous))
    }
}

enum Formatting {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = total % 3600 / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    static func distance(_ meters: Double) -> String {
        String(format: "%.1f", meters / 1000)
    }

    /// Seconds per kilometre as m:ss.
    static func pace(secondsPerKilometre: Double) -> String {
        let seconds = Int(secondsPerKilometre.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func whole(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    static func lastSeen(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }

    /// "garmin_fenix_8_pro" -> "Fenix 8 Pro"
    static func deviceName(_ catalogID: String?) -> String {
        guard let catalogID else { return "Garmin watch" }
        return catalogID.replacing("garmin_", with: "").split(separator: "_").map(\.capitalized).joined(separator: " ")
    }

    static func capability(_ capability: GarminCapability) -> String {
        switch capability {
        case .sync: "Sync"
        case .deviceInitiatesSync: "Watch-initiated sync"
        case .gncs: "Notifications"
        case .findMyPhone: "Find my phone"
        case .findMyWatch: "Find my watch"
        case .connectiqHttp: "Connect IQ apps"
        case .weatherConditions: "Weather"
        case .weatherAlerts: "Weather alerts"
        case .livetrack: "Live track"
        case .workoutDownload: "Workouts"
        case .courseDownload: "Courses"
        case .gpsEphemerisDownload: "GPS satellite data"
        case .realtimeSettings: "Live settings"
        case .incidentDetection: "Incident detection"
        default: "Feature \(capability.rawValue)"
        }
    }
}

extension Sport {
    var title: String {
        switch self {
        case .running: "Run"
        case .cycling: "Ride"
        case .eBiking: "E-bike ride"
        case .swimming: "Swim"
        case .walking: "Walk"
        case .hiking: "Hike"
        case .training: "Strength"
        case .fitnessEquipment: "Cardio"
        case .hiit: "HIIT"
        case .rowing: "Row"
        case .meditation: "Meditation"
        case .alpineSkiing: "Alpine ski"
        case .multisport: "Multisport"
        default: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .running: "figure.run"
        case .cycling, .eBiking: "bicycle"
        case .swimming: "figure.pool.swim"
        case .walking: "figure.walk"
        case .hiking, .mountaineering: "figure.hiking"
        case .training, .hiit, .fitnessEquipment: "figure.strengthtraining.traditional"
        case .rowing: "figure.rower"
        case .alpineSkiing: "figure.skiing.downhill"
        case .crossCountrySkiing: "figure.skiing.crosscountry"
        case .snowboarding: "figure.snowboarding"
        case .golf: "figure.golf"
        case .meditation: "figure.mind.and.body"
        default: "figure.mixed.cardio"
        }
    }

    var tint: Color {
        switch self {
        case .running: Palette.blaze
        case .cycling, .eBiking, .swimming, .rowing: Palette.glacier
        case .walking, .hiking: Palette.lichen
        case .training, .hiit, .fitnessEquipment: Palette.dusk
        default: Palette.amber
        }
    }

    /// Runs and walks are paced in min/km; everything else is shown as speed.
    var usesPace: Bool {
        switch self {
        case .running, .walking, .hiking: true
        default: false
        }
    }
}
