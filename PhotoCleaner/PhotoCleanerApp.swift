import SwiftUI

@main
struct PhotoCleanerApp: App {
    init() {
        // Start the audio session + pre-render the swipe/undo/trash
        // buffers now, so the very first swipe doesn't pay session
        // activation + tone rendering mid-gesture.
        SoundEffects.prewarm()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
