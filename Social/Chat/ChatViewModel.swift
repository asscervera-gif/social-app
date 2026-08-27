//
//  ChatViewModel.swift
//  Social
//
//  Chat en tiempo real vía Supabase Realtime, con la barra de compatibilidad
//  (0-100) actualizándose en vivo para ambos usuarios.
//

import Foundation
import Supabase

@MainActor
final class ChatViewModel: ObservableObject {

    let chatID: UUID
    private let currentUserID: UUID

    @Published var messages: [ChatMessage] = []
    @Published var compatibilityScore: Int = 50
    @Published var draft: String = ""
    @Published var suggestedActivity: String?
    @Published var errorMessage: String?
    @Published var opponentID: UUID?
    // Recibo de lectura real ("Leído ✓✓"), comparado con WhatsApp/
    // Instagram/Messenger -- mismo criterio recíproco real que esas apps:
    // si CUALQUIERA de los dos (yo o la otra persona) desactivó su propio
    // recibo, no se pinta "Leído" para ninguno de los dos lados, aunque
    // `read_at` siga marcándose igual que siempre por debajo (sigue
    // haciendo falta para el propio recuento de "no leídos" del
    // destinatario, 0088). Ver 0091_read_receipts_toggle.sql. Equivalente
    // de ChatViewModel.kt.showReadReceipts.
    @Published var showReadReceipts = true
    // Paginación hacia atrás -- hueco real documentado desde que loadHistory()
    // se limitó a los últimos 100 mensajes (ver comentario ahí): sin esto, un
    // chat con más de 100 mensajes perdía silenciosamente todo lo anterior,
    // sin forma de volver a verlo. Equivalente de
    // ChatViewModel.kt.loadOlderMessages().
    @Published var hasMoreHistory = false
    @Published var isLoadingOlder = false
    private let olderPageSize = 50
    // Responder a un mensaje concreto (cita), comparado con
    // WhatsApp/Telegram/iMessage/Instagram DM -- mensaje real que se está
    // citando ahora mismo en el compositor, ver 0102_message_reply.sql.
    // Equivalente de ChatViewModel.kt.replyingTo.
    @Published var replyingTo: ChatMessage?
    // Última pieza real de "chat funcional con fotos, voz, reacciones,
    // read receipts" alcanzable sin infraestructura mayor — solo queda voz
    // (grabación nativa, alcance propio, documentado aparte).
    @Published var reactions: [UUID: [MessageReaction]] = [:]

    struct MessageReaction: Codable, Identifiable {
        let id: UUID
        let message_id: UUID
        let user_id: UUID
        let emoji: String
    }

    // Enviar una publicación a un chat real (0069_message_shared_post.sql),
    // comparado con Instagram/TikTok/Twitter/Snapchat -- vista previa real
    // (miniatura + caption + autor) de la publicación compartida en un
    // mensaje, cargada por lotes a partir de los sharedPostID presentes en
    // los mensajes ya cargados, mismo patrón que loadReactions().
    @Published var sharedPosts: [UUID: Post] = [:]
    @Published var sharedPostAuthors: [UUID: Profile] = [:]

    private func loadSharedPosts(_ messages: [ChatMessage]) async {
        let postIDs = Array(Set(messages.compactMap { $0.sharedPostID }.filter { sharedPosts[$0] == nil }))
        guard !postIDs.isEmpty else { return }
        guard let posts: [Post] = try? await SupabaseManager.shared.client
            .from("posts")
            .select()
            .in("id", values: postIDs)
            .execute()
            .value else { return }
        for post in posts { sharedPosts[post.id] = post }
        let authorIDs = Array(Set(posts.map { $0.authorID }))
        guard !authorIDs.isEmpty else { return }
        if let authors: [Profile] = try? await SupabaseManager.shared.client
            .from("profiles")
            .select()
            .in("id", values: authorIDs)
            .execute()
            .value {
            for author in authors { sharedPostAuthors[author.id] = author }
        }
    }

    // Responder a una historia real (0071_message_story_reply.sql),
    // comparado con Instagram/WhatsApp Status/Snapchat -- vista previa
    // real (miniatura) de la historia respondida en un mensaje, cargada
    // por lotes, mismo patrón exacto que loadSharedPosts() de arriba. Sin
    // autor propio: en un chat 1:1, la historia referenciada es siempre
    // de uno de los dos participantes ya conocidos, así que el texto de
    // la burbuja se decide comparando message.senderID con el remitente,
    // sin otra consulta.
    struct StoryPreview: Decodable {
        let id: UUID
        let media_url: String
    }
    @Published var storyPreviews: [UUID: StoryPreview] = [:]

    private func loadStoryPreviews(_ messages: [ChatMessage]) async {
        let storyIDs = Array(Set(messages.compactMap { $0.storyID }.filter { storyPreviews[$0] == nil }))
        guard !storyIDs.isEmpty else { return }
        // Historia real ya caducada/borrada (stories_select filtra
        // expires_at > now(), 0002_rls.sql) -- comportamiento CORRECTO y
        // esperado, no un fallo: el mensaje sigue mostrándose, solo sin
        // la vista previa de la historia ya no disponible.
        guard let stories: [StoryPreview] = try? await SupabaseManager.shared.client
            .from("stories")
            .select("id,media_url")
            .in("id", values: storyIDs)
            .execute()
            .value else { return }
        for story in stories { storyPreviews[story.id] = story }
    }

    private var channel: RealtimeChannelV2?

    // "Escribiendo..." — comparado con WhatsApp/Instagram DM, no había
    // ninguna señal de que la otra persona está escribiendo. Mismo
    // criterio ya construido en la versión Kotlin equivalente
    // (ChatViewModel.kt.notifyTyping/isOpponentTyping): Broadcast de
    // Realtime (efímero, sin tabla ni columna nueva) sobre el mismo canal
    // `chat-{chatID}` ya abierto para mensajes/reacciones.
    @Published var isOpponentTyping = false
    private var typingClearTask: Task<Void, Never>?
    private var typingSendTask: Task<Void, Never>?

    // "En línea" — mismo criterio ya construido en la versión Kotlin
    // equivalente (ChatViewModel.kt.isOpponentOnline): Presence de
    // Realtime sobre el mismo canal `chat-{chatID}`. "En línea" significa
    // "tiene esta conversación abierta", no "tiene la app abierta en
    // algún sitio" — alcance deliberadamente acotado al chat.
    @Published var isOpponentOnline = false
    private var onlineUserIDs = Set<String>()

    init(chatID: UUID, currentUserID: UUID) {
        self.chatID = chatID
        self.currentUserID = currentUserID
    }

    func start() async {
        await loadHistory()
        await subscribeToRealtime()
        await markMessagesRead()
        await markMessageNotificationsRead()
        await loadReactions()
        await loadStarred()
    }

    // Mensajes destacados reales, comparado con WhatsApp
    // (0087_starred_messages.sql) -- totalmente privado, sobre CUALQUIER
    // mensaje (propio o ajeno). Equivalente de
    // ChatViewModel.kt.starredMessageIds.
    @Published var starredMessageIDs: Set<UUID> = []

    private func loadStarred() async {
        struct StarredIDRow: Decodable { let message_id: UUID }
        let messageIDs = messages.map { $0.id }
        guard !messageIDs.isEmpty else { return }
        if let rows: [StarredIDRow] = try? await SupabaseManager.shared.client
            .from("starred_messages")
            .select("message_id")
            .eq("user_id", value: currentUserID)
            .in("message_id", values: messageIDs)
            .execute()
            .value {
            starredMessageIDs = Set(rows.map { $0.message_id })
        }
    }

    private struct NewStarredMessage: Encodable {
        let user_id: UUID
        let message_id: UUID
    }

    private struct ReadReceiptsRow: Decodable {
        let id: UUID
        let read_receipts_enabled: Bool
    }

    /// Igual que WhatsApp/Instagram/Messenger: si CUALQUIERA de los dos
    /// (yo o la otra persona) desactivó su propio recibo de lectura, no
    /// se pinta "Leído" en ninguno de los dos sentidos -- ver
    /// 0091_read_receipts_toggle.sql. Equivalente de
    /// ChatViewModel.kt.loadReadReceiptsVisibility().
    private func loadReadReceiptsVisibility() async {
        guard let opponentID else { return }
        do {
            let rows: [ReadReceiptsRow] = try await SupabaseManager.shared.client
                .from("profiles")
                .select("id,read_receipts_enabled")
                .in("id", values: [currentUserID, opponentID])
                .execute()
                .value
            showReadReceipts = rows.allSatisfy { $0.read_receipts_enabled }
        } catch {
            // No crítico: si falla, se queda en el valor por defecto (true).
        }
    }

    /// Destacar/quitar destacado un mensaje real (propio o ajeno),
    /// comparado con WhatsApp -- `starred_messages_insert_own` ya
    /// comprueba del lado del servidor que soy de verdad parte de este
    /// chat (0087_starred_messages.sql). Equivalente de
    /// ChatViewModel.kt.toggleStar().
    func toggleStar(_ messageID: UUID) async {
        let currentlyStarred = starredMessageIDs.contains(messageID)
        if currentlyStarred {
            starredMessageIDs.remove(messageID)
        } else {
            starredMessageIDs.insert(messageID)
        }
        do {
            if currentlyStarred {
                try await SupabaseManager.shared.client
                    .from("starred_messages")
                    .delete()
                    .eq("user_id", value: currentUserID)
                    .eq("message_id", value: messageID)
                    .execute()
            } else {
                try await SupabaseManager.shared.client
                    .from("starred_messages")
                    .insert(NewStarredMessage(user_id: currentUserID, message_id: messageID))
                    .execute()
            }
        } catch {
            // Restricción unique(user_id, message_id): si ya existía, el
            // estado deseado ya se cumple, mismo criterio que
            // toggleReaction().
        }
    }

    /// Fijar/desfijar un mensaje real (propio o ajeno) para que aparezca
    /// destacado arriba del chat, VISIBLE PARA TODOS los participantes --
    /// a diferencia de toggleStar() (totalmente privado), comparado con
    /// WhatsApp/Telegram, ver 0089_pin_message.sql. El servidor no impone
    /// "solo uno a la vez" -- el propio cliente desfija el anterior antes
    /// de fijar uno nuevo (dos escrituras seguidas), mismo criterio ya
    /// usado en otras rondas de "el cliente orquesta, el servidor solo
    /// protege identidad". Equivalente de ChatViewModel.kt.togglePin().
    /// Dos `.update()` seguidos, no uno con ambas columnas mezcladas --
    /// mismo motivo de tipos ya documentado en editMessage()/muteChatFor().
    func togglePin(_ message: ChatMessage) async {
        let previouslyPinnedID = messages.first(where: { $0.pinnedAt != nil && $0.id != message.id })?.id
        let nowPinning = message.pinnedAt == nil
        let nowISO = ISO8601DateFormatter().string(from: Date())
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index].pinnedAt = nowPinning ? Date() : nil
            messages[index].pinnedBy = nowPinning ? currentUserID : nil
        }
        if let previouslyPinnedID, let index = messages.firstIndex(where: { $0.id == previouslyPinnedID }) {
            messages[index].pinnedAt = nil
            messages[index].pinnedBy = nil
        }
        let clearedPinnedAt: String? = nil
        let clearedPinnedBy: UUID? = nil
        do {
            if let previouslyPinnedID {
                try await SupabaseManager.shared.client
                    .from("messages")
                    .update(["pinned_at": clearedPinnedAt])
                    .eq("id", value: previouslyPinnedID)
                    .execute()
                try await SupabaseManager.shared.client
                    .from("messages")
                    .update(["pinned_by": clearedPinnedBy])
                    .eq("id", value: previouslyPinnedID)
                    .execute()
            }
            if nowPinning {
                try await SupabaseManager.shared.client
                    .from("messages")
                    .update(["pinned_at": nowISO])
                    .eq("id", value: message.id)
                    .execute()
                try await SupabaseManager.shared.client
                    .from("messages")
                    .update(["pinned_by": currentUserID])
                    .eq("id", value: message.id)
                    .execute()
            } else {
                try await SupabaseManager.shared.client
                    .from("messages")
                    .update(["pinned_at": clearedPinnedAt])
                    .eq("id", value: message.id)
                    .execute()
                try await SupabaseManager.shared.client
                    .from("messages")
                    .update(["pinned_by": clearedPinnedBy])
                    .eq("id", value: message.id)
                    .execute()
            }
        } catch {
            errorMessage = "No se pudo fijar el mensaje."
        }
    }

    /// Hallazgo real, el hueco de mensajería más grande de la sesión:
    /// ningún mensaje nuevo generaba nunca un aviso -- ver
    /// 0047_message_notify_mute.sql. Sin esto, el badge de Avisos
    /// acumularía avisos de mensajes que el usuario ya vio aquí mismo, en
    /// el propio chat. Dos pasos (traer + filtrar en cliente + actualizar
    /// por id) en vez de filtrar por `payload->>chat_id` directo en el
    /// servidor -- sin precedente verificado de filtro sobre una columna
    /// jsonb en este proyecto, mismo criterio de no adivinar una sintaxis
    /// no probada que ya se aplica al resto del código. Equivalente de
    /// ChatViewModel.kt.markMessageNotificationsRead().
    private func markMessageNotificationsRead() async {
        struct MessageNotifRow: Decodable {
            let id: UUID
            let payload: [String: String]
            let readAt: Date?
            enum CodingKeys: String, CodingKey {
                case id, payload
                case readAt = "read_at"
            }
        }
        do {
            let rows: [MessageNotifRow] = try await SupabaseManager.shared.client
                .from("notifications")
                .select("id,payload,read_at")
                .eq("kind", value: "message")
                .eq("recipient_id", value: currentUserID)
                .limit(200)
                .execute()
                .value
            let matchingIDs = rows.filter { $0.readAt == nil && $0.payload["chat_id"] == chatID.uuidString }.map { $0.id }
            guard !matchingIDs.isEmpty else { return }
            try await SupabaseManager.shared.client
                .from("notifications")
                .update(["read_at": ISO8601DateFormatter().string(from: Date())])
                .in("id", values: matchingIDs)
                .execute()
        } catch {
            // No bloquea el resto del chat si falla.
        }
    }

    /// Llamado desde ChatView en cada pulsación del campo de texto — mismo
    /// debounce de 300ms ya usado en SearchViewModel.swift para no saturar
    /// la red con un broadcast por letra tecleada.
    ///
    /// Aviso de honestidad: `channel.broadcast(event:message:)` con
    /// `[String: AnyJSON]` es la forma documentada en supabase-swift 2.x
    /// (mismo tipo `AnyJSON`/`.stringValue` ya usado arriba en
    /// `reactionDeletes`), pero no está verificada con compilador real en
    /// este entorno (límite de plataforma) — si la firma exacta difiere,
    /// es el único sitio a ajustar, igual que el resto de APIs de
    /// supabase-swift marcadas así en esta sesión.
    func notifyTyping() {
        typingSendTask?.cancel()
        typingSendTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let channel else { return }
            try? await channel.broadcast(event: "typing", message: ["user_id": .string(currentUserID.uuidString)])
        }
    }

    private func loadReactions() async {
        do {
            // Filtro directo por chat_id (desnormalizado en la tabla) en
            // vez de una lista de message_id — mismo criterio que
            // ChatViewModel.kt.loadReactions().
            let rows: [MessageReaction] = try await SupabaseManager.shared.client
                .from("message_reactions")
                .select()
                .eq("chat_id", value: chatID)
                .execute()
                .value
            reactions = Dictionary(grouping: rows, by: { $0.message_id })
        } catch {
            // Sin bloquear el resto del chat si falla.
        }
    }

    private struct NewReaction: Encodable {
        let message_id: UUID
        let chat_id: UUID
        let user_id: UUID
        let emoji: String
    }

    /// Toggle: si ya reaccionaste con ese emoji a ese mensaje, lo quita; si
    /// no, lo añade. Equivalente de ChatViewModel.kt.toggleReaction().
    func toggleReaction(messageID: UUID, emoji: String) async {
        let existing = reactions[messageID]?.first { $0.user_id == currentUserID && $0.emoji == emoji }
        do {
            if let existing {
                try await SupabaseManager.shared.client
                    .from("message_reactions")
                    .delete()
                    .eq("id", value: existing.id)
                    .execute()
                reactions[messageID]?.removeAll { $0.id == existing.id }
            } else {
                let inserted: MessageReaction = try await SupabaseManager.shared.client
                    .from("message_reactions")
                    .insert(NewReaction(message_id: messageID, chat_id: chatID, user_id: currentUserID, emoji: emoji))
                    .select()
                    .single()
                    .execute()
                    .value
                reactions[messageID, default: []].append(inserted)
            }
        } catch {
            errorMessage = "No se pudo reaccionar."
        }
    }

    /// Última pieza real de "chat funcional con fotos, voz, reacciones,
    /// read receipts" alcanzable sin infraestructura nueva —
    /// `messages_update_read` (0017_message_read_receipts.sql) solo deja
    /// marcar como leídos los mensajes ajenos, nunca los propios.
    /// Equivalente de ChatViewModel.kt.markMessagesRead().
    private func markMessagesRead() async {
        do {
            try await SupabaseManager.shared.client
                .from("messages")
                .update(["read_at": ISO8601DateFormatter().string(from: Date())])
                .eq("chat_id", value: chatID)
                .neq("sender_id", value: currentUserID)
                .execute()
            // Marcar como no leído manualmente (0088_mark_chat_unread.sql)
            // se limpia solo al volver a abrir el chat de verdad, mismo
            // criterio real que WhatsApp. Escribir `false` en las DOS
            // columnas a la vez es seguro sin saber si soy user_a o
            // user_b: `protect_chat_unread_flags` ya revierte en
            // silencio la columna ajena, dejando pasar solo la propia --
            // mismo contrato ya verificado en test_rls.mjs. Equivalente
            // de ChatViewModel.kt.markMessagesRead().
            try await SupabaseManager.shared.client
                .from("chats")
                .update(["marked_unread_by_a": false, "marked_unread_by_b": false])
                .eq("id", value: chatID)
                .execute()
        } catch {
            // No es crítico si falla.
        }
    }

    func stop() async {
        await channel?.unsubscribe()
    }

    private func loadHistory() async {
        do {
            let client = SupabaseManager.shared.client
            // Hallazgo real de escalabilidad: sin límite, abrir un chat
            // largo traía el historial ENTERO cada vez — mismo patrón de
            // `.limit()` ya usado en el resto del proyecto. Se piden los
            // últimos 100 en orden descendente y se invierten para
            // mostrar cronológicamente. Paginar hacia atrás sí está
            // construido -- ver loadOlderMessages() más abajo, cableado
            // desde ChatView.swift. Equivalente de
            // ChatViewModel.kt.loadHistory().
            let recent: [ChatMessage] = try await client
                .from("messages")
                .select()
                .eq("chat_id", value: chatID)
                .order("created_at", ascending: false)
                .limit(100)
                .execute()
                .value
            hasMoreHistory = recent.count >= 100
            messages = Array(recent.reversed())
            await loadSharedPosts(messages)
            await loadStoryPreviews(messages)

            let chat: Chat = try await client
                .from("chats")
                .select()
                .eq("id", value: chatID)
                .single()
                .execute()
                .value
            compatibilityScore = chat.compatibilityScore
            opponentID = chat.userAID == currentUserID ? chat.userBID : (chat.userBID == currentUserID ? chat.userAID : nil)
            await loadReadReceiptsVisibility()

            await checkActivitySuggestion()
            if messages.isEmpty { await loadIcebreaker() }
        } catch {
            errorMessage = "No se pudo cargar el chat: \(error.localizedDescription)"
        }
    }

    /// "Cargar mensajes anteriores" -- pide la página de mensajes justo antes
    /// del más antiguo ya cargado (mismo criterio de orden que loadHistory()),
    /// y la antepone a la lista actual.
    func loadOlderMessages() async {
        guard !isLoadingOlder, hasMoreHistory, let oldest = messages.first?.createdAt else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let older: [ChatMessage] = try await SupabaseManager.shared.client
                .from("messages")
                .select()
                .eq("chat_id", value: chatID)
                .lt("created_at", value: oldest)
                .order("created_at", ascending: false)
                .limit(olderPageSize)
                .execute()
                .value
            hasMoreHistory = older.count >= olderPageSize
            messages = older.reversed() + messages
            await loadSharedPosts(older)
            await loadStoryPreviews(older)
        } catch {
            errorMessage = "No se pudieron cargar mensajes anteriores."
        }
    }

    @Published var icebreaker: String?

    /// "Potenciar la IA" (petición explícita del usuario), comparado con
    /// Hinge ("Your Turn")/Bumble ("Opening Move"): un chat nuevo (social
    /// aceptado, sin mensajes todavía) se quedaba con el campo de texto
    /// vacío, sin ninguna ayuda real para arrancar la conversación. Se
    /// pide una sugerencia real a `icebreaker-ai` (mismo patrón que
    /// `duel-ai`/`activity-ai`) — efímera, no se persiste en ninguna
    /// tabla. Mismo fix ya construido en la versión Kotlin equivalente.
    func loadIcebreaker() async {
        struct IcebreakerRequest: Encodable { let chatId: UUID }
        struct IcebreakerResponse: Decodable { let message: String? }
        do {
            // Hallazgo real (primer resultado del CI real en GitHub
            // Actions): no existe overload de `functions.invoke` que
            // devuelva `Data` — se usa el overload genérico
            // `invoke<T: Decodable>` directamente en vez de decodificar a
            // mano (ver el mismo hallazgo, con más detalle, en
            // AnthropicDuelService.swift.invokeDuelAI).
            let response: IcebreakerResponse = try await SupabaseManager.shared.client.functions
                .invoke("icebreaker-ai", options: .init(body: IcebreakerRequest(chatId: chatID)))
            icebreaker = response.message
        } catch {
            // Sin IA disponible no se rompe el resto del chat.
        }
    }

    /// Usar la sugerencia como borrador — el usuario sigue pudiendo
    /// editarla antes de enviar, nunca se manda sola.
    func dismissIcebreaker() {
        icebreaker = nil
    }

    /// Escucha nuevos mensajes y cambios en la fila del chat (para la barra
    /// de compatibilidad) en tiempo real, tal como exige la Fase 5.
    private func subscribeToRealtime() async {
        let client = SupabaseManager.shared.client
        let ch = client.channel("chat-\(chatID.uuidString)")

        let messageInserts = ch.postgresChange(
            InsertAction.self, schema: "public", table: "messages",
            filter: "chat_id=eq.\(chatID.uuidString)"
        )
        let chatUpdates = ch.postgresChange(
            UpdateAction.self, schema: "public", table: "chats",
            filter: "id=eq.\(chatID.uuidString)"
        )
        // Para que el remitente vea "Leído" en vivo cuando la otra persona
        // marca sus mensajes como leídos, sin recargar el chat.
        let messageUpdates = ch.postgresChange(
            UpdateAction.self, schema: "public", table: "messages",
            filter: "chat_id=eq.\(chatID.uuidString)"
        )

        channel = ch
        await ch.subscribe()

        Task {
            for await change in messageInserts {
                if let message = try? change.decodeRecord(as: ChatMessage.self, decoder: JSONDecoder()) {
                    messages.append(message)
                    await loadSharedPosts([message])
                    await loadStoryPreviews([message])
                }
            }
        }

        Task {
            for await change in chatUpdates {
                if let chat = try? change.decodeRecord(as: Chat.self, decoder: JSONDecoder()) {
                    compatibilityScore = chat.compatibilityScore
                    await checkActivitySuggestion()
                }
            }
        }

        Task {
            for await change in messageUpdates {
                if let updated = try? change.decodeRecord(as: ChatMessage.self, decoder: JSONDecoder()),
                   let index = messages.firstIndex(where: { $0.id == updated.id }) {
                    messages[index] = updated
                }
            }
        }

        // Reacciones en vivo — inserciones y borrados de otros miembros
        // del chat, sin recargar.
        let reactionInserts = ch.postgresChange(
            InsertAction.self, schema: "public", table: "message_reactions",
            filter: "chat_id=eq.\(chatID.uuidString)"
        )
        let reactionDeletes = ch.postgresChange(
            DeleteAction.self, schema: "public", table: "message_reactions",
            filter: "chat_id=eq.\(chatID.uuidString)"
        )
        Task {
            for await change in reactionInserts {
                if let reaction = try? change.decodeRecord(as: MessageReaction.self, decoder: JSONDecoder()) {
                    if !(reactions[reaction.message_id]?.contains(where: { $0.id == reaction.id }) ?? false) {
                        reactions[reaction.message_id, default: []].append(reaction)
                    }
                }
            }
        }
        // Aviso de honestidad: la forma exacta de `oldRecord` en un
        // DeleteAction de supabase-swift 2.x (acceso tipo diccionario a
        // AnyJSON, con `.stringValue`) está razonada por analogía con
        // `decodeRecord` ya usado arriba, pero no verificada con compilador
        // real (límite de plataforma) — si la firma difiere, es el único
        // sitio a ajustar.
        Task {
            for await change in reactionDeletes {
                if let idString = change.oldRecord["id"]?.stringValue, let id = UUID(uuidString: idString) {
                    for key in reactions.keys {
                        reactions[key]?.removeAll { $0.id == id }
                    }
                }
            }
        }

        // Hallazgo real (CI real, GitHub Actions, 2026-08-24): confirmado
        // el riesgo que ya avisaba el comentario anterior — la firma real
        // (leída del código fuente de
        // supabase/supabase-swift/Sources/RealtimeV2/RealtimeChannelV2.swift
        // y PresenceAction.swift) es `track(state: JSONObject) async` (con
        // etiqueta, sin throws) y `PresenceAction.joins/.leaves` son
        // `[String: PresenceV2]`, no `[String: Presence]` (tipo v1, ya no
        // existe en la API actual).
        Task {
            let myID = currentUserID.uuidString
            await ch.track(state: ["user_id": .string(myID)])
        }
        let presenceEvents = ch.presenceChange()
        Task {
            for await action in presenceEvents {
                func decode(_ presences: [String: PresenceV2]) -> [String] {
                    presences.values.compactMap { $0.state["user_id"]?.stringValue }
                }
                decode(action.joins).forEach { onlineUserIDs.insert($0) }
                decode(action.leaves).forEach { onlineUserIDs.remove($0) }
                isOpponentOnline = onlineUserIDs.contains { $0 != currentUserID.uuidString }
            }
        }

        let typingEvents = ch.broadcastStream(event: "typing")
        Task {
            for await message in typingEvents {
                guard let senderID = message["user_id"]?.stringValue, senderID != currentUserID.uuidString else { continue }
                isOpponentTyping = true
                // Sin un evento explícito de "dejé de escribir" (mismo
                // criterio que WhatsApp): se apaga sola si no llega otro
                // broadcast en 3s.
                typingClearTask?.cancel()
                typingClearTask = Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    isOpponentTyping = false
                }
            }
        }
    }

    private struct NewMessage: Encodable {
        let chat_id: UUID
        let sender_id: UUID
        var body: String? = nil
        var media_url: String? = nil
        var audio_url: String? = nil
        var reply_to_message_id: UUID? = nil
    }

    func sendMessage() async {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Mismo límite real que messages_body_length
        // (0023_text_length_limits.sql) — validado aquí también, mismo
        // criterio ya aplicado a nombre/bio de perfil y caption de posts,
        // ya construido en la versión Kotlin equivalente.
        guard draft.count <= 2000 else {
            errorMessage = "El mensaje no puede tener más de 2000 caracteres."
            return
        }
        // Hallazgo real: si el usuario ignoraba la sugerencia de apertura
        // (icebreaker) y escribía su propio mensaje, la sugerencia se
        // quedaba visible para siempre encima del compositor. Mismo fix
        // ya construido en la versión Kotlin equivalente.
        icebreaker = nil
        // Responder a un mensaje concreto (cita), comparado con
        // WhatsApp/Telegram/iMessage/Instagram DM -- se consume aquí y se
        // limpia, tanto si el envío sale bien como si falla (mismo
        // criterio real ya usado en la versión Kotlin equivalente: la
        // cita no sobrevive a un envío fallido, se vuelve a elegir).
        let replyToID = replyingTo?.id
        replyingTo = nil
        do {
            try await SupabaseManager.shared.client
                .from("messages")
                .insert(NewMessage(chat_id: chatID, sender_id: currentUserID, body: draft, reply_to_message_id: replyToID))
                .execute()
            draft = ""
        } catch {
            errorMessage = "No se pudo enviar el mensaje."
        }
    }

    /// Primera pieza de "chat multimedia" — el chat solo soportaba texto
    /// (ver `messages_body_or_media`, 0016_message_media.sql).
    func sendPhoto(imageData: Data) async {
        icebreaker = nil
        do {
            let url = try await StorageUploader.uploadImage(data: imageData, fileExtension: "jpg", userID: currentUserID)
            try await SupabaseManager.shared.client
                .from("messages")
                .insert(NewMessage(chat_id: chatID, sender_id: currentUserID, media_url: url))
                .execute()
        } catch {
            errorMessage = "No se pudo enviar la foto."
        }
    }

    /// Última pieza real de "chat funcional con fotos, voz, reacciones,
    /// read receipts" — nota de voz nativa (ver VoiceRecorder.swift).
    /// Equivalente de ChatViewModel.kt.sendVoiceNote().
    func sendVoiceNote(fileURL: URL) async {
        icebreaker = nil
        do {
            let data = try Data(contentsOf: fileURL)
            let url = try await StorageUploader.uploadAudio(data: data, userID: currentUserID)
            try await SupabaseManager.shared.client
                .from("messages")
                .insert(NewMessage(chat_id: chatID, sender_id: currentUserID, audio_url: url))
                .execute()
            try? FileManager.default.removeItem(at: fileURL)
        } catch {
            errorMessage = "No se pudo enviar la nota de voz."
        }
    }

    /// Hallazgo real, mismo patrón que socials/compat_requests: no había
    /// NINGUNA forma de borrar un mensaje propio — `messages` no tenía
    /// política de delete hasta esta pasada (ver 0022_messages_delete.sql).
    /// "Borrar para todos", no solo-para-mí. Equivalente de
    /// ChatViewModel.kt.deleteMessage().
    func deleteMessage(_ messageID: UUID) async {
        messages.removeAll { $0.id == messageID }
        do {
            try await SupabaseManager.shared.client
                .from("messages")
                .delete()
                .eq("id", value: messageID)
                .execute()
        } catch {
            errorMessage = "No se pudo borrar el mensaje."
        }
    }

    /// Hallazgo real, comparado con WhatsApp/Telegram/Messenger: un mensaje
    /// mal escrito solo se podía borrar entero, nunca corregir --
    /// `messages` no tenía ninguna política de UPDATE que dejara al
    /// remitente tocar su propio `body` hasta esta pasada (ver
    /// 0049_messages_edit.sql). Mismo límite real que
    /// `messages_body_length` (0023, 2000 caracteres). Sin ventana de
    /// tiempo límite para editar (alcance deliberado, ver la propia
    /// migración). Equivalente de ChatViewModel.kt.editMessage().
    func editMessage(_ messageID: UUID, newBody: String) async {
        guard !newBody.isEmpty, newBody.count <= 2000 else { return }
        let now = Date()
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].body = newBody
            messages[index].editedAt = now
        }
        do {
            try await SupabaseManager.shared.client
                .from("messages")
                .update(["body": newBody, "edited_at": ISO8601DateFormatter().string(from: now)])
                .eq("id", value: messageID)
                .execute()
        } catch {
            errorMessage = "No se pudo editar el mensaje."
        }
    }

    /// Vota +1/+10/+100 o -1/-10/-100 en la barra de compatibilidad.
    /// Hallazgo de seguridad real (corregido en
    /// 0032_protect_compatibility_score.sql): antes esta función calculaba
    /// `newScore` en el cliente y lo escribía directamente en
    /// `chats.compatibility_score` — un cliente modificado podía saltarse
    /// el voto por completo y escribir cualquier valor. El servidor ahora
    /// es la única fuente de verdad: un trigger en `compatibility_votes`
    /// aplica el delta y actualiza el score, y un segundo trigger revierte
    /// cualquier escritura directa a `compatibility_score` que no venga de
    /// ese trigger. Este cliente ya no escribe `chats` en absoluto — el
    /// número autoritativo llega por la suscripción Realtime a `UPDATE` en
    /// `chats` que ya existía. Mismo fix ya aplicado en la versión Kotlin
    /// equivalente.
    ///
    /// Retoque de UX de la misma pasada: sin ninguna actualización local,
    /// la barra se quedaría congelada hasta que diera la vuelta completa
    /// el trayecto voto→trigger→Realtime. Se mantiene el feedback
    /// optimista — SOLO en memoria, nunca escrito a la base de datos — y
    /// se deja que el valor real de `chats` lo sobrescriba en cuanto
    /// llegue por Realtime.
    func vote(delta: Int) async {
        compatibilityScore = max(0, min(100, compatibilityScore + delta))
        struct NewVote: Encodable {
            let chat_id: UUID
            let voter_id: UUID
            let delta: Int
        }
        do {
            try await SupabaseManager.shared.client
                .from("compatibility_votes")
                .insert(NewVote(chat_id: chatID, voter_id: currentUserID, delta: delta))
                .execute()
        } catch {
            errorMessage = "No se pudo registrar el voto."
        }
    }

    /// Al superar el 50%, se muestra una actividad sugerida (generada en Fase 6
    /// vía IA; aquí se consulta si ya existe una guardada para este chat).
    /// Hallazgo real (cerrado esta pasada): esta función siempre consultó
    /// `activities` de verdad, pero NADA insertaba en esa tabla en ningún
    /// sitio — el campo "✨ Actividad sugerida" estaba conectado a un pozo
    /// vacío desde que se construyó. Ahora, si la compatibilidad supera el
    /// 50% y no hay ninguna fila todavía, se genera una de verdad con IA
    /// (Edge Function `activity-ai`, mismo patrón que `duel-ai`: la clave
    /// de Anthropic nunca sale del servidor). Mismo fix ya construido en
    /// la versión Kotlin equivalente.
    private func checkActivitySuggestion() async {
        guard compatibilityScore > 50 else {
            suggestedActivity = nil
            return
        }
        struct ActivityRow: Decodable { let suggestion: String }
        if let activity: ActivityRow = try? await SupabaseManager.shared.client
            .from("activities")
            .select()
            .eq("chat_id", value: chatID)
            .order("created_at", ascending: false)
            .limit(1)
            .single()
            .execute()
            .value {
            suggestedActivity = activity.suggestion
            return
        }

        struct ActivityRequest: Encodable { let chatId: UUID }
        struct ActivityResponse: Decodable { let suggestion: String? }
        do {
            let response: ActivityResponse = try await SupabaseManager.shared.client.functions
                .invoke("activity-ai", options: .init(body: ActivityRequest(chatId: chatID)))
            suggestedActivity = response.suggestion
        } catch {
            // Sin IA disponible (límite de uso, red...) no se rompe el
            // resto del chat — simplemente no se muestra sugerencia.
        }
    }
}
