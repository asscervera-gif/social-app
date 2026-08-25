//
//  ChatListViewModel.swift
//  Social
//
//  Hallazgo real, el más grande de esta pasada: no existía NINGUNA
//  pantalla de lista de chats en toda la app — la única forma de entrar a
//  un chat era un `chatId` puntual llegado desde una notificación de
//  social aceptado (AvisosView.swift). Una vez se salía de ese chat, no
//  había forma de volver a encontrarlo salvo esperar otra notificación.
//  `chats` no tiene columna de "último mensaje" — se resuelve con una
//  consulta aparte por chat, mismo criterio que el nombre de oponente en
//  DuelHistoryViewModel.swift (sin join embebido, sin adivinar una FK sin
//  poder probarla). Equivalente de ChatListViewModel.kt.
//

import Foundation
import Supabase

struct ChatListEntry: Identifiable {
    let id: UUID
    let chat: Chat
    let otherName: String
    // Hallazgo real, comparado con WhatsApp/Instagram/Messenger: la lista
    // de chats solo mostraba el nombre de la otra persona, nunca su
    // avatar -- el identificador visual principal de cualquier lista de
    // conversaciones. Equivalente de ChatListEntry.otherAvatarConfig (Kotlin).
    let otherAvatarConfig: [String: String]?
    let lastMessage: String?
    let lastActivity: String
}

@MainActor
final class ChatListViewModel: ObservableObject {
    @Published var chats: [ChatListEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var channel: RealtimeChannelV2?

    /// Sin esto, un chat nuevo no aparecía hasta salir y volver a entrar a
    /// "Tus chats" — mismo criterio "en vivo" ya aplicado a Avisos/Chat.
    /// Equivalente de ChatListViewModel.kt.start().
    func start() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        await load()
        await subscribeToRealtime(userID: userID)
    }

    func stop() async {
        await channel?.unsubscribe()
        channel = nil
    }

    private func subscribeToRealtime(userID: UUID) async {
        let client = SupabaseManager.shared.client
        let ch = client.channel("chat-list-\(userID.uuidString)")

        let insertsA = ch.postgresChange(
            InsertAction.self, schema: "public", table: "chats",
            filter: "user_a_id=eq.\(userID.uuidString)"
        )
        let insertsB = ch.postgresChange(
            InsertAction.self, schema: "public", table: "chats",
            filter: "user_b_id=eq.\(userID.uuidString)"
        )

        channel = ch
        await ch.subscribe()

        Task {
            for await _ in insertsA { await load() }
        }
        Task {
            for await _ in insertsB { await load() }
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            // Hallazgo real: la lista de chats seguía mostrando
            // conversaciones con gente que has bloqueado — el envío de
            // mensajes ya está bloqueado en el servidor
            // (0013_block_enforcement_chat.sql), pero el chat en sí
            // seguía apareciendo en la lista, algo que ninguna app de
            // mensajería grande hace. Mismo hallazgo y mismo fix ya
            // aplicados en la versión Kotlin equivalente.
            struct BlockRow: Decodable { let blocked_id: UUID }
            var blockedIDs: Set<UUID> = []
            if let blockRows: [BlockRow] = try? await SupabaseManager.shared.client
                .from("blocks")
                .select()
                .execute()
                .value {
                blockedIDs = Set(blockRows.map { $0.blocked_id })
            }

            // Hallazgo real: sin límite, a diferencia de la convención
            // del resto del proyecto (mismo patrón corregido en
            // ChatViewModel.loadHistory() esta pasada).
            let allChats: [Chat] = try await SupabaseManager.shared.client
                .from("chats")
                .select()
                .or("user_a_id.eq.\(userID),user_b_id.eq.\(userID)")
                .limit(200)
                .execute()
                .value
            let myChats = allChats.filter {
                let otherID = $0.userAID == userID ? $0.userBID : $0.userAID
                return !blockedIDs.contains(otherID)
            }

            // Hallazgo real: la lista no ordenaba por actividad reciente,
            // comparado con cualquier app de mensajería (WhatsApp/Instagram
            // DMs siempre muestran el chat más reciente arriba) — se
            // quedaba en el orden por defecto de la base de datos.
            var entries: [ChatListEntry] = []
            for chat in myChats {
                let otherID = chat.userAID == userID ? chat.userBID : chat.userAID
                let otherProfile = await otherProfileInfo(id: otherID)
                let last = await lastMessage(chatID: chat.id)
                entries.append(ChatListEntry(
                    id: chat.id, chat: chat,
                    otherName: otherProfile?.display_name ?? "Perfil",
                    otherAvatarConfig: otherProfile?.avatar_config,
                    lastMessage: last?.body, lastActivity: last?.created_at ?? chat.createdAt
                ))
            }
            chats = entries.sorted { $0.lastActivity > $1.lastActivity }
        } catch {
            errorMessage = "No se pudieron cargar tus chats."
        }
    }

    private struct NameRow: Decodable {
        let display_name: String
        let avatar_config: [String: String]?
    }

    private func otherProfileInfo(id: UUID) async -> NameRow? {
        try? await SupabaseManager.shared.client
            .from("profiles")
            .select("display_name,avatar_config")
            .eq("id", value: id)
            .single()
            .execute()
            .value
    }

    private struct LastMessageRow: Decodable {
        let body: String?
        let created_at: String
    }

    private func lastMessage(chatID: UUID) async -> LastMessageRow? {
        try? await SupabaseManager.shared.client
            .from("messages")
            .select("body,created_at")
            .eq("chat_id", value: chatID)
            .order("created_at", ascending: false)
            .limit(1)
            .single()
            .execute()
            .value
    }
}
