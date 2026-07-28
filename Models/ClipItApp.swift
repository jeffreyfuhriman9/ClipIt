import SwiftUI

@main
struct ClipItApp: App {
    // MARK: - State Objects
    
    @StateObject private var recordingViewModel = RecordingViewModel()
    @StateObject private var bleViewModel = BLEViewModel()
    @StateObject private var multipeerManager = MultipeerManager()
    
    // MARK: - Environment
    
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recordingViewModel)
                .environmentObject(bleViewModel)
                .environmentObject(multipeerManager)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        print("📱 App entered background mode")
                    case .inactive:
                        print("📱 App became inactive")
                    case .active:
                        print("📱 App became active")
                    @unknown default:
                        break
                    }
                }
        }
    }
}
