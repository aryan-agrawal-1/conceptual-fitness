import Foundation
import FoundationModels

struct DailyInsightProvider {
    func dailyBrief(for snapshot: DashboardSnapshot, now: Date = Date()) async -> String {
        if #available(iOS 26.0, *) {
            if let generated = await foundationModelSummary(for: snapshot, now: now) {
                return generated
            }
        }
        return fallbackDailyBrief(for: snapshot, now: now)
    }

    func shortInsight(for snapshot: DashboardSnapshot) -> String {
        let sleep = snapshot.scores.sleep?.value
        let readiness = snapshot.scores.readiness?.value
        let strainProgress = snapshot.strainTarget?.progressRatio

        if let readiness, readiness >= 80, let sleep, sleep >= 80 {
            return "Strong recovery supports a purposeful push today. Build strain steadily."
        }

        if let readiness, readiness < 55 {
            return "Readiness is low today. Keep movement easy and hold strain below target."
        }

        if let sleep, sleep < 60 {
            return "Sleep is the main limiter today. Keep training controlled and prioritize tonight's wind-down."
        }

        if let strainProgress, strainProgress > 1.05 {
            return "You are already over this week's strain target. Treat today as maintenance."
        }

        return "Your scores point to a balanced day. Build useful strain steadily."
    }

    func fallbackDailyBrief(for snapshot: DashboardSnapshot, now: Date = Date()) -> String {
        let dayPhase = DayPhase(date: now)
        let sleep = snapshot.scores.sleep?.value
        let readiness = snapshot.scores.readiness?.value
        let strainProgress = snapshot.strainTarget?.progressRatio
        let sleepText = sleepDurationText(minutes: snapshot.metrics?.sleepMinutes)
        let hrvText = snapshot.metrics?.heartRateVariability.map { "HRV is \($0.clean) ms" }
        let restingText = snapshot.metrics?.restingHeartRate.map { "resting heart rate is \($0.clean) bpm" }
        let recoverySignal = [hrvText, restingText].compactMap(\.self).joined(separator: " and ")

        if dayPhase == .evening {
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
    private func foundationModelSummary(for snapshot: DashboardSnapshot, now: Date) async -> String? {
        let model = SystemLanguageModel.default
        guard model.availability == .available else { return nil }

        let dayPhase = DayPhase(date: now)
        let strainPercent = ((snapshot.strainTarget?.progressRatio ?? 0) * 100).rounded()
        let sleepDuration = sleepDurationText(minutes: snapshot.metrics?.sleepMinutes)
        let prompt = """
        Write one daily health coaching brief in 70 to 95 words.
        Use calm direct language. Do not diagnose. Do not use bullet points.
        Describe last night's sleep and recovery, then give a specific aim for the next part of the day.
        Current local phase: \(dayPhase.promptLabel).
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

private enum DayPhase: Equatable {
    case morning
    case afternoon
    case evening

    init(date: Date, calendar: Calendar = .current) {
        let hour = calendar.component(.hour, from: date)
        if hour >= 4 && hour < 12 {
            self = .morning
        } else if hour >= 12 && hour < 18 {
            self = .afternoon
        } else {
            self = .evening
        }
    }

    var promptLabel: String {
        switch self {
        case .morning:
            return "morning"
        case .afternoon:
            return "afternoon"
        case .evening:
            return "evening"
        }
    }
}
