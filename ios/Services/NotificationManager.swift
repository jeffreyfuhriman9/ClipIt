//
//  NotificationManager.swift
//  Clipit
//

import Foundation
import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()
    static let notificationsEnabledDefaultsKey = "clipItNotificationsEnabled"

    private let legacyAutoDeleteNotificationsEnabledKey = "originalVideoDeletionNotificationsEnabled"
    private let deletionReminderPrefix = "original-video-delete-reminder-"

    private init() {}

    /// Keeps the previous auto-delete preference when upgrading to the
    /// app-wide notifications setting.
    var notificationsEnabled: Bool {
        migrateLegacyNotificationPreferenceIfNeeded()
        return UserDefaults.standard.bool(forKey: Self.notificationsEnabledDefaultsKey)
    }

    func migrateLegacyNotificationPreferenceIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.notificationsEnabledDefaultsKey) == nil else { return }

        if defaults.bool(forKey: legacyAutoDeleteNotificationsEnabledKey) {
            defaults.set(true, forKey: Self.notificationsEnabledDefaultsKey)
        }
    }

    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            print("❌ Notification permission error: \(error.localizedDescription)")
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    /// Reconciles the pending 8-hour warning notifications against the current sessions.
    func syncOriginalVideoDeletionReminders(sessions: [Session], enabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let existingReminderIDs = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(deletionReminderPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: existingReminderIDs)

        guard enabled else { return }
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else { return }

        let now = Date()
        for session in sessions {
            guard session.fullVideoURL != nil,
                  !session.originalVideoAutoDeleteDisabled,
                  let deletionDate = session.originalVideoDeletionDate else { continue }

            let reminderDate = deletionDate.addingTimeInterval(-8 * 60 * 60)
            // If the 8-hour point has already passed, don't send a misleading late reminder.
            guard reminderDate.timeIntervalSince(now) >= 1 else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Original Video Auto-Delete Reminder"
            content.body = "Your raw footage: \(session.name) is going to auto delete in 8 hours. Make sure any edits are made to your highlights!"
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: reminderDate.timeIntervalSince(now),
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: deletionReminderPrefix + session.id.uuidString,
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
            } catch {
                print("❌ Failed to schedule original-video reminder: \(error.localizedDescription)")
            }
        }
    }

    /// Schedules an instant alert notification when video processing wraps up.
    func sendClipReadyNotification(clipCount: Int = 1) {
        guard notificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "ClipIt Ready! 🎬"
        content.body = clipCount > 1
            ? "Your highlights have finished processing and are ready to watch!"
            : "Your highlight has finished processing and is ready to watch!"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("❌ Failed to schedule notification: \(error)")
            }
        }
    }
}
