import SwiftUI
import WilloPkg

// Entry point - delegates to WilloPkg's app implementation
@main
struct WilloAppMain: App {
    var body: some Scene {
        WilloPkg.WilloApp().body
    }
}
