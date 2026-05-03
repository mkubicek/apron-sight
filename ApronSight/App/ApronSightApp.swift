import SwiftUI

@main
struct ApronSightApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }

        ImmersiveSpace(id: "HomeDemoImmersiveSpace") {
            ImmersiveView(model: model)
        }
    }
}
