//
//  GroupChatViewModel.swift
//  Social
//
//  Hilo de un chat de grupo real -- mismo patrón que ChatViewModel.swift
//  (1:1). Reacciones (0060_group_message_reactions.sql), "visto por"
//  (0061_group_message_reads.sql), notas de voz
//  (0062_group_message_audio.sql) y fotos (media_url) reales. Mensajes en
//  vivo vía Realtime, mismo mecanismo ya usado en el chat 1:1. Equivalente
//  de GroupChatViewModel.kt.
//

import Foundation
import Supabase

struct GroupMessage: Codable, Identifiable {
    let id: UUID
    let groupChatID: UUID
    let senderID: UUID
    var body: String?
    var mediaURL: String?
    // Nota de voz real (0062_group_message_audio.sql), comparado con
    // WhatsApp/Messenger/Telegram -- mismo campo separado que
    // ChatMessage.audioURL (chat 1:1, 0019_message_audio.sql).
    var audioURL: String?
    var createdAt: String
    // Editar un mensaje ya enviado en un grupo (0065_group_messages_edit_delete.sql),
    // comparado con WhatsApp/Telegram/Messenger -- mismo campo separado
    // que ChatMessage.editedAt (chat 1:1, 0049_messages_edit.sql).
    var editedAt: String?
    // Enviar una publicación a un chat de grupo real
    // (0069_message_shared_post.sql), comparado con Instagram/TikTok/
    // Twitter/Snapchat.
    var sharedPostID: UUID?
    // Reenviar un mensaje real (0072_message_forward.sql), comparado con
    // WhatsApp/Telegram/Messenger.
    var isForwarded: Bool = false
    // Fijar un mensaje real (propio o ajeno) para que aparezca destacado
    // arriba del chat, VISIBLE PARA TODOS los miembros -- a diferencia de
    // starred_messages (totalmente privado), comparado con
    // WhatsApp/Telegram, ver 0089_pin_message.sql.
    var pinnedAt: String? = nil
    var pinnedBy: UUID? = nil
    // Responder a un mensaje concreto (cita), comparado con
    // WhatsApp/Telegram/iMessage/Instagram DM -- referencia al mensaje
    // real citado, nunca una copia. Ver 0102_message_reply.sql.
    var replyToMessageID: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case groupChatID = "group_chat_id"
        case senderID = "sender_id"
        case body
        case mediaURL = "media_url"
        case audioURL = "audio_url"
        case createdAt = "created_at"
        case editedAt = "edited_at"
        case sharedPostID = "shared_post_id"
        case isForwarded = "is_forwarded"
        case pinnedAt = "pinned_at"
        case pinnedBy = "pinned_by"
        case replyToMessageID = "reply_to_message_id"
    }
}

@MainActor
final class GroupChatViewModel: ObservableObject {
    let groupChatID: UUID

    @Published var messages: [GroupMessage] = []
    @Published var members: [Profile] = []
    // Administradores reales de grupo, comparado con WhatsApp/Telegram/
    // Messenger -- ver 0107_group_chat_admins.sql.
    @Published var adminIDs: Set<UUID> = []
    @Published var errorMessage: String?
    // Responder a un mensaje concreto (cita), comparado con
    // WhatsApp/Telegram/iMessage/Instagram DM -- mensaje real que se está
    // citando ahora mismo en el compositor, ver 0102_message_reply.sql.
    // Equivalente de ChatViewModel.swift.replyingTo (chat 1:1).
    @Published var replyingTo: GroupMessage?

    // Nombre editable y foto de grupo real (0063_group_chat_photo.sql),
    // comparado con WhatsApp/Messenger/Telegram -- `group_chats_update_own`
    // (0057_group_chats.sql) ya dejaba al creador renombrar/poner foto,
    // pero ningún cliente lo llamaba nunca ni cargaba esta fila.
    @Published var groupChat: GroupChat?

    // Enviar una publicación a un chat de grupo real
    // (0069_message_shared_post.sql), comparado con Instagram/TikTok/
    // Twitter/Snapchat -- mismo patrón exacto que ChatViewModel.swift
    // (chat 1:1).
    @Published var sharedPosts: [UUID: Post] = [:]
    @Published var sharedPostAuthors: [UUID: Profile] = [:]

    private func loadSharedPosts(_ messages: [GroupMessage]) async {
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

    // Reacciones a mensajes de grupo (0060_group_message_reactions.sql),
    // comparado con WhatsApp/Messenger/Instagram -- mismo patrón exacto
    // que ChatViewModel.swift (chat 1:1).
    @Published var reactions: [UUID: [GroupMessageReaction]] = [:]

    struct GroupMessageReaction: Codable, Identifiable {
        let id: UUID
        let group_message_id: UUID
        let user_id: UUID
        let emoji: String
    }

    // "Visto por" real (0061_group_message_reads.sql), comparado con
    // WhatsApp/Messenger -- mapa de group_message_id a la lista de
    // user_id que lo han leído (nunca incluye al propio autor, RLS lo
    // impide desde el servidor).
    @Published var reads: [UUID: [UUID]] = [:]

    private struct ReadRow: Codable {
        let group_message_id: UUID
        let user_id: UUID
    }

    // "En línea" y "escribiendo…" reales en un chat de grupo, comparado
    // con WhatsApp/Messenger -- mismo mecanismo exacto que
    // ChatViewModel.swift (chat 1:1): Presence/Broadcast de Realtime
    // sobre el mismo canal ya abierto para mensajes. A diferencia del
    // 1:1 (un único booleano), aquí hace falta un CONJUNTO de miembros
    // -- puede haber varios a la vez viendo el grupo o escribiendo.
    @Published var onlineMemberIDs = Set<UUID>()
    @Published var typingMemberIDs = Set<UUID>()
    private var typingClearTasks: [UUID: Task<Void, Never>] = [:]
    private var typingSendTask: Task<Void, Never>?

    private var channel: RealtimeChannelV2?

    init(groupChatID: UUID) {
        self.groupChatID = groupChatID
    }

    func load() async {
        do {
            messages = try await SupabaseManager.shared.client
                .from("group_messages")
                .select()
                .eq("group_chat_id", value: groupChatID)
                .order("created_at", ascending: true)
                .execute()
                .value
            await loadGroupChat()
            await loadMembers()
            await loadReactions()
            await loadReads()
            await loadSharedPosts(messages)
            await markUnreadAsRead()
            await loadStarred()
        } catch {
            errorMessage = "No se pudieron cargar los mensajes: \(error.localizedDescription)"
        }
        await subscribeToRealtime()
    }

    private func loadReads() async {
        do {
            let rows: [ReadRow] = try await SupabaseManager.shared.client
                .from("group_message_reads")
                .select("group_message_id,user_id")
                .eq("group_chat_id", value: groupChatID)
                .execute()
                .value
            reads = Dictionary(grouping: rows, by: { $0.group_message_id }).mapValues { group in group.map { $0.user_id } }
        } catch {
            // Sin bloquear el resto del hilo si falla.
        }
    }

    private struct NewRead: Encodable {
        let group_message_id: UUID
        let group_chat_id: UUID
        let user_id: UUID
    }

    /// Marca como leídos todos los mensajes AJENOS todavía no leídos por
    /// mí -- RLS (`group_message_reads_insert_own`) ya impide marcar el
    /// propio. Equivalente de GroupChatViewModel.kt.markUnreadAsRead().
    private func markUnreadAsRead() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        let alreadyRead = Set(reads.filter { $0.value.contains(userID) }.keys)
        let toMark = messages.filter { $0.senderID != userID && !alreadyRead.contains($0.id) }
        if !toMark.isEmpty {
            do {
                let rows = toMark.map { NewRead(group_message_id: $0.id, group_chat_id: groupChatID, user_id: userID) }
                try await SupabaseManager.shared.client
                    .from("group_message_reads")
                    .insert(rows)
                    .execute()
                for message in toMark {
                    reads[message.id, default: []].append(userID)
                }
            } catch {
                // Best-effort -- un recibo de lectura que falla no debe
                // interrumpir la lectura del chat.
            }
        }
        // Marcar como no leído manualmente (0088_mark_chat_unread.sql) y
        // la detección real de no leído en la lista de grupos se limpian
        // solas al volver a abrir el grupo de verdad, mismo criterio real
        // que el chat 1:1 (ChatViewModel.markMessagesRead()).
        do {
            // Dos `.update()` seguidos, no uno con ambas columnas
            // mezcladas -- un diccionario de Swift necesita un tipo de
            // valor homogéneo (Bool por un lado, String por otro), mismo
            // motivo ya documentado en
            // ChatListViewModel.swift.muteChatFor().
            try await SupabaseManager.shared.client
                .from("group_chat_members")
                .update(["marked_unread": false])
                .eq("group_chat_id", value: groupChatID)
                .eq("user_id", value: userID)
                .execute()
            try await SupabaseManager.shared.client
                .from("group_chat_members")
                .update(["last_read_at": ISO8601DateFormatter().string(from: Date())])
                .eq("group_chat_id", value: groupChatID)
                .eq("user_id", value: userID)
                .execute()
        } catch {
            // No crítico: la próxima carga real de la lista reconcilia el
            // estado con el servidor.
        }
    }

    private func loadReactions() async {
        do {
            // Filtro directo por group_chat_id (desnormalizado en la
            // tabla) -- mismo criterio que ChatViewModel.swift.loadReactions().
            let rows: [GroupMessageReaction] = try await SupabaseManager.shared.client
                .from("group_message_reactions")
                .select()
                .eq("group_chat_id", value: groupChatID)
                .execute()
                .value
            reactions = Dictionary(grouping: rows, by: { $0.group_message_id })
        } catch {
            // Sin bloquear el resto del hilo si falla.
        }
    }

    // Mensajes destacados reales, comparado con WhatsApp
    // (0087_starred_messages.sql) -- totalmente privado, sobre CUALQUIER
    // mensaje de grupo (propio o ajeno). Equivalente de
    // GroupChatViewModel.kt.starredMessageIds.
    @Published var starredMessageIDs: Set<UUID> = []

    private func loadStarred() async {
        struct StarredGroupIDRow: Decodable { let group_message_id: UUID }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        // `starred_messages` no desnormaliza group_chat_id (a diferencia
        // de group_message_reactions) -- filtro por user_id + `in` sobre
        // los group_message_id ya cargados, mismo criterio que
        // GroupChatViewModel.kt.loadStarred().
        let groupMessageIDs = messages.map { $0.id }
        guard !groupMessageIDs.isEmpty else { return }
        if let rows: [StarredGroupIDRow] = try? await SupabaseManager.shared.client
            .from("starred_messages")
            .select("group_message_id")
            .eq("user_id", value: userID)
            .in("group_message_id", values: groupMessageIDs)
            .execute()
            .value {
            starredMessageIDs = Set(rows.map { $0.group_message_id })
        }
    }

    private struct NewStarredGroupMessage: Encodable {
        let user_id: UUID
        let group_message_id: UUID
    }

    /// Destacar/quitar destacado un mensaje de grupo real (propio o
    /// ajeno), comparado con WhatsApp -- `starred_messages_insert_own` ya
    /// comprueba del lado del servidor que soy de verdad miembro de este
    /// grupo (0087_starred_messages.sql). Equivalente de
    /// GroupChatViewModel.kt.toggleStar().
    func toggleStar(_ groupMessageID: UUID) async {
        let currentlyStarred = starredMessageIDs.contains(groupMessageID)
        if currentlyStarred {
            starredMessageIDs.remove(groupMessageID)
        } else {
            starredMessageIDs.insert(groupMessageID)
        }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            if currentlyStarred {
                try await SupabaseManager.shared.client
                    .from("starred_messages")
                    .delete()
                    .eq("user_id", value: userID)
                    .eq("group_message_id", value: groupMessageID)
                    .execute()
            } else {
                try await SupabaseManager.shared.client
                    .from("starred_messages")
                    .insert(NewStarredGroupMessage(user_id: userID, group_message_id: groupMessageID))
                    .execute()
            }
        } catch {
            // Restricción unique(user_id, group_message_id): si ya
            // existía, el estado deseado ya se cumple.
        }
    }

    /// Fijar/desfijar un mensaje de grupo real (propio o ajeno) para que
    /// aparezca destacado arriba del chat, VISIBLE PARA TODOS los
    /// miembros -- a diferencia de toggleStar() (totalmente privado),
    /// comparado con WhatsApp/Telegram, ver 0089_pin_message.sql. El
    /// servidor no impone "solo uno a la vez" -- el propio cliente
    /// desfija el anterior antes de fijar uno nuevo (dos escrituras
    /// seguidas), mismo criterio que ChatViewModel.togglePin() (chat
    /// 1:1). Equivalente de GroupChatViewModel.kt.togglePin(). Dos
    /// `.update()` seguidos, no uno con ambas columnas mezcladas -- mismo
    /// motivo de tipos ya documentado más arriba en este archivo.
    func togglePin(_ message: GroupMessage) async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        let previouslyPinnedID = messages.first(where: { $0.pinnedAt != nil && $0.id != message.id })?.id
        let nowPinning = message.pinnedAt == nil
        let nowISO = ISO8601DateFormatter().string(from: Date())
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index].pinnedAt = nowPinning ? nowISO : nil
            messages[index].pinnedBy = nowPinning ? userID : nil
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
                    .from("group_messages")
                    .update(["pinned_at": clearedPinnedAt])
                    .eq("id", value: previouslyPinnedID)
                    .execute()
                try await SupabaseManager.shared.client
                    .from("group_messages")
                    .update(["pinned_by": clearedPinnedBy])
                    .eq("id", value: previouslyPinnedID)
                    .execute()
            }
            if nowPinning {
                try await SupabaseManager.shared.client
                    .from("group_messages")
                    .update(["pinned_at": nowISO])
                    .eq("id", value: message.id)
                    .execute()
                try await SupabaseManager.shared.client
                    .from("group_messages")
                    .update(["pinned_by": userID])
                    .eq("id", value: message.id)
                    .execute()
            } else {
                try await SupabaseManager.shared.client
                    .from("group_messages")
                    .update(["pinned_at": clearedPinnedAt])
                    .eq("id", value: message.id)
                    .execute()
                try await SupabaseManager.shared.client
                    .from("group_messages")
                    .update(["pinned_by": clearedPinnedBy])
                    .eq("id", value: message.id)
                    .execute()
            }
        } catch {
            errorMessage = "No se pudo fijar el mensaje."
        }
    }

    private struct NewGroupReaction: Encodable {
        let group_message_id: UUID
        let group_chat_id: UUID
        let user_id: UUID
        let emoji: String
    }

    /// Toggle: si ya reaccionaste con ese emoji a ese mensaje, lo quita; si
    /// no, lo añade. Equivalente de ChatViewModel.swift.toggleReaction().
    func toggleReaction(groupMessageID: UUID, emoji: String) async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        let existing = reactions[groupMessageID]?.first { $0.user_id == userID && $0.emoji == emoji }
        do {
            if let existing {
                try await SupabaseManager.shared.client
                    .from("group_message_reactions")
                    .delete()
                    .eq("id", value: existing.id)
                    .execute()
                reactions[groupMessageID]?.removeAll { $0.id == existing.id }
            } else {
                let inserted: GroupMessageReaction = try await SupabaseManager.shared.client
                    .from("group_message_reactions")
                    .insert(NewGroupReaction(group_message_id: groupMessageID, group_chat_id: groupChatID, user_id: userID, emoji: emoji))
                    .select()
                    .single()
                    .execute()
                    .value
                reactions[groupMessageID, default: []].append(inserted)
            }
        } catch {
            errorMessage = "No se pudo reaccionar."
        }
    }

    /// Llamado desde GroupChatView en cada pulsación del campo de texto --
    /// mismo debounce de 300ms ya usado en ChatViewModel.swift.notifyTyping().
    func notifyTyping() {
        typingSendTask?.cancel()
        typingSendTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let channel else { return }
            guard let myID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            try? await channel.broadcast(event: "typing", message: ["user_id": .string(myID.uuidString)])
        }
    }

    private func loadGroupChat() async {
        groupChat = try? await SupabaseManager.shared.client
            .from("group_chats")
            .select()
            .eq("id", value: groupChatID)
            .single()
            .execute()
            .value
    }

    /// Renombrar el grupo real, comparado con WhatsApp/Messenger/Telegram
    /// -- RLS (`group_chats_update_own`, 0057_group_chats.sql) ya limitaba
    /// esto al creador; aquí se intenta igual para cualquiera y se deja
    /// que el servidor decida (0 filas afectadas y sin error si no eres el
    /// creador, mismo comportamiento ya confirmado en test_rls.mjs).
    /// Diccionario con solo la columna a cambiar (mismo patrón ya usado en
    /// ChatViewModel.swift.markMessagesRead()/ChatListViewModel.swift.muteChatFor()
    /// etc.), no un
    /// struct con campos opcionales -- evita el riesgo real de que un
    /// campo no tocado se codifique como `null` y borre la foto/nombre.
    func renameGroup(_ newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100 else { return }
        do {
            try await SupabaseManager.shared.client
                .from("group_chats")
                .update(["name": trimmed])
                .eq("id", value: groupChatID)
                .execute()
            groupChat?.name = trimmed
        } catch {
            errorMessage = "No se pudo renombrar el grupo."
        }
    }

    /// Foto de grupo real -- reutiliza tal cual `StorageUploader.uploadImage`
    /// ya construido para fotos de chat, sin infraestructura nueva.
    func updatePhoto(imageData: Data) async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            let url = try await StorageUploader.uploadImage(data: imageData, fileExtension: "jpg", userID: userID)
            try await SupabaseManager.shared.client
                .from("group_chats")
                .update(["photo_url": url])
                .eq("id", value: groupChatID)
                .execute()
            groupChat?.photoURL = url
        } catch {
            errorMessage = "No se pudo cambiar la foto del grupo."
        }
    }

    private func loadMembers() async {
        struct MemberIDRow: Decodable {
            let user_id: UUID
            // Administradores reales de grupo, comparado con WhatsApp/
            // Telegram/Messenger -- ver 0107_group_chat_admins.sql.
            var is_admin: Bool = false
        }
        guard let memberRows: [MemberIDRow] = try? await SupabaseManager.shared.client
            .from("group_chat_members")
            .select("user_id,is_admin")
            .eq("group_chat_id", value: groupChatID)
            .execute()
            .value else { return }
        let memberIDs = memberRows.map { $0.user_id }
        adminIDs = Set(memberRows.filter { $0.is_admin }.map { $0.user_id })
        guard !memberIDs.isEmpty else { return }
        if let profiles: [Profile] = try? await SupabaseManager.shared.client
            .from("profiles")
            .select()
            .in("id", values: memberIDs)
            .execute()
            .value {
            members = profiles
        }
    }

    private func subscribeToRealtime() async {
        let client = SupabaseManager.shared.client
        let ch = client.channel("group-chat-\(groupChatID.uuidString)")
        let messageInserts = ch.postgresChange(
            InsertAction.self, schema: "public", table: "group_messages",
            filter: "group_chat_id=eq.\(groupChatID.uuidString)"
        )
        // Editar un mensaje ya enviado en un grupo real
        // (0065_group_messages_edit_delete.sql), comparado con WhatsApp/
        // Telegram/Messenger -- mismo patrón exacto que ChatViewModel.swift
        // (chat 1:1): cualquier UPDATE de la fila reemplaza la copia local.
        let messageUpdates = ch.postgresChange(
            UpdateAction.self, schema: "public", table: "group_messages",
            filter: "group_chat_id=eq.\(groupChatID.uuidString)"
        )
        // Reacciones en vivo -- inserciones y borrados de otros miembros
        // del grupo, sin tener que recargar. Mismo patrón exacto que
        // ChatViewModel.swift (chat 1:1).
        let reactionInserts = ch.postgresChange(
            InsertAction.self, schema: "public", table: "group_message_reactions",
            filter: "group_chat_id=eq.\(groupChatID.uuidString)"
        )
        let reactionDeletes = ch.postgresChange(
            DeleteAction.self, schema: "public", table: "group_message_reactions",
            filter: "group_chat_id=eq.\(groupChatID.uuidString)"
        )
        // "Visto por" en vivo -- otro miembro marcando como leído uno de
        // mis mensajes, sin tener que recargar.
        let readInserts = ch.postgresChange(
            InsertAction.self, schema: "public", table: "group_message_reads",
            filter: "group_chat_id=eq.\(groupChatID.uuidString)"
        )
        channel = ch
        await ch.subscribe()

        Task {
            for await change in messageInserts {
                if let message = try? change.decodeRecord(as: GroupMessage.self, decoder: JSONDecoder()) {
                    if !messages.contains(where: { $0.id == message.id }) {
                        messages.append(message)
                        await loadSharedPosts([message])
                        // El chat sigue abierto -- un mensaje que llega en
                        // vivo se marca leído igual que uno cargado al
                        // abrir el hilo.
                        await markUnreadAsRead()
                    }
                }
            }
        }

        Task {
            for await change in messageUpdates {
                if let updated = try? change.decodeRecord(as: GroupMessage.self, decoder: JSONDecoder()),
                   let index = messages.firstIndex(where: { $0.id == updated.id }) {
                    messages[index] = updated
                }
            }
        }

        Task {
            for await change in readInserts {
                if let read = try? change.decodeRecord(as: ReadRow.self, decoder: JSONDecoder()) {
                    if !(reads[read.group_message_id]?.contains(read.user_id) ?? false) {
                        reads[read.group_message_id, default: []].append(read.user_id)
                    }
                }
            }
        }

        Task {
            for await change in reactionInserts {
                if let reaction = try? change.decodeRecord(as: GroupMessageReaction.self, decoder: JSONDecoder()) {
                    if !(reactions[reaction.group_message_id]?.contains(where: { $0.id == reaction.id }) ?? false) {
                        reactions[reaction.group_message_id, default: []].append(reaction)
                    }
                }
            }
        }

        // Aviso de honestidad, mismo criterio ya documentado en
        // ChatViewModel.swift: la forma exacta de `oldRecord` en un
        // DeleteAction (acceso tipo diccionario a AnyJSON con
        // `.stringValue`) está razonada por analogía, no verificada con
        // compilador real -- si difiere, es el único sitio a ajustar.
        Task {
            for await change in reactionDeletes {
                if let idString = change.oldRecord["id"]?.stringValue, let id = UUID(uuidString: idString) {
                    for key in reactions.keys {
                        reactions[key]?.removeAll { $0.id == id }
                    }
                }
            }
        }

        // "En línea" real -- mismo patrón exacto que ChatViewModel.swift
        // (chat 1:1), aquí como un CONJUNTO de miembros (puede haber
        // varios viendo el grupo a la vez). Firma real verificada en CI
        // (ver ChatViewModel.swift): `track(state: JSONObject) async` y
        // `PresenceActionV2.joins/.leaves` como `[String: PresenceV2]`.
        Task {
            guard let myID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            await ch.track(state: ["user_id": .string(myID.uuidString)])
        }
        let presenceEvents = ch.presenceChange()
        Task {
            for await action in presenceEvents {
                func decode(_ presences: [String: PresenceV2]) -> [UUID] {
                    presences.values.compactMap { $0.state["user_id"]?.stringValue }.compactMap { UUID(uuidString: $0) }
                }
                decode(action.joins).forEach { onlineMemberIDs.insert($0) }
                decode(action.leaves).forEach { onlineMemberIDs.remove($0) }
            }
        }

        // "Escribiendo…" real -- mismo patrón exacto que
        // ChatViewModel.swift (chat 1:1): sin evento explícito de "dejé
        // de escribir" (WhatsApp hace lo mismo), se apaga sola si esa
        // persona no manda otro broadcast en 3s -- una tarea de apagado
        // POR PERSONA, a diferencia del 1:1 que solo necesita una.
        let typingEvents = ch.broadcastStream(event: "typing")
        Task {
            let myID = try? await SupabaseManager.shared.client.auth.session.user.id
            for await message in typingEvents {
                guard let senderIDString = message["user_id"]?.stringValue,
                      let senderID = UUID(uuidString: senderIDString),
                      senderID != myID else { continue }
                typingMemberIDs.insert(senderID)
                typingClearTasks[senderID]?.cancel()
                typingClearTasks[senderID] = Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    typingMemberIDs.remove(senderID)
                }
            }
        }
    }

    /// Borrar el propio mensaje en un grupo real
    /// (0065_group_messages_edit_delete.sql), comparado con WhatsApp/
    /// Telegram/Messenger -- "borrar para todos", mismo criterio simple
    /// que ChatViewModel.swift.deleteMessage() (chat 1:1).
    func deleteMessage(_ messageID: UUID) async {
        messages.removeAll { $0.id == messageID }
        do {
            try await SupabaseManager.shared.client
                .from("group_messages")
                .delete()
                .eq("id", value: messageID)
                .execute()
        } catch {
            errorMessage = "No se pudo borrar el mensaje."
        }
    }

    /// Editar un mensaje ya enviado en un grupo real
    /// (0065_group_messages_edit_delete.sql), comparado con WhatsApp/
    /// Telegram/Messenger -- mismo límite de 2000 caracteres y sin ventana
    /// de tiempo límite, mismo criterio que ChatViewModel.swift.editMessage()
    /// (chat 1:1).
    func editMessage(_ messageID: UUID, newBody: String) async {
        guard !newBody.isEmpty, newBody.count <= 2000 else { return }
        let nowISO = ISO8601DateFormatter().string(from: Date())
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].body = newBody
            messages[index].editedAt = nowISO
        }
        do {
            try await SupabaseManager.shared.client
                .from("group_messages")
                .update(["body": newBody, "edited_at": nowISO])
                .eq("id", value: messageID)
                .execute()
        } catch {
            errorMessage = "No se pudo editar el mensaje."
        }
    }

    func sendMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Mismo límite real que group_messages (char_length between 1 and
        // 2000, 0057_group_chats.sql).
        guard trimmed.count <= 2000 else {
            errorMessage = "El mensaje no puede tener más de 2000 caracteres."
            return
        }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        struct NewGroupMessage: Encodable {
            let group_chat_id: UUID
            let sender_id: UUID
            let body: String
            var reply_to_message_id: UUID? = nil
        }
        // Responder a un mensaje concreto (cita), comparado con
        // WhatsApp/Telegram/iMessage/Instagram DM -- se consume aquí y se
        // limpia, tanto si el envío sale bien como si falla (mismo
        // criterio real que ChatViewModel.swift.sendMessage(), chat 1:1).
        let replyToID = replyingTo?.id
        replyingTo = nil
        do {
            let inserted: GroupMessage = try await SupabaseManager.shared.client
                .from("group_messages")
                .insert(NewGroupMessage(group_chat_id: groupChatID, sender_id: userID, body: trimmed, reply_to_message_id: replyToID))
                .select()
                .single()
                .execute()
                .value
            if !messages.contains(where: { $0.id == inserted.id }) {
                messages.append(inserted)
            }
        } catch {
            errorMessage = "No se pudo enviar el mensaje."
        }
    }

    /// Fotos reales en un chat de grupo, comparado con WhatsApp/Instagram/
    /// Messenger/Facebook -- `group_messages.media_url` ya existía en el
    /// esquema desde 0057_group_chats.sql, solo faltaba la UI. Reutiliza
    /// tal cual `StorageUploader.uploadImage` ya construido para el chat
    /// 1:1, sin infraestructura nueva. Equivalente de
    /// ChatViewModel.swift.sendPhoto().
    func sendPhoto(imageData: Data) async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        struct NewGroupPhotoMessage: Encodable {
            let group_chat_id: UUID
            let sender_id: UUID
            let media_url: String
        }
        do {
            let url = try await StorageUploader.uploadImage(data: imageData, fileExtension: "jpg", userID: userID)
            let inserted: GroupMessage = try await SupabaseManager.shared.client
                .from("group_messages")
                .insert(NewGroupPhotoMessage(group_chat_id: groupChatID, sender_id: userID, media_url: url))
                .select()
                .single()
                .execute()
                .value
            if !messages.contains(where: { $0.id == inserted.id }) {
                messages.append(inserted)
            }
        } catch {
            errorMessage = "No se pudo enviar la foto."
        }
    }

    /// Nota de voz real en un chat de grupo (0062_group_message_audio.sql),
    /// comparado con WhatsApp/Messenger/Telegram -- reutiliza tal cual
    /// `VoiceRecorder`/`StorageUploader.uploadAudio` ya construidos para
    /// el chat 1:1, sin infraestructura nueva. Equivalente de
    /// ChatViewModel.swift.sendVoiceNote().
    func sendVoiceNote(fileURL: URL) async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        struct NewGroupAudioMessage: Encodable {
            let group_chat_id: UUID
            let sender_id: UUID
            let audio_url: String
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let url = try await StorageUploader.uploadAudio(data: data, userID: userID)
            let inserted: GroupMessage = try await SupabaseManager.shared.client
                .from("group_messages")
                .insert(NewGroupAudioMessage(group_chat_id: groupChatID, sender_id: userID, audio_url: url))
                .select()
                .single()
                .execute()
                .value
            if !messages.contains(where: { $0.id == inserted.id }) {
                messages.append(inserted)
            }
            try? FileManager.default.removeItem(at: fileURL)
        } catch {
            errorMessage = "No se pudo enviar la nota de voz."
        }
    }

    /// Añadir a alguien real al grupo ya creado -- cualquier miembro puede
    /// (RLS `group_chat_members_insert`), salvo bloqueo real de por medio.
    func addMember(_ profileID: UUID) async {
        struct NewMember: Encodable {
            let group_chat_id: UUID
            let user_id: UUID
        }
        do {
            try await SupabaseManager.shared.client
                .from("group_chat_members")
                .insert(NewMember(group_chat_id: groupChatID, user_id: profileID))
                .execute()
            await loadMembers()
        } catch {
            errorMessage = "No se pudo añadir al grupo."
        }
    }

    /// Expulsar a otro miembro real, comparado con WhatsApp/Messenger/
    /// Telegram -- el creador real o cualquier admin real ya ascendido
    /// puede (RLS `group_chat_members_delete_by_creator`/
    /// `_delete_by_admin`, 0066/0107_group_chat_admins.sql). El servidor
    /// decide de verdad: si quien llama no es admin, la fila simplemente
    /// no se borra (0 filas afectadas), por eso se recarga la lista de
    /// miembros después en vez de asumir éxito.
    func kickMember(_ profileID: UUID) async {
        do {
            try await SupabaseManager.shared.client
                .from("group_chat_members")
                .delete()
                .eq("group_chat_id", value: groupChatID)
                .eq("user_id", value: profileID)
                .execute()
            await loadMembers()
        } catch {
            errorMessage = "No se pudo expulsar del grupo."
        }
    }

    /// Ascender/descender a un admin real de grupo, comparado con
    /// WhatsApp/Telegram/Messenger -- solo un admin real ya existente
    /// puede (RLS `group_chat_members_update_admin`/
    /// `protect_group_chat_member_identity`, 0107_group_chat_admins.sql).
    /// El servidor decide de verdad: si quien llama no es admin, la
    /// columna simplemente no cambia (revertida en silencio), por eso se
    /// recarga la lista de miembros después en vez de asumir éxito.
    func toggleAdmin(_ profileID: UUID, makeAdmin: Bool) async {
        do {
            try await SupabaseManager.shared.client
                .from("group_chat_members")
                .update(["is_admin": makeAdmin])
                .eq("group_chat_id", value: groupChatID)
                .eq("user_id", value: profileID)
                .execute()
            await loadMembers()
        } catch {
            errorMessage = "No se pudo cambiar el estado de administrador."
        }
    }

    /// Salir del grupo real -- borra la propia fila (RLS
    /// `group_chat_members_delete_own`).
    func leaveGroup() async -> Bool {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return false }
        do {
            try await SupabaseManager.shared.client
                .from("group_chat_members")
                .delete()
                .eq("group_chat_id", value: groupChatID)
                .eq("user_id", value: userID)
                .execute()
            return true
        } catch {
            errorMessage = "No se pudo salir del grupo."
            return false
        }
    }
}
