import Foundation

/// Words and number formats for one language. Anything other than "de" is English.
struct Words {
    let de: Bool

    init(_ lang: String) {
        de = lang == "de"
    }

    static let metricNames: [String: (en: String, de: String)] = [
        "steps": ("steps", "Schritte"),
        "activeEnergy": ("active energy", "aktive Energie"),
        "sleepMinutes": ("sleep", "Schlaf"),
        "sleepDeepMinutes": ("deep sleep", "Tiefschlaf"),
        "restingHeartRate": ("resting heart rate", "Ruhepuls"),
        "hrv": ("HRV", "HRV"),
        "stress": ("stress", "Stress"),
        "bodyBattery": ("Body Battery", "Body Battery"),
        "intensityMinutes": ("intensity minutes", "Intensitätsminuten"),
        "trainingMinutes": ("training minutes", "Trainingsminuten"),
    ]

    static let units: [String: String] = [
        "activeEnergy": "kcal", "sleepMinutes": "min", "sleepDeepMinutes": "min", "intensityMinutes": "min",
        "restingHeartRate": "bpm", "hrv": "ms", "trainingMinutes": "min",
    ]

    static let months: (en: [String], de: [String]) = (
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
        ["Jan", "Feb", "März", "Apr", "Mai", "Juni", "Juli", "Aug", "Sept", "Okt", "Nov", "Dez"]
    )

    static let weekdays: (en: [String], de: [String]) = (
        ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
        ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
    )

    func pick(_ english: String, _ german: String) -> String {
        de ? german : english
    }

    func name(_ metric: String) -> String {
        guard let names = Words.metricNames[metric] else { return metric }
        return de ? names.de : names.en
    }

    func date(_ day: Int) -> String {
        let parts = CivilDay.parts(day)
        let month = de ? Words.months.de[parts.month - 1] : Words.months.en[parts.month - 1]
        return de ? "\(parts.day). \(month) \(parts.year)" : "\(parts.day) \(month) \(parts.year)"
    }

    /// `key` is year * 12 + month - 1, as the trend code counts months.
    func monthYear(_ key: Int) -> String {
        let month = de ? Words.months.de[key % 12] : Words.months.en[key % 12]
        return "\(month) \(key / 12)"
    }

    func weekday(_ index: Int) -> String {
        de ? Words.weekdays.de[index] : Words.weekdays.en[index]
    }

    func num(_ value: Double, _ digits: Int) -> String {
        let text = String(format: "%.\(digits)f", value)
        return de ? text.replacingOccurrences(of: ".", with: ",") : text
    }

    /// Whole numbers with a thousands separator: 9800 is "9,800" in English and "9.800" in German.
    func integer(_ value: Double) -> String {
        let digits = String(Int(value.rounded()).magnitude)
        var grouped = ""
        for (offset, digit) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { grouped.append(de ? "." : ",") }
            grouped.append(digit)
        }
        return String(grouped.reversed())
    }

    /// A value with its unit, such as "58 bpm" or "9,800". Signed values get a "+" when positive.
    func quantity(_ value: Double, _ metric: String, digits: Int = 0, signed: Bool = false) -> String {
        let body = digits == 0 ? integer(abs(value)) : num(abs(value), digits)
        let sign = value < 0 ? "-" : (signed ? "+" : "")
        let unit = Words.units[metric] ?? ""
        return sign + body + (unit.isEmpty ? "" : " " + unit)
    }

    func pct(_ value: Double) -> String {
        de ? "\(num(value, 0)) %" : "\(num(value, 0))%"
    }

    func p(_ value: Double) -> String {
        value < 0.001 ? "< 0.001" : num(value, 3)
    }

    /// How a lag reads after a clause: " the next day", " 2 days later", or nothing for the same day.
    func lagPhrase(_ lag: Int) -> String {
        switch (lag, de) {
        case (0, _): return ""
        case (1, false): return " the next day"
        case (1, true): return " am Folgetag"
        case (_, false): return " \(lag) days later"
        default: return " \(lag) Tage später"
        }
    }
}
