//
//  AvisosViewModel.swift
//  Social
//
//  Notificaciones: social, follow, fight, like, solicitud de %. Suscrito a
//  Supabase Realtime (igual que ChatViewModel): sin esto, un aviso nuevo
//  solo aparecería la próxima vez que el usuario reabra la pestaña, lo cual
//  no vale para algo tan sensible al tiempo como "alguien te envió un social
//  mientras estás cerca de él ahora mismo".
//

import Foundation
import Supabase

@MainActor
final class AvisosViewModel: ObservableObject {

    struct NotificationEntry: Identifiable, Decodable {
        let id: UUID
        let kind: String
        let payload: [String: String]
        let readAt: Date?
        let createdAt: Date

        enum CodingKeys: String, CodingKey {
            case id, kind, payload
            case readAt = "read_at"
            case createdAt = "created_at"
        }
    }

    @Published var notifications: [NotificationEntry] = []
    @Published var selected: NotificationEntry?
    @Published var errorMessage: String?
    // Hallazgo real, mismo hueco raíz ya cerrado en el feed/comentarios/
    // chats/duelos: Avisos mostraba un icono genérico por tipo, pero nunca
    // el avatar de quién disparó el aviso -- comparado con la pestaña
    // "Actividad" de Instagram, que siempre muestra la foto de perfil del
    // actor como elemento visual principal de cada fila.
    @Published var actorProfiles: [UUID: Profile] = [:]

    private var channel: RealtimeChannelV2?
    private var currentUserID: UUID?

    func start() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        currentUserID = userID
        await load()
        await subscribeToRealtime(userID: userID)
    }

    func stop() async {
        await channel?.unsubscribe()
        channel = nil
    }

    func load() async {
        do {
            let loaded: [NotificationEntry] = try await SupabaseManager.shared.client
                .from("notifications")
                .select()
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value
            notifications = loaded
            let actorIDs = loaded.compactMap { $0.payload["actor_id"].flatMap { UUID(uuidString: $0) } }
            await fetchActorProfiles(Array(Set(actorIDs)))
        } catch {
            errorMessage = "No se pudieron cargar los avisos: \(error.localizedDescription)"
        }
    }

    private func fetchActorProfiles(_ actorIDs: [UUID]) async {
        let missing = actorIDs.filter { actorProfiles[$0] == nil }
        guard !missing.isEmpty else { return }
        if let fetched: [Profile] = try? await SupabaseManager.shared.client
            .from("profiles")
            .select()
            .in("id", values: missing)
            .execute()
            .value {
            for profile in fetched { actorProfiles[profile.id] = profile }
        }
    }

    /// Escucha inserciones nuevas en `notifications` para este usuario y las
    /// añade en vivo, sin esperar a un pull-to-refresh manual.
    private func subscribeToRealtime(userID: UUID) async {
        let client = SupabaseManager.shared.client
        let ch = client.channel("notifications-\(userID.uuidString)")

        let inserts = ch.postgresChange(
            InsertAction.self, schema: "public", table: "notifications",
            filter: "recipient_id=eq.\(userID.uuidString)"
        )

        channel = ch
        await ch.subscribe()

        Task {
            for await change in inserts {
                if let entry = try? change.decodeRecord(as: NotificationEntry.self, decoder: JSONDecoder()) {
                    notifications.insert(entry, at: 0)
                    if let actorID = entry.payload["actor_id"].flatMap({ UUID(uuidString: $0) }) {
                        await fetchActorProfiles([actorID])
                    }
                }
            }
        }
        // La notificación local del sistema ahora la publica
        // `NotificationsBadgeViewModel` (arranca desde `RootTabView.swift`
        // al abrir la app, en cualquier pestaña) — publicarla también aquí
        // duplicaría el aviso cuando ambos canales están vivos a la vez
        // (el usuario tiene la pestaña Avisos abierta). Mismo criterio que
        // Android: solo `NotificationsBadgeViewModel.kt` llama a
        // `LocalNotifier`, `AvisosViewModel.kt` nunca lo hizo.
    }

    func markRead(_ entry: NotificationEntry) async {
        // Actualización optimista: no esperamos al round-trip de red para
        // que el punto rojo desaparezca, coherente con el resto de la app.
        if let index = notifications.firstIndex(where: { $0.id == entry.id }) {
            notifications[index] = NotificationEntry(
                id: entry.id, kind: entry.kind, payload: entry.payload,
                readAt: Date(), createdAt: entry.createdAt
            )
        }
        do {
            try await SupabaseManager.shared.client
                .from("notifications")
                .update(["read_at": ISO8601DateFormatter().string(from: Date())])
                .eq("id", value: entry.id)
                .execute()
        } catch {
            errorMessage = "No se pudo marcar como leído."
        }
    }

    /// Hallazgo real, comparado con Gmail/Instagram/Twitter -- cualquier
    /// lista de notificaciones grande deja marcar todo como leído de una
    /// vez, no solo aviso por aviso. `notifications_update` (0002_rls.sql)
    /// es por fila (`recipient_id = auth.uid()`), sin límite de cuántas
    /// filas puede tocar una sola sentencia -- un UPDATE real, no N
    /// llamadas. Equivalente de AvisosViewModel.kt.markAllRead().
    func markAllRead() async {
        guard notifications.contains(where: { $0.readAt == nil }) else { return }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        let now = Date()
        for index in notifications.indices where notifications[index].readAt == nil {
            notifications[index] = NotificationEntry(
                id: notifications[index].id, kind: notifications[index].kind, payload: notifications[index].payload,
                readAt: now, createdAt: notifications[index].createdAt
            )
        }
        do {
            try await SupabaseManager.shared.client
                .from("notifications")
                .update(["read_at": ISO8601DateFormatter().string(from: now)])
                .eq("recipient_id", value: userID)
                .execute()
        } catch {
            errorMessage = "No se pudieron marcar todos los avisos como leídos."
        }
    }
}

extension AvisosViewModel.NotificationEntry {
    var icon: String {
        switch kind {
        case "social": return "person.2.fill"
        case "follow": return "person.badge.plus"
        case "fight": return "bolt.fill"
        case "like": return "heart.fill"
        case "compat_request": return "percent"
        // Hallazgo real: aceptar un social o una solicitud de
        // compatibilidad no notificaba nunca a quien la pidió -- ver
        // 0046_notify_accepted.sql.
        case "social_accepted": return "checkmark.circle.fill"
        case "compat_accepted": return "percent"
        // Hallazgo real, el hueco de mensajería más grande de la sesión:
        // ningún mensaje nuevo generaba nunca un aviso -- ver
        // 0047_message_notify_mute.sql.
        case "message": return "message.fill"
        default: return "bell"
        }
    }

    var title: String {
        switch kind {
        case "social": return "Nueva solicitud de social"
        case "follow": return "Nuevo seguidor"
        case "fight": return "Duelo completado"
        case "like": return "Le gustó tu publicación"
        case "compat_request": return "Quiere ver tu compatibilidad"
        case "social_accepted": return "Aceptó tu social"
        case "compat_accepted": return "Compartió su compatibilidad contigo"
        case "message": return "Nuevo mensaje"
        default: return "Notificación"
        }
    }
}
