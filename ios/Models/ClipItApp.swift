import SwiftUI
import UIKit
import UserNotifications

final class ClipItAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var recordingOrientationMask: UIInterfaceOrientationMask?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        recordingOrientationMask ?? (window?.windowScene?.traitCollection.userInterfaceIdiom == .pad ? .all : .allButUpsideDown)
    }
}

@MainActor
enum RecordingOrientationController {
    static func lockToCurrentInterfaceOrientation() {
        guard let appDelegate = UIApplication.shared.delegate as? ClipItAppDelegate,
              let scene = activeWindowScene() else { return }

        let mask: UIInterfaceOrientationMask
        switch scene.interfaceOrientation {
        case .portrait: mask = .portrait
        case .portraitUpsideDown: mask = .portraitUpsideDown
        case .landscapeLeft: mask = .landscapeLeft
        case .landscapeRight: mask = .landscapeRight
        default: return
        }

        appDelegate.recordingOrientationMask = mask
        updateSupportedOrientations(in: scene)
    }

    static func unlock() {
        guard let appDelegate = UIApplication.shared.delegate as? ClipItAppDelegate else { return }
        appDelegate.recordingOrientationMask = nil
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .forEach(updateSupportedOrientations)
    }

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive && $0.windows.contains(where: { $0.isKeyWindow }) }
            ?? scenes.first { $0.activationState == .foregroundActive }
    }

    private static func updateSupportedOrientations(in scene: UIWindowScene) {
        scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
    }
}

@main
struct ClipItApp: App {
    @UIApplicationDelegateAdaptor(ClipItAppDelegate.self) private var appDelegate
    // MARK: - State Objects
    
    @StateObject private var recordingViewModel = RecordingViewModel()
    @StateObject private var bleViewModel = BLEViewModel()
    
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
