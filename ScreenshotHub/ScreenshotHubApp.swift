import SwiftUI
    
@main
struct ScreenshotHubApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: ScreenshotHubDocument()) { file in
            ContentView(document: file.$document)
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)
        .commands { InspectorCommands() }
    }
}
