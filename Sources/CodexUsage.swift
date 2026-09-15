import Foundation

// MARK: - Model

struct CodexTokenCounts: Equatable {
    var input = 0
    var output = 0
    var cachedInput = 0
    var reasoningOutput = 0

    // Cached input and reasoning output are subsets of input and output.
    var total: Int { input + output }

    static func += (lhs: inout CodexTokenCounts, rhs: CodexTokenCounts) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cachedInput += rhs.cachedInput
        lhs.reasoningOutput += rhs.reasoningOutput
    }
}

struct CodexTotals: Equatable {
    var counts = CodexTokenCounts()
    var responses = 0
    var byModel: [String: CodexTokenCounts] = [:]

    mutating func add(model: String, _ newCounts: CodexTokenCounts) {
        counts += newCounts
        responses += 1
        var existing = byModel[model] ?? CodexTokenCounts()
        existing += newCounts
        byModel[model] = existing
    }
}

struct CodexPlanLimits: Equatable {
    var primary: QuotaWindow?
    var secondary: QuotaWindow?
    var capturedAt: Date
    var planType: String?

    var isEmpty: Bool { primary == nil && secondary == nil }
    var isStale: Bool { Date().timeIntervalSince(capturedAt) > 15 * 60 }
}

struct CodexSnapshot: Equatable {
    var today = CodexTotals()
    var month = CodexTotals()
    var sessionsToday = 0
    var plan: CodexPlanLimits?
    var updated = Date()
    var error: String?
}

// MARK: - Local session scanner

enum CodexUsageScanner {
    private struct Record: Decodable {
        let timestamp: String?
        let type: String?
        let payload: Payload?

        struct Payload: Decodable {
            let type: String?
            let model: String?
            let responseId: String?
            let usage: Usage?
            let rateLimits: RateLimits?

            enum CodingKeys: String, CodingKey {
                case type, model, usage
                case responseId = "response_id"
                case rateLimits = "rate_limits"
            }
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let cachedInputTokens: Int?
            let cacheWriteInputTokens: Int?
            let outputTokens: Int?
            let reasoningOutputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cachedInputTokens = "cached_input_tokens"
                case cacheWriteInputTokens = "cache_write_input_tokens"
                case outputTokens = "output_tokens"
                case reasoningOutputTokens = "reasoning_output_tokens"
            }
        }

        struct RateLimits: Decodable {
            let primary: Window?
            let secondary: Window?
            let planType: String?

            enum CodingKeys: String, CodingKey {
                case primary, secondary
                case planType = "plan_type"
            }

            struct Window: Decodable {
                let usedPercent: Double?
                let resetsAt: Double?
                let windowMinutes: Int?

                enum CodingKeys: String, CodingKey {
                    case usedPercent = "used_percent"
                    case resetsAt = "resets_at"
                    case windowMinutes = "window_minutes"
                }
            }
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func date(from string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }

    static func scan(
        sessionsDir: URL,
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws -> CodexSnapshot {
        let startOfDay = calendar.startOfDay(for: now)
        let startOfMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now)
        ) ?? startOfDay

        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            var snapshot = CodexSnapshot()
            snapshot.error = "No Codex logs at \(sessionsDir.path). Install and run Codex, or set CODEX_HOME."
            return snapshot
        }

        var snapshot = CodexSnapshot()
        var seenResponses = Set<String>()
        var sessionsToday = Set<String>()
        var latestPlan: CodexPlanLimits?
        let decoder = JSONDecoder()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            if let modified = values?.contentModificationDate, modified < startOfMonth { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

            var currentModel = "unknown"
            for (lineNumber, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
                guard line.contains("token_usage_record")
                        || line.contains("token_count")
                        || line.contains("turn_context")
                else { continue }
                guard let data = line.data(using: .utf8),
                      let record = try? decoder.decode(Record.self, from: data)
                else { continue }

                if record.type == "turn_context", let model = record.payload?.model {
                    currentModel = model
                    continue
                }

                guard let timestamp = record.timestamp,
                      let recordDate = date(from: timestamp)
                else { continue }

                if record.payload?.type == "token_count",
                   let limits = record.payload?.rateLimits,
                   latestPlan == nil || recordDate > latestPlan!.capturedAt {
                    let parsed = CodexPlanLimits(
                        primary: quotaWindow(limits.primary),
                        secondary: quotaWindow(limits.secondary),
                        capturedAt: recordDate,
                        planType: limits.planType
                    )
                    if !parsed.isEmpty { latestPlan = parsed }
                }

                guard record.type == "token_usage_record",
                      recordDate >= startOfMonth,
                      let usage = record.payload?.usage
                else { continue }

                let responseKey = record.payload?.responseId
                    ?? "\(url.path)|\(lineNumber)"
                guard seenResponses.insert(responseKey).inserted else { continue }

                let counts = CodexTokenCounts(
                    input: usage.inputTokens ?? 0,
                    output: usage.outputTokens ?? 0,
                    cachedInput: usage.cachedInputTokens ?? 0,
                    reasoningOutput: usage.reasoningOutputTokens ?? 0
                )
                guard counts.total > 0 else { continue }

                snapshot.month.add(model: currentModel, counts)
                if recordDate >= startOfDay {
                    snapshot.today.add(model: currentModel, counts)
                    sessionsToday.insert(url.lastPathComponent)
                }
            }
        }

        snapshot.sessionsToday = sessionsToday.count
        snapshot.plan = latestPlan
        snapshot.updated = Date()
        return snapshot
    }

    private static func quotaWindow(_ source: Record.RateLimits.Window?) -> QuotaWindow? {
        guard let percent = source?.usedPercent, (0...100).contains(percent) else { return nil }
        return QuotaWindow(
            usedPercentage: percent,
            resetsAt: source?.resetsAt.map(Date.init(timeIntervalSince1970:)),
            windowMinutes: source?.windowMinutes
        )
    }
}

// MARK: - Official Codex quota client

enum CodexAppServerClient {
    private struct Envelope: Decodable {
        let id: Int?
        let result: ResultPayload?
        let error: RPCError?
    }

    private struct RPCError: Decodable {
        let message: String
    }

    private struct ResultPayload: Decodable {
        let rateLimits: RateLimits?
    }

    private struct RateLimits: Decodable {
        let primary: Window?
        let secondary: Window?
        let planType: String?

        struct Window: Decodable {
            let usedPercent: Double?
            let resetsAt: Double?
            let windowDurationMins: Int?
        }
    }

    enum ClientError: LocalizedError {
        case executableMissing
        case timeout
        case server(String)

        var errorDescription: String? {
            switch self {
            case .executableMissing: return "Codex CLI was not found."
            case .timeout: return "Codex usage request timed out."
            case .server(let message): return message
            }
        }
    }

    static func fetchRateLimits(timeout: TimeInterval = 8) throws -> CodexPlanLimits {
        guard let executable = executableURL() else { throw ClientError.executableMissing }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var buffer = Data()
        var plan: CodexPlanLimits?
        var serverError: String?
        var finished = false

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            lock.lock()
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line),
                      envelope.id == 1
                else { continue }

                if let limits = envelope.result?.rateLimits {
                    let parsed = CodexPlanLimits(
                        primary: quotaWindow(limits.primary),
                        secondary: quotaWindow(limits.secondary),
                        capturedAt: Date(),
                        planType: limits.planType
                    )
                    if !parsed.isEmpty { plan = parsed }
                }
                serverError = envelope.error?.message
                if !finished {
                    finished = true
                    semaphore.signal()
                }
            }
            lock.unlock()
        }

        try process.run()
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        let messages: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "code_usage_bar",
                        "title": "Code Usage Bar",
                        "version": "1.1.0"
                    ]
                ]
            ],
            ["method": "initialized", "params": [:]],
            [
                "method": "account/rateLimits/read",
                "id": 1,
                "params": ["excludeResetCreditDetails": true]
            ]
        ]

        for message in messages {
            let data = try JSONSerialization.data(withJSONObject: message)
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.write(Data([0x0A]))
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw ClientError.timeout
        }

        lock.lock()
        defer { lock.unlock() }
        if let plan { return plan }
        throw ClientError.server(serverError ?? "Codex did not return plan limits.")
    }

    private static func quotaWindow(_ source: RateLimits.Window?) -> QuotaWindow? {
        guard let percent = source?.usedPercent, (0...100).contains(percent) else { return nil }
        return QuotaWindow(
            usedPercentage: percent,
            resetsAt: source?.resetsAt.map(Date.init(timeIntervalSince1970:)),
            windowMinutes: source?.windowDurationMins
        )
    }

    private static func executableURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [String] = []

        if let configured = environment["CODEX_EXECUTABLE"], !configured.isEmpty {
            candidates.append((configured as NSString).expandingTildeInPath)
        }
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            candidates.append(
                URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
                    .appendingPathComponent("packages/standalone/current/bin/codex").path
            )
        }
        candidates += [
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".codex/packages/standalone/current/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]

        return candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }).map(URL.init(fileURLWithPath:))
    }
}

// MARK: - Store

final class CodexUsageStore: ObservableObject {
    @Published private(set) var snapshot = CodexSnapshot()
    @Published private(set) var isLoading = false

    let sessionsDir: URL
    private let queue = DispatchQueue(label: "com.example.codeusagebar.codex", qos: .utility)

    init(sessionsDir: URL = CodexUsageStore.defaultSessionsDir) {
        self.sessionsDir = sessionsDir
    }

    static var defaultSessionsDir: URL {
        let environment = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let root: URL
        if let environment, !environment.isEmpty {
            root = URL(fileURLWithPath: (environment as NSString).expandingTildeInPath)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        }
        return root.appendingPathComponent("sessions")
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let directory = sessionsDir

        queue.async { [weak self] in
            var result: CodexSnapshot
            do {
                result = try CodexUsageScanner.scan(sessionsDir: directory)
            } catch {
                result = CodexSnapshot()
                result.error = error.localizedDescription
            }

            // The app-server value is account-wide and current. A session-log
            // value remains as a useful fallback when Codex is closed or old.
            if let official = try? CodexAppServerClient.fetchRateLimits() {
                result.plan = official
            }

            result.updated = Date()
            DispatchQueue.main.async {
                self?.snapshot = result
                self?.isLoading = false
            }
        }
    }
}
