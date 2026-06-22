import SwiftUI

@main
struct ConceptualFitnessApp: App {
    @StateObject private var authStore = AuthStore()

    var body: some Scene {
        WindowGroup {
            AuthGateView(authStore: authStore)
        }
    }
}
