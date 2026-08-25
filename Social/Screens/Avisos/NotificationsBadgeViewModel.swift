//
//  NotificationsBadgeViewModel.swift
//  Social
//
//  Contador de no leídas para el badge de la pestaña Avisos — mismo
//  hallazgo que NotificationsBadgeViewModel.kt: la pestaña nunca mostraba
//  si había avisos nuevos sin entrar a mirar. Suscripción realtime igual
//  que AvisosViewModel.swift.
//

import Foundation
import Supabase
import UserNotifications

@MainActor
final class NotificationsBadgeViewModel: ObservableObject {
    // Hallazgo real: se pedía permiso de `.badge` pero nada mantenía
    // sincronizado el número rojo del icono de la app con el contador
    // real — quedaba desfasado en cuanto se marcaba algo como leído sin
    // que llegara una notificación nueva de por medio (WhatsApp/
    // Instagram/Gmail siempre lo mantienen al día). `didSet` centraliza
    // la sincronización en un solo sitio, tanto si el cambio viene de
    // `refresh()` como del contador optimista al llegar un aviso nuevo.
    @Published var unreadCount: Int = 0 {
        didSet {
            UNUserNotificationCenter.current().setBadgeCount(unreadCount)
        }
    }

    private var channel: RealtimeChannelV2?

    struct NotificationRow: Decodable {
        let id: UUID
        let readAt: Date?
        enum CodingKeys: String, CodingKey {
            case id
            case readAt = "read_at"
        }
    }

    func start() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        // Hallazgo real: `AvisosViewModel.postLocalNotification` (pasada
        // anterior) solo sonaba mientras la pestaña Avisos había llegado a
        // montarse — a diferencia de Android (`NotificationsBadgeViewModel.kt`
        // vive en `RootTabView.kt`, fuera de cualquier pestaña, así que
        // suena en toda la app). Este ViewModel SÍ arranca desde
        // `RootTabView.swift` (línea `.task { await notificationsBadge.start() }`,
        // en el momento en que la app abre, en cualquier pestaña) — es el
        // sitio correcto para elevar el aviso local al mismo nivel que
        // Android, cerrando la diferencia de alcance documentada en
        // LOOP_STATE.md.
        try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refresh()
        await subscribeToRealtime(userID: userID)
    }

    func stop() async {
        await channel?.unsubscribe()
        channel = nil
    }

    private func refresh() async {
        do {
            let rows: [NotificationRow] = try await SupabaseManager.shared.client
                .from("notifications")
                .select()
                .execute()
                .value
            unreadCount = rows.filter { $0.readAt == nil }.count
        } catch {
            // Sin conexión: se mantiene el último contador conocido, mismo
            // criterio que el resto de ViewModels de esta app.
        }
    }

    private func subscribeToRealtime(userID: UUID) async {
        let client = SupabaseManager.shared.client
        let ch = client.channel("notifications-badge-\(userID.uuidString)")

        let inserts = ch.postgresChange(
            InsertAction.self, schema: "public", table: "notifications",
            filter: "recipient_id=eq.\(userID.uuidString)"
        )
        let updates = ch.postgresChange(
            UpdateAction.self, schema: "public", table: "notifications",
            filter: "recipient_id=eq.\(userID.uuidString)"
        )

        channel = ch
        await ch.subscribe()

        Task {
            for await change in inserts {
                unreadCount += 1
                // `AvisosViewModel.NotificationEntry` ya tiene `kind`/
                // `title` (mismos textos que Android); se reutiliza aquí
                // en vez de duplicar el switch de textos.
                if let entry = try? change.decodeRecord(as: AvisosViewModel.NotificationEntry.self, decoder: JSONDecoder()) {
                    let content = UNMutableNotificationContent()
                    content.title = entry.title
                    // Hallazgo real, mismo tipo de bug ya corregido en
                    // LocalNotifier.kt (Android): el cuerpo del aviso nunca
                    // se rellenaba, así que el banner solo mostraba el
                    // título, sin ninguna llamada a la acción.
                    content.body = "Toca para verlo"
                    content.sound = .default
                    // Al tocar el aviso, NotificationDelegate.swift abre la
                    // pestaña Avisos -- mismo criterio que EXTRA_OPEN_TAB en
                    // Android.
                    content.userInfo = ["open_tab": "avisos"]
                    // El icono ya se sincroniza centralizadamente en el
                    // `didSet` de `unreadCount` (ver más arriba) — no
                    // hace falta duplicarlo aquí en `content.badge`.
                    let request = UNNotificationRequest(identifier: entry.id.uuidString, content: content, trigger: nil)
                    try? await UNUserNotificationCenter.current().add(request)
                }
            }
        }
        Task {
            for await _ in updates {
                await refresh()
            }
        }
    }
}
