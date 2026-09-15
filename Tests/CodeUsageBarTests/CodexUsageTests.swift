import Foundation
import XCTest
@testable import CodeUsageBar

final class CodexUsageTests: XCTestCase {
    func testScannerCountsResponsesOnceAndReadsQuota() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let reset = now.addingTimeInterval(3_600).timeIntervalSince1970
        let lines = [
            """
            {"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-test"}}
            """,
            """
            {"timestamp":"\(timestamp)","type":"token_usage_record","payload":{"response_id":"resp_1","usage":{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":0,"output_tokens":25,"reasoning_output_tokens":5,"total_tokens":125}}}
            """,
            """
            {"timestamp":"\(timestamp)","type":"token_usage_record","payload":{"response_id":"resp_1","usage":{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":0,"output_tokens":25,"reasoning_output_tokens":5,"total_tokens":125}}}
            """,
            """
            {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":20,"window_minutes":300,"resets_at":\(reset)},"secondary":null,"plan_type":"plus"}}}
            """
        ]
        try lines.joined(separator: "\n").write(
            to: root.appendingPathComponent("rollout.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = try CodexUsageScanner.scan(sessionsDir: root, now: now)

        XCTAssertEqual(snapshot.today.responses, 1)
        XCTAssertEqual(snapshot.today.counts.total, 125)
        XCTAssertEqual(snapshot.today.counts.cachedInput, 60)
        XCTAssertEqual(snapshot.today.counts.reasoningOutput, 5)
        XCTAssertEqual(snapshot.today.byModel["gpt-test"]?.total, 125)
        XCTAssertEqual(snapshot.plan?.primary?.usedPercentage, 20)
        XCTAssertEqual(snapshot.plan?.primary?.windowMinutes, 300)
        XCTAssertEqual(snapshot.plan?.planType, "plus")
    }
}
