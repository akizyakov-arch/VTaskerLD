import SwiftUI
import UniformTypeIdentifiers

@main
struct VTASKApp: App {
    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .frame(minWidth: 720, minHeight: 450)
        }
        .defaultSize(width: 1200, height: 760)

    }
}
