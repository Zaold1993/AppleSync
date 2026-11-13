import AppleSyncCore
import SwiftUI

@main
struct AppleSyncApp: App {
    @State private var viewModel = AppleSyncViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(viewModel: viewModel)
        } label: {
            Label {
                Text("AppleSync")
            } icon: {
                switch viewModel.menuBarStatus {
                case .idle:
                    Image(systemName: "iphone.and.arrow.forward")
                case .syncing:
                    Image(systemName: "arrow.triangle.2.circlepath")
                case .paused:
                    Image(systemName: "pause.circle")
                case .warning:
                    Image(systemName: "exclamationmark.circle.fill")
                case .urgent:
                    Image(systemName: "exclamationmark.triangle.fill")
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("AppleSync Manager", id: "dashboard") {
            DashboardView(viewModel: viewModel)
        }
        .defaultSize(width: 960, height: 640)
    }
}
