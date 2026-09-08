import SwiftUI

@main
struct SpatialDemoApp: App {
    @State private var session = DemoSessionModel()

    var body: some Scene {
        WindowGroup {
            SpatialDemoView(session: session)
                .preferredColorScheme(.dark)
        }
    }
}
