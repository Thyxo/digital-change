import SwiftUI

@main
struct KameraPlusApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var engine: Engine

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _engine = StateObject(wrappedValue: Engine(settings: s))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
    }
}
