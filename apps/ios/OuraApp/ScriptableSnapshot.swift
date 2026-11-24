import Foundation

/// A bounded projection of existing calculations. Missing and nonfinite values are JSON null.
enum ScriptableSnapshot {
    static let filename = "open-oura-widget.json"

    static func data(summary s: Summary, sync: [String: Any], generatedAt: Date?,
                     now: Date = Date(), reason: String, hourly: HourlyHR.Result) throws -> Data {
        let iso = ISO8601DateFormatter()
        func timestamp(_ seconds: Int64?) -> Any {
            seconds.map { iso.string(from: Date(timeIntervalSince1970: Double($0))) } ?? NSNull() as Any
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let today = dayFormatter.string(from: now)
        let cutoff = dayFormatter.string(from: calendar.date(byAdding: .day, value: -13, to: now)!)
        let days = Set(s.days + Array(s.activity_daily.keys)).filter { $0 >= cutoff && $0 <= today }.sorted()
        let latestActivityDay = Set(Array(s.activity_daily.keys) + Array(s.activity_profile.keys))
            .filter { $0 <= today }.max()
        let latestNight = s.nights.filter { ($0.end_unix ?? Int64.max) <= Int64(now.timeIntervalSince1970) }
            .max { ($0.end_unix ?? 0) < ($1.end_unix ?? 0) }
        var unavailable: [String: String] = [:]
        func value<T>(_ optional: T?) -> Any { optional.map { $0 as Any } ?? NSNull() }
        func number(_ optional: Double?) -> Any {
            guard let optional, optional.isFinite else { return NSNull() }
            return optional
        }
        func encoded<T: Encodable>(_ object: T?, required: [String] = []) throws -> Any {
            guard let object else { return NSNull() }
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "nonfinite", negativeInfinity: "nonfinite", nan: "nonfinite")
            let result = try JSONSerialization.jsonObject(with: encoder.encode(object), options: .fragmentsAllowed)
            guard var dictionary = result as? [String: Any] else { return result }
            for key in required where dictionary[key] == nil { dictionary[key] = NSNull() }
            return dictionary
        }
        func metrics(_ n: NightRow) -> SleepMetrics? {
            guard n.stagingComplete, n.hasHypnogram else { return nil }
            return Sleep.metrics(n.analysisStages, inBedS: n.durationS)
        }
        func signal(_ raw: [[Double]]?, unit: String) -> Any {
            let samples = (raw ?? []).filter { $0.count >= 2 && $0[0].isFinite && $0[1].isFinite }
            guard !samples.isEmpty else { return NSNull() }
            let indices = samples.count <= 96 ? Array(samples.indices)
                : (0..<96).map { Int(Double($0) * Double(samples.count - 1) / 95) }
            return ["unit": unit, "samples": indices.map { i -> [Any] in
                let v = unit == "degF" ? ImperialUnits.fahrenheit(samples[i][1]) : samples[i][1]
                return [iso.string(from: Date(timeIntervalSince1970: samples[i][0])), v]
            }] as [String: Any]
        }

        var activity: Any = NSNull()
        if let day = latestActivityDay {
            let stat = s.activity_daily[day]
            let profile = s.activity_profile[day] ?? []
            let bucketMinutes = profile.isEmpty ? 0 : 1440 / Double(profile.count)
            let start = dayFormatter.date(from: day)
            let buckets: [Any] = profile.enumerated().map { i, v in
                guard let start, start.addingTimeInterval(Double(i) * bucketMinutes * 60) <= now else { return NSNull() }
                return number(v)
            }
            let active = buckets.compactMap { $0 as? Double }
            #if TORCH
            let workouts: Any = Bundle.main.url(forResource: "automatic_activity_detection_3_1_11", withExtension: "ptl") == nil
                || s.modelErrors.contains(where: { $0.contains("activity") }) ? NSNull()
                : s.workoutsOn(day).map { w -> [String: Any] in
                    ["start_local": w.start, "end_local": w.end, "duration_min": w.durationMin,
                     "label": w.label, "workout_probability": number(w.isWorkout)]
                }
            #else
            let workouts: Any = NSNull()
            unavailable["activity.workouts"] = "activity_model_not_bundled"
            #endif
            let movement: Any = profile.isEmpty ? NSNull() : [
                "start_at": start.map { iso.string(from: $0) } ?? NSNull() as Any,
                "interval_seconds": bucketMinutes * 60, "unit": "MET_above_rest", "values": buckets
            ] as [String: Any]
            activity = ["date": day, "steps": number(stat?.steps), "active_kcal": number(stat?.active_kcal),
                        "total_kcal": number(stat?.total_kcal), "distance_mi": number(stat?.distance_m.map(ImperialUnits.miles)),
                        "active_min": active.isEmpty ? NSNull() : Double(active.filter { $0 >= 3 }.count) * bucketMinutes,
                        "lightly_active_min": active.isEmpty ? NSNull() : Double(active.filter { $0 >= 1.5 && $0 < 3 }.count) * bucketMinutes,
                        "peak_met_above_rest": number(active.max()), "movement": movement, "workouts": workouts]
        } else { unavailable["activity"] = "no_activity_data" }

        func latest(_ pick: (NightRow) -> Double?, field: String) -> Any {
            guard let night = s.nights.first(where: { pick($0)?.isFinite == true }) else { return NSNull() }
            return ["date": value(s.wakeYmd(night)), field: number(pick(night))]
        }
        let hrv: Any = s.vitals.hrv.latest.map { v -> [String: Any] in
            ["date": value(VitalKind.hrv.series(in: s).last?.date), "rmssd_ms": number(v),
             "baseline_ms": number(s.vitals.hrv.baseline), "delta_percent": number(s.vitals.hrv.delta_pct)]
        } ?? NSNull() as Any
        let resting: Any = s.vitals.rhr.latest.map { v -> [String: Any] in
            ["date": value(VitalKind.heartRate.series(in: s).last?.date), "bpm": number(v),
             "baseline_bpm": number(s.vitals.rhr.baseline), "delta_percent": number(s.vitals.rhr.delta_pct)]
        } ?? NSNull() as Any
        let oxygen = latest({ $0.spo2_mean }, field: "percent")
        if oxygen is NSNull { unavailable["vitals.oxygen_saturation"] = "no_calculated_value" }
        let vitals: [String: Any] = [
            "heart_rate": s.vitals.hr?.latest.map { ["bpm": number($0), "measured_at": timestamp(s.vitals.hr?.at_unix)] } ?? NSNull() as Any,
            "nightly_hrv": hrv, "nightly_resting_heart_rate": resting,
            "skin_temperature": latest({ $0.skin_temp.map(ImperialUnits.fahrenheit) }, field: "fahrenheit"),
            "oxygen_saturation": oxygen,
            "respiratory_rate": latest({ $0.breath_rate }, field: "breaths_per_min")
        ]

        var sleep: Any = NSNull()
        if let n = latestNight {
            let m = metrics(n)
            let autonomic = m.map { _ in Sleep.autonomic(night: n, stages: n.analysisStages) }
            let stageData: Any
            if let codes = n.hypnogram, !codes.isEmpty, let start = n.start_unix, let end = n.end_unix, end > start {
                // analysisStages is the exact grid used by the existing chart and metrics.
                stageData = ["start_at": timestamp(start), "epoch_seconds": n.durationS / Double(codes.count), "codes": n.analysisStages]
            } else { stageData = NSNull(); unavailable["sleep.stages"] = "no_stage_data" }
            if m == nil {
                for key in ["asleep_seconds", "efficiency_percent", "clinical_metrics", "autonomic_by_stage"] {
                    unavailable["sleep." + key] = "no_complete_stage_data"
                }
            }
            let debt = s.sleepDebt.flatMap { $0.valid ? $0 : nil }
            var debtData = try encoded(debt)
            if var object = debtData as? [String: Any], let debt {
                object["days"] = try debt.days.map {
                    try encoded($0, required: ["total_sleep_min", "shortfall_min", "cumulative_debt_min"])
                }
                debtData = object
            }
            if debt == nil { unavailable["sleep.debt"] = "insufficient_valid_staged_nights" }
            if n.sleep_score == nil { unavailable["sleep.score"] = "no_calculated_value" }
            let score: Any = try n.sleep_score.map { score -> [String: Any] in
                ["score": number(score.score), "basis": value(score.basis),
                 "components": try score.components.map { component -> [String: Any] in
                    ["key": component.key, "score": number(component.score), "weight": number(component.weight),
                     "detail": try encoded(component.detail)]
                 }]
            } ?? NSNull() as Any
            sleep = ["date": value(s.wakeYmd(n)), "start_at": timestamp(n.start_unix), "end_at": timestamp(n.end_unix),
                     "in_bed_seconds": number(n.durationS), "asleep_seconds": number(m.map { $0.asleepMin * 60 }),
                     "efficiency_percent": number(m.flatMap { n.durationS > 0 ? $0.asleepMin * 60 / n.durationS * 100 : nil }),
                     "stages": stageData, "staging_source": value(n.staging_source),
                     "stage_percentages": ["deep": number(n.deep_pct), "light": number(n.light_pct),
                                           "rem": number(n.rem_pct), "awake": number(n.wake_pct)],
                     "staging_coverage_percent": number(n.staging_coverage_pct), "staging_complete": n.stagingComplete,
                     "signals": ["sample_limit_per_signal": 96,
                                 "heart_rate": signal(n.series_t?.hr, unit: "bpm"),
                                 "hrv": signal(n.series_t?.hrv, unit: "ms"),
                                 "skin_temperature": signal(n.series_t?.temp, unit: "degF"),
                                 "motion": signal(n.series_t?.motion, unit: "s"),
                                 "oxygen_saturation": signal(n.series_t?.spo2, unit: "%")],
                     "score": score,
                     "clinical_metrics": try encoded(m.map(DayExport.Metrics.init), required: ["rem_latency_min", "deep_first_half_pct", "rem_first_half_pct"]),
                     "autonomic_by_stage": try encoded(autonomic.flatMap { $0.any ? $0 : nil }, required: ["hrv_deep", "hrv_light", "hrv_rem", "hr_deep", "hr_light", "hr_rem"]),
                     "debt": debtData]
        } else { unavailable["sleep"] = "no_timed_sleep_data" }

        let cardiovascular: [String: Any] = [
            "vo2max_ml_kg_min": number(s.fitness?.vo2max),
            "vo2max_method": s.fitness?.vo2max == nil ? NSNull() : "demographic_estimate",
            "vascular_age_years": number(s.cardio?.vascular_age),
            "chronological_age_years": number(s.cardio?.chronological_age),
            "pulse_wave_velocity_ft_s": number(s.cardio?.pwv_ms.map(ImperialUnits.feet)),
            "segments_analyzed": value(s.cardio?.segments)
        ]
        for key in ["vascular_age_years", "pulse_wave_velocity_ft_s"] where cardiovascular[key] is NSNull {
            unavailable["cardiovascular." + key] = "no_calculated_value"
        }
        var radar: Any = NSNull()
        if let r = s.symptomRadar {
            radar = ["date": r.date, "source": s.illness?.available == true ? "on_device_model" : "baseline_comparison",
                     "available": r.available, "status": r.status, "traffic_light": r.trafficLight,
                     "score": number(r.available ? r.score : nil), "decision": r.available ? r.decision as Any : NSNull(),
                     "days_with_data": r.daysWithData, "biomarkers": r.biomarkers.map { b -> [String: Any] in
                        let temperature = b.type == "TemperatureDeviation"
                        let units = ["AverageBreath": "breaths/min", "LowestHeartRate": "bpm", "AverageHrv": "ms"]
                        return ["type": b.type, "value": number(temperature ? ImperialUnits.fahrenheitDelta(b.value) : b.value),
                                "lower": number(temperature ? ImperialUnits.fahrenheitDelta(b.lower) : b.lower),
                                "upper": number(temperature ? ImperialUnits.fahrenheitDelta(b.upper) : b.upper),
                                "unit": temperature ? "degF_difference" : (units[b.type] ?? "unknown"),
                                "indicates_symptoms": b.indicatesSymptoms, "reason": value(b.reason)]
                     }]
        }
        let profile: Any = s.profile.map { p -> [String: Any] in
            ["age_years": number(p.age), "biological_sex": value(p.sex),
             "height_in": number(p.height_m.map { ImperialUnits.inches($0 * 100) }),
             "weight_lb": number(p.weight_kg.map(ImperialUnits.pounds)), "ring_size": number(p.ring_size)]
        } ?? NSNull() as Any
        let history: [[String: Any]] = days.map { day in
            let stat = s.activity_daily[day], n = s.night(forDay: day)
            return ["date": day, "steps": number(stat?.steps), "active_kcal": number(stat?.active_kcal),
                    "total_kcal": number(stat?.total_kcal), "distance_mi": number(stat?.distance_m.map(ImperialUnits.miles)),
                    "hrv_ms": number(n?.hrv_ms), "resting_heart_rate_bpm": number(n?.rhr),
                    "skin_temperature_f": number(n?.skin_temp.map(ImperialUnits.fahrenheit)),
                    "spo2_percent": number(n?.spo2_mean), "breaths_per_min": number(n?.breath_rate),
                    "in_bed_seconds": number(n.map { $0.durationS }),
                    "asleep_seconds": number(n.flatMap(metrics).map { $0.asleepMin * 60 }),
                    "sleep_score": number(n?.sleep_score?.score)]
        }
        let hours = hourly.bars.filter { $0.unix >= now.timeIntervalSince1970 - 86400 && $0.unix <= now.timeIntervalSince1970 }
            .sorted { $0.unix < $1.unix }.suffix(24).map { bar -> [String: Any] in
                ["start_at": iso.string(from: Date(timeIntervalSince1970: bar.unix)), "p05_bpm": number(bar.low),
                 "p95_bpm": number(bar.high), "median_bpm": number(bar.median), "min_bpm": number(bar.min),
                 "max_bpm": number(bar.max), "sample_count": bar.count]
            }
        var syncInfo = sync
        syncInfo["summary_generated_at"] = generatedAt.map { iso.string(from: $0) } ?? NSNull() as Any
        #if TORCH
        let hasSleepModels = Bundle.main.url(forResource: "sleepstaging_2_6_0", withExtension: "ptl") != nil
        #else
        let hasSleepModels = false
        #endif
        var warnings = s.clock?.warnings ?? []
        if let error = hourly.error { warnings.append("Hourly heart rate: " + error) }
        let info = Bundle.main.infoDictionary ?? [:]
        let root: [String: Any] = [
            "schema_version": 1, "is_example": false, "exported_at": iso.string(from: now), "export_reason": reason,
            "timezone": TimeZone.current.identifier, "utc_offset_seconds": TimeZone.current.secondsFromGMT(for: now),
            "display_units": "imperial", "app": ["name": "Open Oura", "version": info["CFBundleShortVersionString"] ?? NSNull(),
                "build": info["CFBundleVersion"] ?? NSNull(), "analysis_version": value(s.analysis_version), "build_has_sleep_models": hasSleepModels],
            "sync": syncInfo, "ring": ["battery_percent": value(s.device?.battery_pct), "battery_voltage_v": number(s.device?.battery_v),
                "battery_recorded_label": value(s.device?.battery_recorded), "battery_recorded_time_local": value(s.device?.battery_recorded_hm),
                "battery_age_hours": number(s.device?.battery_fresh_hours), "observed_days": value(s.device?.observed_days), "nights_recorded": value(s.device?.nights)],
            "activity": activity, "vitals": vitals, "sleep": sleep, "cardiovascular": cardiovascular,
            "symptom_radar": radar, "profile": profile,
            "history": ["window_days": 14, "days": history, "hourly_heart_rate": Array(hours)],
            "availability": unavailable, "warnings": warnings, "model_errors": s.modelErrors
        ]
        return try JSONSerialization.data(withJSONObject: sanitized(root), options: [.sortedKeys])
    }

    private static func sanitized(_ item: Any) -> Any {
        if let object = item as? [String: Any] { return object.mapValues(sanitized) }
        if let array = item as? [Any] { return array.map(sanitized) }
        if let string = item as? String, string == "nonfinite" { return NSNull() }
        if let number = item as? NSNumber, !number.doubleValue.isFinite { return NSNull() }
        return item
    }
}
