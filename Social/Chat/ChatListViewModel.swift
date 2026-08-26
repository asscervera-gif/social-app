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
    // Hallazgo real, comparado con WhatsApp/Instagram/Messenger: no había
    // ninguna forma de quitar una conversación de "Tus chats" -- ver
    // 0044_chats_hide.sql. Necesario para saber qué columna
    // (hidden_by_a/hidden_by_b) me corresponde a MÍ en este chat.
    let iAmUserA: Bool
    // Hallazgo real, comparado con WhatsApp/Instagram/Messenger: no había
    // ninguna forma de silenciar una conversación sin salir ni bloquear --
    // ver 0047_message_notify_mute.sql.
    let isMutedForMe: Bool
    // Hallazgo real, comparado con WhatsApp/Instagram/Messenger: "Tus
    // chats" no distinguía visualmente qué conversaciones tenían mensajes
    // sin leer.
    let hasUnread: Bool
    // Fijar un chat arriba de la lista, comparado con
    // WhatsApp/Telegram/Messenger -- ver 0081_pin_chats.sql.
    let isPinnedForMe: Bool
    // Marcar un chat como no leído manualmente, comparado con WhatsApp/
    // Telegram/Messenger -- ver 0088_mark_chat_unread.sql. Se guarda
    // aparte de `hasUnread` (que ya combina esto con el estado real de
    // lectura) porque el botón de la UI necesita saber CUÁL de los dos
    // motivos aplica para decidir su propia etiqueta.
    let markedUnreadForMe: Bool
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
                let hiddenForMe = $0.userAID == userID ? $0.hiddenByA : $0.hiddenByB
                return !blockedIDs.contains(otherID) && !hiddenForMe
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
                // Marcar como no leído manualmente, comparado con
                // WhatsApp/Telegram/Messenger -- capa personal por
                // encima del estado real de lectura del último mensaje
                // (0088_mark_chat_unread.sql).
                let markedUnreadForMe = chat.userAID == userID ? chat.markedUnreadByA : chat.markedUnreadByB
                entries.append(ChatListEntry(
                    id: chat.id, chat: chat,
                    otherName: otherProfile?.display_name ?? "Perfil",
                    otherAvatarConfig: otherProfile?.avatar_config,
                    lastMessage: last?.body, lastActivity: last?.created_at ?? chat.createdAt,
                    iAmUserA: chat.userAID == userID,
                    isMutedForMe: chat.userAID == userID ? chat.mutedByA : chat.mutedByB,
                    hasUnread: (last != nil && last!.sender_id != userID && last!.read_at == nil) || markedUnreadForMe,
                    isPinnedForMe: chat.userAID == userID ? chat.pinnedByA : chat.pinnedByB,
                    markedUnreadForMe: markedUnreadForMe
                ))
            }
            // Fijado primero (mismo criterio que WhatsApp/Telegram),
            // actividad reciente dentro de cada grupo.
            chats = entries.sorted {
                if $0.isPinnedForMe != $1.isPinnedForMe { return $0.isPinnedForMe }
                return $0.lastActivity > $1.lastActivity
            }
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
        // Hallazgo real, comparado con WhatsApp/Instagram/Messenger: "Tus
        // chats" no distinguía visualmente qué conversaciones tenían
        // mensajes sin leer -- solo el badge total de la pestaña Avisos,
        // nunca por chat. markMessagesRead() (ChatViewModel) marca TODO
        // el historial pendiente de una vez al abrir el chat (no hay
        // marcado incremental mensaje a mensaje), así que el estado de
        // lectura del ÚLTIMO mensaje ya equivale a "¿hay algo sin leer en
        // este chat?" -- sin necesitar una segunda consulta.
        let sender_id: UUID
        let read_at: Date?
    }

    private func lastMessage(chatID: UUID) async -> LastMessageRow? {
        try? await SupabaseManager.shared.client
            .from("messages")
            .select("body,created_at,sender_id,read_at")
            .eq("chat_id", value: chatID)
            .order("created_at", ascending: false)
            .limit(1)
            .single()
            .execute()
            .value
    }

    /// "Ocultar conversación" -- solo afecta a MI copia (columna
    /// hidden_by_a/hidden_by_b según corresponda), nunca a la de la otra
    /// persona (protect_chat_hidden_flags, 0044_chats_hide.sql, lo
    /// garantiza también del lado del servidor). Un mensaje nuevo real la
    /// restaura sola.
    func hideChat(_ entry: ChatListEntry) {
        chats.removeAll { $0.id == entry.id }
        Task {
            do {
                if entry.iAmUserA {
                    try await SupabaseManager.shared.client
                        .from("chats")
                        .update(["hidden_by_a": true])
                        .eq("id", value: entry.chat.id)
                        .execute()
                } else {
                    try await SupabaseManager.shared.client
                        .from("chats")
                        .update(["hidden_by_b": true])
                        .eq("id", value: entry.chat.id)
                        .execute()
                }
            } catch {
                errorMessage = "No se pudo ocultar la conversación."
                await load()
            }
        }
    }

    /// Silenciar con una duración real elegida (8 horas / 1 semana /
    /// siempre), comparado con WhatsApp/Telegram -- antes era un simple
    /// interruptor sin expiración (ver 0082_mute_until.sql). `until` en
    /// nil significa "para siempre", mismo criterio que
    /// `profiles.banned_until`. Solo afecta a MI copia (columnas
    /// muted_by_a/muted_until_a o muted_by_b/muted_until_b según
    /// corresponda), nunca a la de la otra persona
    /// (protect_chat_muted_flags lo garantiza también del lado del
    /// servidor). Dos `.update()` seguidos, no uno con ambas columnas
    /// mezcladas -- un diccionario de Swift necesita un tipo de valor
    /// homogéneo (Bool por un lado, String? por otro), mismo motivo por
    /// el que el resto de esta pantalla nunca mezcla tipos en un solo
    /// `.update()`. Equivalente de ChatListViewModel.kt.muteChatFor().
    func muteChatFor(_ entry: ChatListEntry, until: Date?) {
        if let index = chats.firstIndex(where: { $0.id == entry.id }) {
            chats[index] = ChatListEntry(
                id: entry.id, chat: entry.chat, otherName: entry.otherName,
                otherAvatarConfig: entry.otherAvatarConfig, lastMessage: entry.lastMessage,
                lastActivity: entry.lastActivity, iAmUserA: entry.iAmUserA, isMutedForMe: true,
                hasUnread: entry.hasUnread, isPinnedForMe: entry.isPinnedForMe,
                markedUnreadForMe: entry.markedUnreadForMe
            )
        }
        let untilString: String? = until.map { ISO8601DateFormatter().string(from: $0) }
        let mutedColumn = entry.iAmUserA ? "muted_by_a" : "muted_by_b"
        let untilColumn = entry.iAmUserA ? "muted_until_a" : "muted_until_b"
        Task {
            do {
                try await SupabaseManager.shared.client
                    .from("chats")
                    .update([mutedColumn: true])
                    .eq("id", value: entry.chat.id)
                    .execute()
                try await SupabaseManager.shared.client
                    .from("chats")
                    .update([untilColumn: untilString])
                    .eq("id", value: entry.chat.id)
                    .execute()
            } catch {
                errorMessage = "No se pudo silenciar la conversación."
                await load()
            }
        }
    }

    /// Activar (quitar el silencio) -- limpia también la fecha de
    /// expiración para no dejar estado colgado.
    func unmuteChat(_ entry: ChatListEntry) {
        if let index = chats.firstIndex(where: { $0.id == entry.id }) {
            chats[index] = ChatListEntry(
                id: entry.id, chat: entry.chat, otherName: entry.otherName,
                otherAvatarConfig: entry.otherAvatarConfig, lastMessage: entry.lastMessage,
                lastActivity: entry.lastActivity, iAmUserA: entry.iAmUserA, isMutedForMe: false,
                hasUnread: entry.hasUnread, isPinnedForMe: entry.isPinnedForMe,
                markedUnreadForMe: entry.markedUnreadForMe
            )
        }
        let mutedColumn = entry.iAmUserA ? "muted_by_a" : "muted_by_b"
        let untilColumn = entry.iAmUserA ? "muted_until_a" : "muted_until_b"
        let untilString: String? = nil
        Task {
            do {
                try await SupabaseManager.shared.client
                    .from("chats")
                    .update([mutedColumn: false])
                    .eq("id", value: entry.chat.id)
                    .execute()
                try await SupabaseManager.shared.client
                    .from("chats")
                    .update([untilColumn: untilString])
                    .eq("id", value: entry.chat.id)
                    .execute()
            } catch {
                errorMessage = "No se pudo activar la conversación."
                await load()
            }
        }
    }

    /// Fijar/desfijar -- solo afecta a MI copia (columna
    /// pinned_by_a/pinned_by_b según corresponda), nunca a la de la otra
    /// persona (protect_chat_pinned_flags, 0081_pin_chats.sql, lo
    /// garantiza también del lado del servidor). A diferencia de ocultar,
    /// un chat fijado NO se desfija solo al llegar un mensaje -- mismo
    /// criterio que WhatsApp/Telegram. Equivalente de
    /// ChatListViewModel.kt.togglePin().
    func togglePin(_ entry: ChatListEntry) {
        let newValue = !entry.isPinnedForMe
        if let index = chats.firstIndex(where: { $0.id == entry.id }) {
            chats[index] = ChatListEntry(
                id: entry.id, chat: entry.chat, otherName: entry.otherName,
                otherAvatarConfig: entry.otherAvatarConfig, lastMessage: entry.lastMessage,
                lastActivity: entry.lastActivity, iAmUserA: entry.iAmUserA, isMutedForMe: entry.isMutedForMe,
                hasUnread: entry.hasUnread, isPinnedForMe: newValue,
                markedUnreadForMe: entry.markedUnreadForMe
            )
        }
        chats.sort {
            if $0.isPinnedForMe != $1.isPinnedForMe { return $0.isPinnedForMe }
            return $0.lastActivity > $1.lastActivity
        }
        Task {
            do {
                if entry.iAmUserA {
                    try await SupabaseManager.shared.client
                        .from("chats")
                        .update(["pinned_by_a": newValue])
                        .eq("id", value: entry.chat.id)
                        .execute()
                } else {
                    try await SupabaseManager.shared.client
                        .from("chats")
                        .update(["pinned_by_b": newValue])
                        .eq("id", value: entry.chat.id)
                        .execute()
                }
            } catch {
                errorMessage = "No se pudo fijar la conversación."
                await load()
            }
        }
    }

    /// Marcar/desmarcar un chat como no leído manualmente, comparado con
    /// WhatsApp/Telegram/Messenger -- capa puramente personal por encima
    /// del estado real de lectura del último mensaje, NUNCA toca
    /// `messages.read_at` (0088_mark_chat_unread.sql, lo garantiza
    /// también del lado del servidor). Se limpia sola al volver a abrir
    /// el chat de verdad -- ver ChatViewModel.markMessagesRead(). Sin
    /// actualización optimista de `hasUnread` a propósito, mismo motivo
    /// que ChatListViewModel.kt.toggleMarkUnread(): combina dos fuentes
    /// que no se guardan por separado aquí, `load()` tras escribir es
    /// simple y siempre correcto. Equivalente de
    /// ChatListViewModel.kt.toggleMarkUnread().
    func toggleMarkUnread(_ entry: ChatListEntry) {
        let newValue = !entry.markedUnreadForMe
        if let index = chats.firstIndex(where: { $0.id == entry.id }) {
            chats[index] = ChatListEntry(
                id: entry.id, chat: entry.chat, otherName: entry.otherName,
                otherAvatarConfig: entry.otherAvatarConfig, lastMessage: entry.lastMessage,
                lastActivity: entry.lastActivity, iAmUserA: entry.iAmUserA, isMutedForMe: entry.isMutedForMe,
                hasUnread: entry.hasUnread, isPinnedForMe: entry.isPinnedForMe,
                markedUnreadForMe: newValue
            )
        }
        Task {
            do {
                if entry.iAmUserA {
                    try await SupabaseManager.shared.client
                        .from("chats")
                        .update(["marked_unread_by_a": newValue])
                        .eq("id", value: entry.chat.id)
                        .execute()
                } else {
                    try await SupabaseManager.shared.client
                        .from("chats")
                        .update(["marked_unread_by_b": newValue])
                        .eq("id", value: entry.chat.id)
                        .execute()
                }
            } catch {
                errorMessage = "No se pudo cambiar el estado de leído."
            }
            await load()
        }
    }
}
