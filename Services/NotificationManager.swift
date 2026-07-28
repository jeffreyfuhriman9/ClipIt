//
//  NotificationManager.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 5/29/26.
//

import Foundation
import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()
    
    private init() {}
    
    /// Requests user authorization using modern Swift concurrency
    func requestPermission() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                if granted {
                    print("✅ Notification permission granted.")
                } else {
                    print("⚠️ Notification permission denied by user.")
                }
            } catch {
                print("❌ Notification permission error: \(error.localizedDescription)")
            }
        }
    }
    
    /// Schedules an instant alert notification when video processing wraps up
    func sendClipReadyNotification(clipCount: Int = 1) {
        let content = UNMutableNotificationContent()
        content.title = "ClipIt Ready! 🎬"
        content.body = clipCount > 1
            ? "Your highlights have finished processing and are ready to watch!"
            : "Your highlight has finished processing and is ready to watch!"
        content.sound = .default
        
        // Trigger 1 second from now
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to schedule notification: \(error)")
            }
        }
    }
}
