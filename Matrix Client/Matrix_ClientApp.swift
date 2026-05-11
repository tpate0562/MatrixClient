import SwiftUI

@main
struct Matrix_ClientApp: App {
    @StateObject private var session = MatrixSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
        }
        .windowResizability(.contentMinSize)

        Settings {
            Text("Matrix Client").padding()
        }
    }
}
