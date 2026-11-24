import XCTest
import CoreFoundation
import Combine
@testable import OuraApp

final class ScriptableTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_459_800)

    private func snapshot(_ summary: Summary) throws -> [String: Any] {
        let sync: [String: Any] = ["last_successful_at": NSNull(), "last_successful_source": NSNull(),
                                   "events_received": 0, "events_inserted": 0]
        let data = try ScriptableSnapshot.data(summary: summary, sync: sync, generatedAt: nil,
                                               now: now, reason: "sync", hourly: HourlyHR.Result())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "open-oura-widget.schema", withExtension: "json"))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        try check(root, schema: schema, path: "$")
        return root
    }

    /// Validate the emitted fixtures against the committed schema without an extra dependency.
    private func check(_ value: Any, schema: [String: Any], path: String) throws {
        if let constant = schema["const"] as? NSNumber { XCTAssertEqual(value as? NSNumber, constant, path) }
        if let types = (schema["type"] as? [String]) ?? (schema["type"] as? String).map({ [$0] }) {
            let matches = types.contains { type in
                switch type {
                case "null": return value is NSNull
                case "object": return value is [String: Any]
                case "array": return value is [Any]
                case "string": return value is String
                case "boolean": return (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
                case "number": return value is NSNumber
                case "integer": return (value as? NSNumber).map { $0.doubleValue.rounded() == $0.doubleValue } ?? false
                default: return false
                }
            }
            XCTAssertTrue(matches, "\(path) has an invalid type")
        }
        if let dictionary = value as? [String: Any] {
            for key in schema["required"] as? [String] ?? [] { XCTAssertNotNil(dictionary[key], "\(path).\(key) is missing") }
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            for (key, child) in dictionary {
                if let rule = properties[key] { try check(child, schema: rule, path: path + "." + key) }
                else if let rule = schema["additionalProperties"] as? [String: Any] { try check(child, schema: rule, path: path + "." + key) }
                else { XCTAssertNotEqual(schema["additionalProperties"] as? Bool, false, path + "." + key) }
            }
        }
        if let array = value as? [Any] {
            if let max = schema["maxItems"] as? Int { XCTAssertLessThanOrEqual(array.count, max, path) }
            let tuple = schema["prefixItems"] as? [[String: Any]]
            for (index, item) in array.enumerated() {
                let rule = tuple.flatMap { index < $0.count ? $0[index] : nil } ?? (schema["items"] as? [String: Any] ?? [:])
                try check(item, schema: rule, path: path + "[\(index)]")
            }
        }
    }

    func testMissingCalculationsStayNullAndRealExportsAreNotExamples() throws {
        let root = try snapshot(Summary())
        XCTAssertEqual(root["schema_version"] as? Int, 1)
        XCTAssertEqual(root["is_example"] as? Bool, false)
        XCTAssertTrue(root["activity"] is NSNull)
        XCTAssertTrue(root["sleep"] is NSNull)
        let ring = try XCTUnwrap(root["ring"] as? [String: Any])
        XCTAssertTrue(ring["battery_percent"] is NSNull)
        let sync = try XCTUnwrap(root["sync"] as? [String: Any])
        XCTAssertEqual(sync["events_inserted"] as? Int, 0)
        XCTAssertTrue(sync["summary_generated_at"] is NSNull)
    }

    func testExportsImperialValuesAndNeverInventsSleepStages() throws {
        var summary = Summary()
        summary.activity_daily = ["2026-11-22": DailyStat(active_kcal: 353, steps: 2800, distance_m: 1609.344)]
        summary.activity_profile = ["2026-11-22": [0, 3, 2, 0]]
        var night = NightRow(ymd: "2026-11-22", skin_temp: 35)
        night.start_unix = Int64(now.timeIntervalSince1970 - 36000)
        night.end_unix = Int64(now.timeIntervalSince1970 - 6000)
        summary.nights = [night]
        let root = try snapshot(summary)
        let activity = try XCTUnwrap(root["activity"] as? [String: Any])
        XCTAssertEqual(activity["distance_mi"] as? Double, 1)
        XCTAssertEqual(activity["steps"] as? Int, 2800)
        let vitals = try XCTUnwrap(root["vitals"] as? [String: Any])
        let temperature = try XCTUnwrap(vitals["skin_temperature"] as? [String: Any])
        XCTAssertEqual(temperature["fahrenheit"] as? Double, 95)
        let sleep = try XCTUnwrap(root["sleep"] as? [String: Any])
        XCTAssertTrue(sleep["stages"] is NSNull)
        XCTAssertTrue(sleep["asleep_seconds"] is NSNull)
    }

    func testNonfiniteValuesAreNullAndFutureBucketsAreMissing() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let day = formatter.string(from: now)
        var summary = Summary()
        summary.activity_daily = [day: DailyStat(active_kcal: .nan, steps: .infinity)]
        summary.activity_profile = [day: Array(repeating: 1, count: 96)]
        let activity = try XCTUnwrap(try snapshot(summary)["activity"] as? [String: Any])
        XCTAssertTrue(activity["steps"] is NSNull)
        XCTAssertTrue(activity["active_kcal"] is NSNull)
        let movement = try XCTUnwrap(activity["movement"] as? [String: Any])
        let values = try XCTUnwrap(movement["values"] as? [Any])
        XCTAssertEqual(values.count, 96)
        XCTAssertTrue(values.last is NSNull)
    }

    func testAtomicReplacementLeavesACompleteLatestDocument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(ScriptableSnapshot.filename)
        try ScriptableIntegration.replace(Data("{\"steps\":1}".utf8), at: file)
        try ScriptableIntegration.replace(Data("{\"steps\":2800}".utf8), at: file)
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Int]
        XCTAssertEqual(result?["steps"], 2800)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [ScriptableSnapshot.filename])
    }

    @MainActor
    func testZeroEventSyncAttemptsExportAndRetainsPendingStateAfterFailure() async throws {
        let suite = "ScriptableTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "scriptable.enabled")
        let integration = ScriptableIntegration(defaults: defaults)
        let failed = expectation(description: "Missing folder is reported after a zero-event sync")
        let subscription = integration.$error.compactMap { $0 }.sink { _ in failed.fulfill() }
        defer { subscription.cancel() }
        integration.synchronized(at: now, source: "resume", report: SyncReport(serial: "test", eventsSynced: 0, inserted: 0, nextCursor: 0))
        integration.summaryReady(Summary(), generatedAt: now, syncedAt: now)
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertNil(integration.lastExportAt)
        XCTAssertEqual(defaults.double(forKey: "scriptable.pending-sync"), now.timeIntervalSince1970)
        XCTAssertEqual(defaults.dictionary(forKey: "scriptable.sync")?["last_successful_source"] as? String, "automatic")
    }
}
