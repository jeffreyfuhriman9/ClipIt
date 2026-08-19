import SwiftUI

@main
struct ClipItApp: App {
    // MARK: - State Objects
    
    @StateObject private var recordingViewModel = RecordingViewModel()
    @StateObject private var bleViewModel = BLEViewModel()
    @StateObject private var multipeerManager = MultipeerManager()
    
    // MARK: - Environment
    
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor(Color.cosmosBlue)]
        appearance.titleTextAttributes = [.foregroundColor: UIColor(Color.cosmosBlue)]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some Scene {
            WindowGroup {
                ContentView()
                    .environmentObject(recordingViewModel)
                    .environmentObject(bleViewModel)
                    .environmentObject(multipeerManager)
                    .preferredColorScheme(.light) // 👈 Forces light mode app-wide
                    .tint(Color.cosmosBlue) // 👈 Tints nav bar titles, buttons, etc. app-wide — avoids the iOS 26 UINavigationBarAppearance large-title bug
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
