// SPDX-License-Identifier: AGPL-3.0-only

import KhensuKit
import UserNotifications

/// Anonymous push (PLAN.md, "Push notifications"): the gateway sends a fixed
/// "New message" alert with mutable-content. This extension queues any sealed
/// packets into the CompleteUnlessOpen queue and never decrypts anything, so
/// nothing readable exists while the phone is locked.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = Self.anonymous(from: request.content)
        self.content = content

        // v0.1: devnet pushes may carry sealed packets inline (base64 strings
        // under "sealed"). Fetching from mailbox replicas comes with the network.
        if let sealed = request.content.userInfo["sealed"] as? [String] {
            let packets = sealed.compactMap { Data(base64Encoded: $0) }
            try? IncomingQueue.shared()?.append(packets)
        }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let content { contentHandler(content) }
    }

    private static func anonymous(from original: UNNotificationContent) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "khensu.nu"
        content.body = String(localized: "New message")
        content.sound = original.sound
        content.threadIdentifier = "khensu"
        return content
    }
}
