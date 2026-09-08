import SwiftUI

@main
struct SpatialDemoApp: App {
    @State private var session = DemoSessionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            SpatialDemoView(session: session)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active: session.appDidBecomeActive()
                    case .background: session.appDidEnterBackground()
                    default: break // System permission sheets temporarily make the app inactive.
                    }
                }
        }
    }
}
