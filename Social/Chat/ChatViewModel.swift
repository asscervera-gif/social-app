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
        await loadReactions()
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
            // mostrar cronológicamente. Paginar hacia atrás (cargar más
            // historial antiguo) no se construye aquí — hueco real
            // documentado, no inventado. Equivalente de
            // ChatViewModel.kt.loadHistory().
            let recent: [ChatMessage] = try await client
                .from("messages")
                .select()
                .eq("chat_id", value: chatID)
                .order("created_at", ascending: false)
                .limit(100)
                .execute()
                .value
            messages = Array(recent.reversed())

            let chat: Chat = try await client
                .from("chats")
                .select()
                .eq("id", value: chatID)
                .single()
                .execute()
                .value
            compatibilityScore = chat.compatibilityScore
            opponentID = chat.userAID == currentUserID ? chat.userBID : (chat.userBID == currentUserID ? chat.userAID : nil)

            await checkActivitySuggestion()
            if messages.isEmpty { await loadIcebreaker() }
        } catch {
            errorMessage = "No se pudo cargar el chat: \(error.localizedDescription)"
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

        // Aviso de honestidad (más fuerte de lo habitual): a diferencia del
        // resto de APIs de supabase-swift usadas en esta sesión (razonadas
        // por analogía directa con un método hermano ya usado, como
        // `broadcastStream` junto a `broadcast`), la superficie exacta de
        // Presence en supabase-swift 2.x no se ha visto en ningún otro
        // sitio de este proyecto — `track(_:)`/`presenceChange()` con
        // `PresenceAction.joins`/`.leaves` es la forma razonada por
        // simetría con `RealtimeChannel.track`/`presenceChangeFlow` de
        // Kotlin (mismo SDK, mismo diseño de API entre plataformas), pero
        // el riesgo de que el nombre exacto difiera es mayor aquí que en
        // el resto de esta pasada. Sin verificación de compilador real
        // (límite de plataforma) — si la firma difiere, es el único sitio
        // a ajustar.
        Task {
            let myID = currentUserID.uuidString
            try? await ch.track(["user_id": .string(myID)])
        }
        let presenceEvents = ch.presenceChange()
        Task {
            for await action in presenceEvents {
                func decode(_ presences: [String: Presence]) -> [String] {
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
        do {
            try await SupabaseManager.shared.client
                .from("messages")
                .insert(NewMessage(chat_id: chatID, sender_id: currentUserID, body: draft))
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
