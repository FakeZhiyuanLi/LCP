import Foundation

enum CanvasSyncInterval: Int, CaseIterable, Identifiable, Sendable {
    case manual = 0
    case fifteenMinutes = 900
    case hourly = 3600
    case everySixHours = 21600
    case daily = 86400

    var id: Self { self }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var label: String {
        switch self {
        case .manual: "Manual only"
        case .fifteenMinutes: "Every 15 minutes"
        case .hourly: "Every hour"
        case .everySixHours: "Every 6 hours"
        case .daily: "Once a day"
        }
    }
}
