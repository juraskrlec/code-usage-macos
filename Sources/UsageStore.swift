import Foundation

// MARK: - Model

struct TokenCounts: Equatable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0

    var total: Int { input + output + cacheWrite + cacheRead }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheWrite += rhs.cacheWrite
        lhs.cacheRead += rhs.cacheRead
    }
}

struct Totals: Equatable {
    var counts = TokenCounts()
    var messages = 0
    var byModel: [String: TokenCounts] = [:]

    mutating func add(model: String, _ c: TokenCounts) {
        counts += c
        messages += 1
        var existing = byModel[model] ?? TokenCounts()
        existing += c
        byModel[model] = existing
    }

    /// nil when no pricing table is configured, or no model in it matched.
    func cost(_ pricing: Pricing) -> Double? {
        guard !pricing.isEmpty else { return nil }
        var sum = 0.0
        var matched = false
        for (model, c) in byModel {
            if let v = pricing.cost(c, model: model) {
                sum += v
                matched = true
            }
        }
        return matched ? sum : nil
    }
}

struct Snapshot: Equatable {
    var today = Totals()
    var month = Totals()
    var todayCost: Double?
    var monthCost: Double?
    var sessionsToday = 0
    /// Official 5h/7d quota, when a statusLine capture is available.
    var plan: PlanLimits?
    var updated = Date()
    var error: String?
}

// MARK: - Pricing

/// Optional USD-per-million-token table, read from
/// ~/.config/claude-usage-bar/pricing.json. Without it the app shows
/// token counts only, which is the part it can measure exactly.
struct Pricing {
    struct Entry: Decodable {
        let input: Double?
        let output: Double?
        let cacheWrite: Double?
        let cacheRead: Double?
    }

    var table: [String: Entry] = [:]
    var isEmpty: Bool { table.isEmpty }

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/claude-usage-bar/pricing.json")

    static func load() -> Pricing {
        guard let data = try? Data(contentsOf: fileURL),
              let table = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return Pricing() }
        return Pricing(table: table)
    }

    /// Exact key first, then the longest key that appears inside the model id,
    /// so "sonnet" matches "claude-sonnet-5-20260514" without a release-date table.
    func entry(for model: String) -> Entry? {
        if let e = table[model] { return e }
        let lowered = model.lowercased()
        return table
            .filter { lowered.contains($0.key.lowercased()) }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    func cost(_ c: TokenCounts, model: String) -> Double? {
        guard let e = entry(for: model) else { return nil }
        let usd = Double(c.input) * (e.input ?? 0)
            + Double(c.output) * (e.output ?? 0)
            + Double(c.cacheWrite) * (e.cacheWrite ?? 0)
            + Double(c.cacheRead) * (e.cacheRead ?? 0)
        return usd / 1_000_000
    }
}

// MARK: - Scanner

enum UsageScanner {
    /// One JSON object per line; assistant records carry `message.usage`.
    private struct Record: Decodable {
        let timestamp: String?
        let requestId: String?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func date(from string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }

    static func scan(
        projectsDir: URL,
        pricing: Pricing,
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws -> Snapshot {
        let startOfDay = calendar.startOfDay(for: now)
        let startOfMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now)
        ) ?? startOfDay

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            var snap = Snapshot()
            snap.error = "No logs at \(projectsDir.path). Run Claude Code once, or set CLAUDE_CONFIG_DIR."
            return snap
        }

        var snap = Snapshot()
        var seen = Set<String>()
        var sessionsToday = Set<String>()
        let decoder = JSONDecoder()

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            // A file untouched since last month can't hold this month's records.
            if let modified = values?.contentModificationDate, modified < startOfMonth { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard line.contains("\"usage\"") else { continue }
                guard let data = line.data(using: .utf8),
                      let record = try? decoder.decode(Record.self, from: data),
                      let message = record.message,
                      let usage = message.usage,
                      let stamp = record.timestamp,
                      let date = date(from: stamp),
                      date >= startOfMonth
                else { continue }

                // The same assistant turn can appear in more than one session file
                // after a resume or a compaction, so key on message + request id.
                let dedupeKey = "\(message.id ?? "")|\(record.requestId ?? "")"
                if dedupeKey != "|", !seen.insert(dedupeKey).inserted { continue }

                let counts = TokenCounts(
                    input: usage.inputTokens ?? 0,
                    output: usage.outputTokens ?? 0,
                    cacheWrite: usage.cacheCreationInputTokens ?? 0,
                    cacheRead: usage.cacheReadInputTokens ?? 0
                )
                guard counts.total > 0 else { continue }

                let model = message.model ?? "unknown"
                snap.month.add(model: model, counts)
                if date >= startOfDay {
                    snap.today.add(model: model, counts)
                    sessionsToday.insert(url.lastPathComponent)
                }
            }
        }

        snap.sessionsToday = sessionsToday.count
        snap.todayCost = snap.today.cost(pricing)
        snap.monthCost = snap.month.cost(pricing)
        snap.updated = Date()
        return snap
    }
}

// MARK: - Store

final class UsageStore: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var isLoading = false

    let projectsDir: URL
    private let queue = DispatchQueue(label: "com.example.codeusagebar.claude", qos: .utility)

    init(projectsDir: URL = UsageStore.defaultProjectsDir) {
        self.projectsDir = projectsDir
    }

    static var defaultProjectsDir: URL {
        let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
                .appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let dir = projectsDir
        let pricing = Pricing.load()

        queue.async { [weak self] in
            var result: Snapshot
            do {
                result = try UsageScanner.scan(projectsDir: dir, pricing: pricing)
            } catch {
                result = Snapshot()
                result.error = error.localizedDescription
            }
            result.plan = StatusLineCapture.load()
            let final = result
            DispatchQueue.main.async {
                self?.snapshot = final
                self?.isLoading = false
            }
        }
    }
}

// MARK: - Formatting

enum Fmt {
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...:
            return String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...:
            return String(format: "%.0fk", Double(n) / 1_000)
        case 1_000...:
            return String(format: "%.1fk", Double(n) / 1_000)
        default:
            return "\(n)"
        }
    }

    static func money(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }

    static func percent(_ v: Double) -> String {
        String(format: "%.0f%%", v)
    }

    static func countdown(to date: Date) -> String? {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return nil }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "resets in \(hours)h \(minutes)m" : "resets in \(minutes)m"
    }

    static func shortModel(_ id: String) -> String {
        let lowered = id.lowercased()
        for name in ["opus", "sonnet", "haiku", "fable", "mythos"] where lowered.contains(name) {
            return name.capitalized
        }
        return id
    }
}
