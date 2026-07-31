import SwiftData
import SwiftUI

@main
struct BuddyApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: DashboardSnapshot.self)
        } catch {
            fatalError("Unable to create Buddy's local cache: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(modelContainer)
    }
}
