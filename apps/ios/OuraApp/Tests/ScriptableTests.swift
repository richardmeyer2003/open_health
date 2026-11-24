import XCTest
@testable import OuraApp

final class ScriptableTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_459_800)

    private func snapshot(_ summary: Summary) throws -> [String: Any] {
        let sync: [String: Any] = ["last_successful_at": NSNull(), "last_successful_source": NSNull(),
                                   "events_received": 0, "events_inserted": 0]
        let data = try ScriptableSnapshot.data(summary: summary, sync: sync, generatedAt: nil,
                                               now: now, reason: "sync", hourly: HourlyHR.Result())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
}
