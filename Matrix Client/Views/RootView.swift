import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: MatrixSession

    var body: some View {
        Group {
            if session.isAuthenticated {
                MainView()
            } else {
                LoginView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
