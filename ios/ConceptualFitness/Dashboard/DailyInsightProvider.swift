import Foundation
import FoundationModels

struct DailyInsightProvider {
    func cachedDailyBriefForCurrentSlot(now: Date = Date()) -> String? {
        cachedLastText(for: BriefSlot(date: now), kind: .dailyBrief, now: now)
    }

    func dailyBrief(for snapshot: DashboardSnapshot, now: Date = Date()) async -> String {
        let slot = BriefSlot(date: now)
        if let cached = cachedText(for: snapshot, slot: slot, kind: .dailyBrief) {
            return cached
        }

        if #available(iOS 26.0, *) {
            if let generated = await foundationModelSummary(for: snapshot, slot: slot) {
                cache(generated, for: snapshot, slot: slot, kind: .dailyBrief)
                return generated
            }
        }
        let fallback = fallbackDailyBrief(for: snapshot, now: now)
        cache(fallback, for: snapshot, slot: slot, kind: .dailyBrief)
        return fallback
    }

    func shortInsight(for snapshot: DashboardSnapshot, now: Date = Date()) -> String {
        let slot = BriefSlot(date: now)
        if let cached = cachedText(for: snapshot, slot: slot, kind: .shortInsight) {
            return cached
        }

        let sleep = snapshot.scores.sleep?.value
        let readiness = snapshot.scores.readiness?.value
        let strainProgress = snapshot.strainTarget?.progressRatio
        let insight: String

        if slot == .evening {
            if let sleep, sleep < 60 {
                insight = "Sleep is the main limiter. Keep tonight's plan quiet and protect a full sleep window."
            } else if let readiness, readiness < 55 {
                insight = "Readiness is low. Keep the evening easy and let recovery lead the plan."
            } else if let strainProgress, strainProgress > 1.05 {
                insight = "Weekly strain is already high. Use tonight for maintenance and recovery."
            } else if let readiness, readiness >= 80, let sleep, sleep >= 80 {
                insight = "Recovery is in a good place. Keep tonight calm so the sleep win carries forward."
            } else {
                insight = "Your scores point to a balanced day. Finish with an easy wind-down."
            }
        } else {
            if let readiness, readiness >= 80, let sleep, sleep >= 80 {
                insight = "Strong recovery supports a purposeful push today. Build strain steadily."
            } else if let readiness, readiness < 55 {
                insight = "Readiness is low today. Keep movement easy and hold strain below target."
            } else if let sleep, sleep < 60 {
                insight = "Sleep is the main limiter today. Keep training controlled and prioritize tonight's wind-down."
            } else if let strainProgress, strainProgress > 1.05 {
                insight = "You are already over this week's strain target. Treat today as maintenance."
            } else {
                insight = "Your scores point to a balanced day. Build useful strain steadily."
            }
        }

        cache(insight, for: snapshot, slot: slot, kind: .shortInsight)
        return insight
    }

    func fallbackDailyBrief(for snapshot: DashboardSnapshot, now: Date = Date()) -> String {
        let slot = BriefSlot(date: now)
        let sleep = snapshot.scores.sleep?.value
        let readiness = snapshot.scores.readiness?.value
        let strainProgress = snapshot.strainTarget?.progressRatio
        let sleepText = sleepDurationText(minutes: snapshot.metrics?.sleepMinutes)
        let hrvText = snapshot.metrics?.heartRateVariability.map { "HRV is \($0.clean) ms" }
        let restingText = snapshot.metrics?.restingHeartRate.map { "resting heart rate is \($0.clean) bpm" }
        let recoverySignal = [hrvText, restingText].compactMap(\.self).joined(separator: " and ")

        if slot == .evening {
            if let sleep, sleep < 70 {
                return "Last night looks like the main recovery limiter, with \(sleepText) logged and a sleep score of \(Int(sleep.rounded())). Keep the rest of tonight simple: finish hard training and heavy meals early, dim screens, and start a consistent wind-down. Aim for a full sleep window, a cooler room, and an easy morning plan so recovery can catch up."
            }
            return "Your recovery picture is \(readinessText(readiness)), and last night's sleep logged \(sleepText). Tonight's goal is to protect that base: keep the evening low-friction, avoid late intensity, and give yourself enough time in bed to repeat a strong sleep window. If you want movement, keep it relaxed and let the day close without chasing more strain."
        }

        if let readiness, readiness < 55 {
            return "Readiness is low today, so treat recovery as the priority. Last night's sleep logged \(sleepText), and \(recoverySignal.isEmpty ? "your recovery signals are still settling" : recoverySignal). Keep training easy, cap strain below target, and use light movement, hydration, and steady meals to help your system normalize before asking for more intensity."
        }

        if let sleep, sleep < 60 {
            return "Sleep is the main limiter after \(sleepText) last night. Keep today's aim controlled: move enough to feel better, but avoid stacking hard intensity on top of poor recovery. Prioritize daylight, hydration, and a clear caffeine cutoff, then make tonight's wind-down non-negotiable so you can rebuild sleep pressure and recover more fully."
        }

        if let strainProgress, strainProgress > 1.05 {
            return "You are already past this week's strain target, so the useful move today is maintenance. Last night's sleep logged \(sleepText), and readiness is \(readinessText(readiness)). Keep movement low to moderate, leave hard intervals for another day, and focus on recovery basics so tomorrow's baseline is not dragged down by extra load."
        }

        if let readiness, readiness >= 80, let sleep, sleep >= 80 {
            return "Recovery looks strong after \(sleepText) last night, with sleep and readiness both in a good range. Use today for a purposeful push if it fits your plan: build strain steadily, warm up properly, and stop short of turning a good recovery day into unnecessary fatigue. Keep the evening calm so the sleep win carries forward."
        }

        return "Your scores point to a balanced day after \(sleepText) last night. Aim for useful strain rather than maximum strain: get movement in, keep intensity honest, and watch how energy changes through the day. \(recoverySignalSentence(recoverySignal)) Finish with a simple wind-down so tomorrow starts from a stable recovery base."
    }

    @available(iOS 26.0, *)
    private func foundationModelSummary(for snapshot: DashboardSnapshot, slot: BriefSlot) async -> String? {
        let model = SystemLanguageModel.default
        guard model.availability == .available else { return nil }

        let strainPercent = ((snapshot.strainTarget?.progressRatio ?? 0) * 100).rounded()
        let sleepDuration = sleepDurationText(minutes: snapshot.metrics?.sleepMinutes)
        let prompt = """
        Write one daily health coaching brief in 70 to 95 words.
        Use calm direct language. Do not diagnose. Do not use bullet points.
        Describe last night's sleep and recovery, then give a specific aim for the next part of the day.
        Current local phase: \(slot.promptLabel).
        If the phase is evening, focus on tonight's sleep goal and a practical wind-down plan instead of pushing training.
        Readiness: \(snapshot.scores.readiness?.value?.clean ?? "unknown").
        Sleep: \(snapshot.scores.sleep?.value?.clean ?? "unknown").
        Sleep duration: \(sleepDuration).
        Strain target progress: \(Int(strainPercent))%.
        HRV: \(snapshot.metrics?.heartRateVariability?.clean ?? "unknown").
        Resting heart rate: \(snapshot.metrics?.restingHeartRate?.clean ?? "unknown").
        Steps: \(snapshot.metrics?.steps.map(String.init) ?? "unknown").
        """

        do {
            let session = LanguageModelSession(
                model: model,
                instructions: "You write practical wearable-based recovery, sleep, and training briefs for a fitness dashboard."
            )
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.25, maximumResponseTokens: 180)
            )
            let cleaned = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil
        }
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
        "dailyInsight.v1.\(snapshot.userID).\(snapshot.date).\(slot.rawValue).\(kind.rawValue)"
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
        "dailyInsight.v1.last.\(slot.rawValue).\(kind.rawValue)"
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

    private func sleepDurationText(minutes: Int?) -> String {
        guard let minutes else { return "no confirmed sleep duration" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) minutes" }
        if remainder == 0 { return "\(hours) hours" }
        return "\(hours) hours \(remainder) minutes"
    }

    private func readinessText(_ value: Double?) -> String {
        guard let value else { return "still being established" }
        if value >= 80 { return "strong" }
        if value >= 65 { return "solid" }
        if value >= 50 { return "moderate" }
        return "low"
    }

    private func recoverySignalSentence(_ value: String) -> String {
        guard let first = value.first else {
            return "As more data syncs, the brief will become more specific."
        }
        return "\(String(first).uppercased())\(value.dropFirst())."
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
