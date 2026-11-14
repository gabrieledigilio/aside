//
// DayReader.swift
//
// Reads what is left of today from the iPhone's calendar, and schedules the "in 10 minutes"
// reminders. Calendar entries are only read; nothing is ever written to the calendar.
//

import EventKit
import Foundation
import UserNotifications

struct CalendarEntry {
  let id: String
  let title: String
  let start: Date
  let end: Date
  let place: String
  let notes: String
}

struct Reminder {
  let id: String
  let title: String
  let start: Date
  let prep: [String]
}

final class DayReader: @unchecked Sendable {
  private let store = EKEventStore()

  /// Asks to read the calendar. iOS shows its own prompt the first time.
  func requestAccess() async -> Bool {
    do {
      return try await store.requestFullAccessToEvents()
    } catch {
      return false
    }
  }

  /// The rest of today, in order. All-day entries are left out: there is nothing to walk into.
  func upcoming() -> [CalendarEntry] {
    let now = Date()
    guard let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) else { return [] }
    let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: endOfDay, calendars: nil)
    var entries: [CalendarEntry] = []
    for event in store.events(matching: predicate) {
      guard !event.isAllDay, let start = event.startDate, let end = event.endDate, end > now else { continue }
      entries.append(
        CalendarEntry(
          id: event.eventIdentifier ?? UUID().uuidString,
          title: event.title ?? "Untitled",
          start: start,
          end: end,
          place: event.location ?? "",
          notes: event.notes ?? ""
        )
      )
    }
    entries.sort { $0.start < $1.start }
    return Array(entries.prefix(8))
  }

  /// One notification ten minutes before each event, carrying what to have ready.
  /// These fire even when Gist is closed.
  func schedule(_ reminders: [Reminder]) async {
    let center = UNUserNotificationCenter.current()
    let allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    guard allowed else { return }
    center.removeAllPendingNotificationRequests()
    for reminder in reminders {
      let wait = reminder.start.addingTimeInterval(-600).timeIntervalSinceNow
      guard wait > 5 else { continue }
      let content = UNMutableNotificationContent()
      content.title = "In 10 minutes: \(reminder.title)"
      content.body = reminder.prep.isEmpty ? "Open Aside for what to have ready." : reminder.prep.joined(separator: "\n")
      content.sound = .default
      let trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
      let request = UNNotificationRequest(identifier: "gist.brief." + reminder.id, content: content, trigger: trigger)
      try? await center.add(request)
    }
  }

  func cancelReminders() {
    UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
  }
}
