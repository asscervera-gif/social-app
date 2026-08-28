//
//  PushTokenManager.swift
//  Social
//
//  Pieza cliente que faltaba para que notify_push_on_new_notification()
//  (0041_notify_push_trigger.sql) y send-push (supabase/functions/send-push)
//  tengan un token real al que enviar -- hasta ahora device_tokens existía
//  como tabla e infraestructura de envío, pero ningún cliente escribía
//  nunca una fila en ella.
//
//  Se pide permiso y se registra solo con sesión real, desde
//  AppRootView.swift -- nunca en frío al abrir la app: pedir notificaciones
//  antes de que la persona tenga cuenta no tiene sentido y quema el único
//  aviso de permiso que iOS deja pedir sin fricción.
//

import Foundation
import UIKit
import UserNotifications

enum PushTokenManager {

    // Guardado real del último token de ESTE dispositivo, comparado con
    // Instagram/Facebook/Snapchat -- ver DevicesView.swift, que lo usa
    // para marcar "(este dispositivo)" en la lista real de
    // device_tokens (0040), sin tabla nueva.
    static private(set) var currentToken: String?

    static func requestAuthorizationAndRegister() {
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            guard granted else { return }
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// Llamado desde AppDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)
    /// con el token binario que entrega APNs.
    static func register(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        currentToken = token
        Task {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            struct DeviceTokenUpsert: Encodable {
                let profile_id: UUID
                let platform: String
                let token: String
            }
            do {
                try await SupabaseManager.shared.client
                    .from("device_tokens")
                    .upsert(
                        DeviceTokenUpsert(profile_id: userID, platform: "ios", token: token),
                        onConflict: "profile_id,platform,token"
                    )
                    .execute()
            } catch {
                // Fire-and-forget deliberado, mismo criterio que
                // AnalyticsManager.track(): un fallo de red al registrar el
                // token no debe afectar a la funcionalidad real de la app.
            }
        }
    }
}
