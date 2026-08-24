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
            notifications = try await SupabaseManager.shared.client
                .from("notifications")
                .select()
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value
        } catch {
            errorMessage = "No se pudieron cargar los avisos: \(error.localizedDescription)"
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
}

extension AvisosViewModel.NotificationEntry {
    var icon: String {
        switch kind {
        case "social": return "person.2.fill"
        case "follow": return "person.badge.plus"
        case "fight": return "bolt.fill"
        case "like": return "heart.fill"
        case "compat_request": return "percent"
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
        default: return "Notificación"
        }
    }
}
