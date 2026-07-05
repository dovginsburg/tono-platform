// NotificationManager.swift
// Daily re-engagement nudge. Fires at 9 pm on any day the user hasn't run Coach.
//
// Contract:
//   • requestPermission() — call once from the main app after onboarding.
//   • recordCoachSession() — call after every successful Coach run (from the
//     keyboard extension or host app). Reschedules the nudge for tomorrow
//     so tonight's notification is cancelled.
//   • ensureNudgeScheduled() — call on UIApplication.didBecomeActive from the
//     host app. Schedules a nudge for tonight if none is pending and the user
//     hasn't coached today.
//
// NOTE: requestPermission() must be called from the main app target, not the
// keyboard extension — the authorization dialog requires the main app.
// The scheduling/cancellation calls work from either target.

import Foundation
import UserNotifications

public final class NotificationManager: @unchecked Sendable {
    public static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()

    public func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            guard granted else { return }
            // Schedule first nudge for tomorrow so the user isn't immediately pinged.
            DispatchQueue.main.async { self?.scheduleNudge(daysFromNow: 1) }
        }
    }

    /// Call after every successful Coach session. Removes tonight's pending nudge
    /// and schedules one for tomorrow, so the user only gets a ping on idle days.
    public func recordCoachSession() {
        center.removePendingNotificationRequests(withIdentifiers: ["tono.daily"])
        scheduleNudge(daysFromNow: 1)
        let today = isoDay(from: Date())
        SharedStore.defaults.set(today, forKey: SharedKeys.lastCoachDate)
    }

    /// Idempotent. Schedule a nudge for tonight if the user hasn't coached today
    /// and there's no pending request.
    public func ensureNudgeScheduled() {
        let today = isoDay(from: Date())
        let lastCoach = SharedStore.defaults.string(forKey: SharedKeys.lastCoachDate) ?? ""
        guard lastCoach != today else { return } // already coached today — nothing to do

        center.getPendingNotificationRequests { [weak self] pending in
            let hasPending = pending.contains { $0.identifier == "tono.daily" }
            if !hasPending {
                self?.scheduleNudge(daysFromNow: 0)
            }
        }
    }

    /// Schedule (or reschedule) a repeating Sunday 10 am weekly digest notification.
    public func scheduleWeeklyDigest() {
        center.removePendingNotificationRequests(withIdentifiers: ["tono.weekly"])
        let content = UNMutableNotificationContent()
        content.title = "Your weekly tone report is ready"
        content.body = "See how your communication patterns shifted this week."
        content.sound = .default

        var comps = DateComponents()
        comps.weekday = 1  // Sunday
        comps.hour = 10
        comps.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request = UNNotificationRequest(identifier: "tono.weekly", content: content, trigger: trigger)
        center.add(request)
    }

    public func cancelWeeklyDigest() {
        center.removePendingNotificationRequests(withIdentifiers: ["tono.weekly"])
    }

    // MARK: - Private

    private func scheduleNudge(daysFromNow: Int) {
        var cal = Calendar.current
        cal.timeZone = .current
        var fireDate = cal.startOfDay(for: Date())
        if daysFromNow > 0 {
            fireDate = cal.date(byAdding: .day, value: daysFromNow, to: fireDate) ?? fireDate
        }
        guard let ninepm = cal.date(bySettingHour: 21, minute: 0, second: 0, of: fireDate),
              ninepm > Date() else {
            return // already past 9 pm today — skip
        }

        let content = UNMutableNotificationContent()
        content.title = "Coach a message today?"
        content.body = "Tap Coach on any draft for an instant tone read and rewrite."
        content.sound = .default

        let components = cal.dateComponents([.year, .month, .day, .hour, .minute], from: ninepm)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: "tono.daily", content: content, trigger: trigger)
        center.add(request)
    }

    private func isoDay(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }
}
