import Foundation
import FoundationModels

struct DailyInsightProvider {
    func summary(for snapshot: DashboardSnapshot) async -> String {
        if #available(iOS 26.0, *) {
            if let generated = await foundationModelSummary(for: snapshot) {
                return generated
            }
        }
        return fallbackSummary(for: snapshot)
    }

    private func fallbackSummary(for snapshot: DashboardSnapshot) -> String {
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

    @available(iOS 26.0, *)
    private func foundationModelSummary(for snapshot: DashboardSnapshot) async -> String? {
        let model = SystemLanguageModel.default
        guard model.availability == .available else { return nil }

        let strainPercent = ((snapshot.strainTarget?.progressRatio ?? 0) * 100).rounded()
        let prompt = """
        Write one concise daily health coaching summary in 18 words or fewer.
        Mention today's aim. Do not diagnose. Use calm direct language.
        Readiness: \(snapshot.scores.readiness?.value?.clean ?? "unknown").
        Sleep: \(snapshot.scores.sleep?.value?.clean ?? "unknown").
        Strain target progress: \(Int(strainPercent))%.
        HRV: \(snapshot.metrics?.heartRateVariability?.clean ?? "unknown").
        Resting heart rate: \(snapshot.metrics?.restingHeartRate?.clean ?? "unknown").
        """

        do {
            let session = LanguageModelSession(
                model: model,
                instructions: "You summarize wearable scores for a fitness dashboard. Keep advice practical, safe, and specific."
            )
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 45)
            )
            let cleaned = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil
        }
    }
}
