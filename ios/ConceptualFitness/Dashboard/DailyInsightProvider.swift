import Foundation
import FoundationModels

struct DailyInsightProvider {
    func cachedDailyBriefForCurrentSlot(now: Date = Date()) -> String? {
        cachedLastText(for: BriefSlot(date: now), kind: .dailyBrief, now: now)
    }

    func dailyBrief(for bundle: DashboardBundle, now: Date = Date()) async -> String {
        let slot = BriefSlot(date: now)
        if let cached = cachedText(for: bundle.snapshot, slot: slot, kind: .dailyBrief) {
            return cached
        }

        if #available(iOS 26.0, *) {
            if let generated = await generatedSummary(for: bundle, slot: slot, mode: slot == .evening ? .eveningBrief : .dayBrief) {
                cache(generated, for: bundle.snapshot, slot: slot, kind: .dailyBrief)
                return generated
            }
        }

        return "Daily brief unavailable on this device."
    }

    func shortInsight(for bundle: DashboardBundle, now: Date = Date()) async -> String {
        let slot = BriefSlot(date: now)
        if let cached = cachedText(for: bundle.snapshot, slot: slot, kind: .shortInsight) {
            return cached
        }

        if #available(iOS 26.0, *) {
            if let generated = await generatedSummary(for: bundle, slot: slot, mode: .shortInsight) {
                cache(generated, for: bundle.snapshot, slot: slot, kind: .shortInsight)
                return generated
            }
        }

        return "Insight unavailable on this device."
    }

    func previewDailyBrief(now: Date = Date()) -> String {
        let slot = BriefSlot(date: now)
        if slot == .evening {
            return "Tonight is for protecting recovery: keep the wind-down simple, avoid late intensity, and give sleep enough room to do its job."
        }
        return "Recovery supports a purposeful day: build useful strain if it fits your plan, then keep enough margin for a calm evening and strong sleep."
    }

    func previewShortInsight(now: Date = Date()) -> String {
        BriefSlot(date: now) == .evening
            ? "The day is ready to close with a steady wind-down."
            : "Recovery looks supportive, so today can handle purposeful movement."
    }

    @available(iOS 26.0, *)
    private func generatedSummary(for bundle: DashboardBundle, slot: BriefSlot, mode: InsightMode) async -> String? {
        let model = SystemLanguageModel.default
        guard model.availability == .available else { return nil }

        let context = DailyInsightContext(bundle: bundle, slot: slot)
        let prompt = """
        \(mode.task)

        Output rules:
        - Do not use bullet points.
        - Do not quote numeric scores, metric values, component scores, percentages, load points, or thresholds.
        - Write directly to the user with "you" and "your". The tone should feel personal, not like a detached report.
        - Translate the data into plain guidance. Say what you should do and why.
        - Name your dominant limiter or opportunity when one is clear.
        - Prefer natural sentences over compressed clauses. For example: "Your main limiter today is recent training load" instead of "The limiter is recent load."
        - Keep medical language cautious. Do not diagnose illness, injury, sleep disorders, or cardiovascular problems.
        - If data quality or confidence is weak, phrase the recommendation cautiously.
        - Do not echo internal component keys from the data, such as recent_load_fit or illness_anomaly_context.
        - Do name user-facing metrics when they explain the recommendation, such as HRV, resting heart rate, respiratory rate, oxygen saturation, sleep duration, strain, and sleep debt.
        - If an anomaly signal matters, name the metric behind it instead of saying "one recovery signal" or "a metric."

        Current local phase: \(slot.promptLabel)

        Domain contract:
        \(Self.domainContract)

        User data:
        \(context.promptBlock)
        """

        do {
            let session = LanguageModelSession(
                model: model,
                instructions: "You write practical wearable-based recovery, sleep, and training guidance for a fitness dashboard. You understand the app's Sleep, Strain, and Readiness scores from their components and personal baselines, then convert them into concise user-facing coaching."
            )
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: mode.maximumResponseTokens)
            )
            return cleaned(response.content, for: mode)
        } catch {
            return nil
        }
    }

    private static let domainContract = """
    Sleep is a 0-100 view of last night's sleep quality and adequacy. It relies most on sleep duration, timing consistency, and sleep continuity because wearables are better at broad sleep-wake patterns than exact sleep stages. Timing and overnight physiology are supporting signals. Sleep stages are useful context but should not override a short, irregular, or broken night.

    Strain is accumulated load, not a 0-100 quality score. More strain is not automatically better. Interpret strain against your weekly target, chronic load, recent training load, and whether load came from cardio, ordinary activity, or muscular work. If weekly strain is already high, favor maintenance or recovery even if sleep looks good.

    Readiness is a personalized estimate of whether your body appears recovered enough for strain today. It combines sleep adequacy and sleep debt, overnight recovery signals, recent training load, illness-like anomaly context, and confidence. Readiness should guide training ambition: strong readiness can support purposeful strain, while low readiness should shift you toward easy movement and recovery.

    HRV is interpreted against the user's own baseline. Higher than usual often supports recovery; suppressed HRV can reflect stress, poor sleep, heavy training load, alcohol, travel, or possible illness. Do not treat one HRV value as a diagnosis.

    Resting heart rate is interpreted against the user's own baseline. Lower or normal values tend to support recovery. Elevated resting heart rate can reflect incomplete recovery, stress, dehydration, heat, alcohol, heavy recent load, or possible illness.

    Respiratory rate and oxygen saturation are anomaly/context signals. If respiratory rate is elevated or oxygen saturation is low, be conservative and suggest recovery-focused behavior without making medical claims.

    Sleep debt means the user may need more recovery even if one score is acceptable. Recent load spikes should make advice more conservative, especially when autonomic signals are also poor.
    """

    private func cleaned(_ text: String, for mode: InsightMode) -> String? {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !trimmed.isEmpty else { return nil }
        let collapsed = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if mode == .shortInsight {
            return String(collapsed.prefix(220))
        }
        return collapsed
    }

    private func cachedText(for snapshot: DashboardSnapshot, slot: BriefSlot, kind: CacheKind) -> String? {
        guard snapshot.isCacheableForDailyInsight else { return nil }
        guard let data = UserDefaults.standard.data(forKey: cacheKey(for: snapshot, slot: slot, kind: kind)),
              let entry = try? JSONDecoder().decode(CachedInsight.self, from: data)
        else {
            return nil
        }
        guard entry.userID == snapshot.userID,
              entry.date == snapshot.date,
              entry.slot == slot.rawValue,
              entry.kind == kind.rawValue,
              !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        UserDefaults.standard.set(data, forKey: lastCacheKey(for: slot, kind: kind))
        return entry.text
    }

    private func cache(_ text: String, for snapshot: DashboardSnapshot, slot: BriefSlot, kind: CacheKind) {
        guard snapshot.isCacheableForDailyInsight else { return }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let entry = CachedInsight(
            userID: snapshot.userID,
            date: snapshot.date,
            slot: slot.rawValue,
            kind: kind.rawValue,
            text: cleaned,
            generatedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(for: snapshot, slot: slot, kind: kind))
        UserDefaults.standard.set(data, forKey: lastCacheKey(for: slot, kind: kind))
    }

    private func cacheKey(for snapshot: DashboardSnapshot, slot: BriefSlot, kind: CacheKind) -> String {
        "dailyInsight.v2.\(snapshot.userID).\(snapshot.date).\(slot.rawValue).\(kind.rawValue)"
    }

    private func cachedLastText(for slot: BriefSlot, kind: CacheKind, now: Date) -> String? {
        guard let entry = UserDefaults.standard.data(forKey: lastCacheKey(for: slot, kind: kind)).flatMap({
            try? JSONDecoder().decode(CachedInsight.self, from: $0)
        }) else {
            return nil
        }
        guard entry.slot == slot.rawValue,
              entry.kind == kind.rawValue,
              allowedSnapshotDates(for: slot, now: now).contains(entry.date),
              !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return entry.text
    }

    private func lastCacheKey(for slot: BriefSlot, kind: CacheKind) -> String {
        "dailyInsight.v2.last.\(slot.rawValue).\(kind.rawValue)"
    }

    private func allowedSnapshotDates(for slot: BriefSlot, now: Date, calendar: Calendar = .current) -> Set<String> {
        var dates = [Self.cacheDateFormatter.string(from: now)]
        let hour = calendar.component(.hour, from: now)
        if slot == .evening, hour < 4, let yesterday = calendar.date(byAdding: .day, value: -1, to: now) {
            dates.append(Self.cacheDateFormatter.string(from: yesterday))
        }
        return Set(dates)
    }

    private static let cacheDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct DailyInsightContext {
    let bundle: DashboardBundle
    let slot: BriefSlot

    var promptBlock: String {
        [
            "Snapshot:",
            snapshotBlock,
            "",
            "Score components and inputs:",
            scoreBlock,
            "",
            "Key metrics:",
            metricsBlock,
            "",
            "Recent workout context:",
            workoutsBlock,
            "",
            "Interpretive signals:",
            interpretationBlock,
        ].joined(separator: "\n")
    }

    private var snapshotBlock: String {
        let snapshot = bundle.snapshot
        return [
            "- date: \(snapshot.date)",
            "- dashboard_data_quality: \(snapshot.dataQuality ?? "unknown")",
            "- phase: \(slot.promptLabel)",
        ].joined(separator: "\n")
    }

    private var scoreBlock: String {
        let snapshot = bundle.snapshot
        return [
            scoreSection(name: "sleep", score: snapshot.scores.sleep),
            scoreSection(name: "readiness", score: snapshot.scores.readiness),
            scoreSection(name: "strain", score: snapshot.scores.strain),
            strainTargetSection(snapshot.strainTarget),
        ].joined(separator: "\n")
    }

    private var metricsBlock: String {
        let metrics = bundle.snapshot.metrics
        var lines = [
            "- steps: \(format(metrics?.steps))",
            "- active_calories: \(format(metrics?.activeCalories))",
            "- total_calories: \(format(metrics?.totalCalories))",
            "- distance_meters: \(format(metrics?.distanceMeters))",
            "- resting_heart_rate: \(format(metrics?.restingHeartRate))",
            "- heart_rate_variability: \(format(metrics?.heartRateVariability))",
            "- oxygen_saturation: \(format(metrics?.oxygenSaturation))",
            "- respiratory_rate: \(format(metrics?.respiratoryRate))",
            "- sleep_minutes: \(format(metrics?.sleepMinutes))",
            "- workout_count: \(format(metrics?.workoutCount))",
            "- metrics_data_quality: \(metrics?.dataQuality ?? "unknown")",
            "- vo2_max_current: \(format(bundle.vo2Max?.current?.value))",
            "- vo2_max_data_quality: \(bundle.vo2Max?.dataQuality ?? "unknown")",
        ]

        for key in bundle.metricSummaries.keys.sorted() {
            guard let summary = bundle.metricSummaries[key] else { continue }
            lines.append("- metric_summary.\(key).current: \(format(summary.current?.value)); quality: \(summary.dataQuality ?? "unknown")")
        }
        return lines.joined(separator: "\n")
    }

    private var workoutsBlock: String {
        let workouts = bundle.recentWorkouts.prefix(5)
        guard !workouts.isEmpty else { return "- no recent workouts supplied" }
        return workouts.map { workout in
            "- \(workout.workoutType ?? "workout") on \(workout.date ?? "unknown date"); duration_seconds: \(format(workout.durationSeconds)); active_calories: \(format(workout.activeCalories)); distance_meters: \(format(workout.distanceMeters)); intensity: \(workout.intensity ?? "unknown"); avg_hr: \(format(workout.heartRate?.averageBPM)); max_hr: \(format(workout.heartRate?.maxBPM))"
        }.joined(separator: "\n")
    }

    private var interpretationBlock: String {
        let snapshot = bundle.snapshot
        let readinessDrivers = driverSummary(
            components: snapshot.scores.readiness?.components,
            preferredOrder: [
                ("illness_anomaly_context", "recovery anomaly context"),
                ("autonomic_recovery", "overnight recovery signals"),
                ("sleep_adequacy_debt", "sleep adequacy and sleep debt"),
                ("recent_load_fit", "recent training load"),
                ("confidence", "personal baseline confidence"),
            ]
        )
        let sleepDrivers = driverSummary(
            components: snapshot.scores.sleep?.components,
            preferredOrder: [
                ("duration", "sleep duration"),
                ("regularity", "sleep timing consistency"),
                ("continuity", "sleep continuity"),
                ("timing", "bedtime timing"),
                ("physiology", "overnight recovery signals"),
                ("stages", "sleep stage estimate"),
            ]
        )
        let strainDrivers = strainDriverSummary(snapshot.scores.strain?.components)
        let strainTarget = snapshot.strainTarget
        return [
            "- sleep_overall: \(scoreBand(snapshot.scores.sleep?.value)); plain_language_sleep_drivers: \(sleepDrivers)",
            "- readiness_overall: \(scoreBand(snapshot.scores.readiness?.value)); plain_language_readiness_drivers: \(readinessDrivers)",
            "- current_strain_load: \(format(snapshot.scores.strain?.value)); plain_language_strain_sources: \(strainDrivers)",
            "- weekly_training_load: \(strainTarget?.loadBand ?? "unknown"); weekly_progress_ratio: \(format(strainTarget?.progressRatio)); target_load_points: \(format(strainTarget?.targetLoadPoints)); progress_load_points: \(format(strainTarget?.progressLoadPoints))",
            "- hrv_signal: \(baselineSignal(snapshot.scores.readiness?.components?["autonomic_recovery"]?.objectValue?["hrv"]))",
            "- resting_hr_signal: \(baselineSignal(snapshot.scores.readiness?.components?["autonomic_recovery"]?.objectValue?["rhr"]))",
            "- anomaly_signals: \(anomalySignals(snapshot.scores.readiness?.components?["illness_anomaly_context"]))",
            "- confidence_phase: readiness=\(snapshot.scores.readiness?.confidencePhase ?? "unknown"), sleep=\(snapshot.scores.sleep?.confidencePhase ?? "unknown"), strain=\(snapshot.scores.strain?.confidencePhase ?? "unknown")",
        ].joined(separator: "\n")
    }

    private func scoreSection(name: String, score: DailyScore?) -> String {
        guard let score else { return "\(name): missing" }
        return [
            "\(name):",
            "- value: \(format(score.value)); unit: \(score.unit ?? "unknown"); status: \(score.status ?? "unknown"); confidence: \(score.confidencePhase ?? "unknown"); data_quality: \(score.dataQuality ?? "unknown")",
            "- reasons: \(reasonSummary(score.reasons))",
            "- components: \(formatJSON(.object(score.components ?? [:])))",
            "- inputs: \(formatJSON(.object(score.inputs ?? [:])))",
        ].joined(separator: "\n")
    }

    private func strainTargetSection(_ target: StrainTarget?) -> String {
        guard let target else { return "strain_target: missing" }
        return [
            "strain_target:",
            "- target_load_points: \(format(target.targetLoadPoints)); chronic_load_points: \(format(target.chronicLoadPoints)); acute_load_points: \(format(target.acuteLoadPoints)); progress_load_points: \(format(target.progressLoadPoints)); progress_ratio: \(format(target.progressRatio)); load_band: \(target.loadBand ?? "unknown"); confidence: \(target.confidencePhase ?? "unknown")",
            "- components: \(formatJSON(.object(target.components ?? [:])))",
            "- inputs: \(formatJSON(.object(target.inputs ?? [:])))",
        ].joined(separator: "\n")
    }

    private func reasonSummary(_ reasons: [ScoreReason]?) -> String {
        guard let reasons, !reasons.isEmpty else { return "none" }
        return reasons.map { reason in
            "\(reason.code ?? "unknown")(\(reason.severity ?? "unknown"), \(reason.direction ?? "unknown")): \(reason.message ?? "")"
        }.joined(separator: "; ")
    }

    private func driverSummary(components: [String: JSONValue]?, preferredOrder: [(key: String, label: String)]) -> String {
        guard let components else { return "unknown" }
        let scored = preferredOrder.compactMap { item -> String? in
            let key = item.key
            let label = item.label
            guard let score = components[key]?.objectValue?["score"]?.doubleValue else { return nil }
            return "\(label) \(scoreBand(score))"
        }
        return scored.isEmpty ? "unknown" : scored.joined(separator: ", ")
    }

    private func strainDriverSummary(_ components: [String: JSONValue]?) -> String {
        guard let components else { return "unknown" }
        let keys: [(key: String, label: String)] = [
            ("cardio_load", "cardio load"),
            ("source_zone_load", "provider zone load"),
            ("daily_activity_load", "ordinary activity"),
            ("muscular_load", "strength or muscular load"),
            ("rpe_load", "reported effort load"),
            ("total_load", "total strain"),
        ]
        let parts = keys.compactMap { item -> String? in
            let key = item.key
            let label = item.label
            guard let value = components[key] else { return nil }
            if let object = value.objectValue {
                if let load = object["load_points"]?.doubleValue {
                    return "\(label)=\(format(load))"
                }
                return "\(label)=available"
            }
            if case .null = value {
                return "\(label)=missing"
            }
            return "\(label)=\(formatJSON(value))"
        }
        return parts.isEmpty ? "unknown" : parts.joined(separator: ", ")
    }

    private func baselineSignal(_ value: JSONValue?) -> String {
        guard let object = value?.objectValue else { return "unknown" }
        let score = object["score"]?.doubleValue
        let baseline = object["baseline"]?.doubleValue ?? object["median"]?.doubleValue
        let observed = object["value"]?.doubleValue
        return "score_band=\(scoreBand(score)); observed=\(format(observed)); baseline=\(format(baseline))"
    }

    private func anomalySignals(_ value: JSONValue?) -> String {
        guard let object = value?.objectValue else { return "unknown" }
        let anomalies = object["anomalies"]?.arrayValue?.map { anomalyLabel(formatJSON($0)) }.joined(separator: ", ")
        return anomalies?.isEmpty == false ? anomalies! : "none"
    }

    private func anomalyLabel(_ value: String) -> String {
        switch value {
        case "oxygen_saturation_low":
            return "oxygen saturation is low"
        case "respiratory_rate_elevated":
            return "respiratory rate is elevated"
        case "hrv_suppressed":
            return "HRV is suppressed"
        case "resting_hr_elevated":
            return "resting heart rate is elevated"
        case "illness_tag":
            return "illness tag is present"
        default:
            return value.displayTitle.lowercased()
        }
    }

    private func scoreBand(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        if value >= 85 { return "strong" }
        if value >= 70 { return "solid" }
        if value >= 55 { return "limited" }
        return "low"
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return value.clean
    }

    private func format(_ value: Int?) -> String {
        guard let value else { return "unknown" }
        return String(value)
    }

    private func formatJSON(_ value: JSONValue) -> String {
        switch value {
        case .string(let string):
            return string
        case .number(let number):
            return number.clean
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null:
            return "null"
        case .array(let array):
            return "[" + array.prefix(12).map(formatJSON).joined(separator: ", ") + (array.count > 12 ? ", ..." : "") + "]"
        case .object(let object):
            let parts = object.keys.sorted().prefix(40).map { key in
                "\(key): \(formatJSON(object[key] ?? .null))"
            }
            return "{" + parts.joined(separator: ", ") + (object.count > 40 ? ", ..." : "") + "}"
        }
    }
}

private enum InsightMode: Equatable {
    case dayBrief
    case eveningBrief
    case shortInsight

    var task: String {
        switch self {
        case .dayBrief:
            return "Write one daily health coaching brief in 70 to 95 words. The brief should tell the user what to aim for today and why: whether this is a good day for a workout, an easier movement day, recovery, or a normal steady day."
        case .eveningBrief:
            return "Write one evening health coaching brief in 70 to 95 words. The brief should tell the user how to wind down tonight and why: whether to keep rhythm, catch up on sleep, avoid more strain, or prepare for tomorrow."
        case .shortInsight:
            return "Write a very short dashboard insight in one or two sentences. It should summarize what the scores mean for the user's day without using numbers."
        }
    }

    var maximumResponseTokens: Int {
        switch self {
        case .dayBrief, .eveningBrief:
            return 180
        case .shortInsight:
            return 70
        }
    }
}

private enum BriefSlot: String, Equatable, Codable {
    case daytime
    case evening

    init(date: Date, calendar: Calendar = .current) {
        let hour = calendar.component(.hour, from: date)
        self = hour >= 4 && hour < 18 ? .daytime : .evening
    }

    var promptLabel: String {
        switch self {
        case .daytime:
            return "daytime"
        case .evening:
            return "evening"
        }
    }
}

private enum CacheKind: String, Codable {
    case dailyBrief
    case shortInsight
}

private struct CachedInsight: Codable {
    let userID: String
    let date: String
    let slot: String
    let kind: String
    let text: String
    let generatedAt: Date
}

private extension DashboardSnapshot {
    var isCacheableForDailyInsight: Bool {
        guard userID != "preview", dataQuality != "missing", metrics != nil else { return false }
        return scores.sleep?.value != nil
            || scores.readiness?.value != nil
            || metrics?.sleepMinutes != nil
    }
}
