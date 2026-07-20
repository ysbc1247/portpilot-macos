import Foundation
import UserNotifications

protocol PortNotifying: Sendable {
    func requestAuthorization() async throws -> Bool
    func notify(title: String, body: String) async
}

struct LocalNotificationService: PortNotifying, Sendable {
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func notify(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

