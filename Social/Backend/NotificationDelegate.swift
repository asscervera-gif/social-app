//
//  NotificationDelegate.swift
//  Social
//
//  Hasta esta pasada no existía ningún UNUserNotificationCenterDelegate, así
//  que iOS aplicaba el comportamiento por defecto: SIN delegado, un aviso
//  local no se presenta en absoluto (ni banner ni sonido) mientras la app
//  está en primer plano, y tocarlo no llevaba a ningún sitio -- mismo hueco
//  que LocalNotifier.kt en Android (ver MainActivity.kt.EXTRA_OPEN_TAB),
//  encontrado comparando con Instagram/TikTok/Snapchat.
//

import Foundation
import UserNotifications

extension Notification.Name {
    static let openAvisosTab = Notification.Name("openAvisosTab")
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    /// Sin esto, un aviso local con la app en primer plano no se muestra
    /// nunca (comportamiento por defecto de iOS sin delegado) -- a
    /// diferencia de Android, donde NotificationCompat sí se muestra en
    /// primer plano salvo que se suprima explícitamente.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    /// Al tocar el aviso, abre la pestaña Avisos -- mismo criterio que
    /// EXTRA_OPEN_TAB en Android, con NotificationCenter en vez de un
    /// Intent porque no hay equivalente de Activity/PendingIntent en iOS.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.content.userInfo["open_tab"] as? String == "avisos" {
            NotificationCenter.default.post(name: .openAvisosTab, object: nil)
        }
        completionHandler()
    }
}
