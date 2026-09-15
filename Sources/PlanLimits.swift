import Foundation

/// One rolling quota window as reported by Claude Code itself.
struct QuotaWindow: Equatable {
    var usedPercentage: Double
    var resetsAt: Date?
    var windowMinutes: Int? = nil
}

struct PlanLimits: Equatable {
    var fiveHour: QuotaWindow?
    var sevenDay: QuotaWindow?
    var capturedAt: Date

    var isEmpty: Bool { fiveHour == nil && sevenDay == nil }

    /// The payload only refreshes while a session is open, so anything old is
    /// shown as such rather than passed off as current.
    var isStale: Bool { Date().timeIntervalSince(capturedAt) > 15 * 60 }
}

/// Reads the file written by claude-statusline-capture.sh.
///
/// Parsed loosely on purpose: `resets_at` has appeared as both an epoch number
/// and an ISO string across versions, individual windows are omitted rather
/// than nulled when unknown, and `used_percentage` has been seen carrying an
/// epoch value at the very start of a window.
enum StatusLineCapture {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/statusline.json")

    static func load() -> PlanLimits? {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let captured = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date.distantPast

        let limits = root["rate_limits"] as? [String: Any] ?? [:]
        let parsed = PlanLimits(
            fiveHour: window(limits["five_hour"]),
            sevenDay: window(limits["seven_day"]),
            capturedAt: captured
        )
        return parsed.isEmpty ? nil : parsed
    }

    private static func window(_ value: Any?) -> QuotaWindow? {
        guard let dict = value as? [String: Any],
              let number = dict["used_percentage"] as? NSNumber
        else { return nil }
        let percent = number.doubleValue
        guard (0...100).contains(percent) else { return nil }
        return QuotaWindow(usedPercentage: percent, resetsAt: date(dict["resets_at"]))
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let string = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        }
        return nil
    }
}
