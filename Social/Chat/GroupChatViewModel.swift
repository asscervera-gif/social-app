//
//  GroupChatViewModel.swift
//  Social
//
//  Hilo de un chat de grupo real -- mismo patrón que ChatViewModel.swift
//  (1:1). Reacciones (0060_group_message_reactions.sql) y "visto por"
//  (0061_group_message_reads.sql) reales -- voz sigue pendiente, hueco
//  real documentado. Mensajes en vivo vía Realtime, mismo mecanismo ya
//  usado en el chat 1:1. Equivalente de GroupChatViewModel.kt.
//

import Foundation
import Supabase

struct GroupMessage: Codable, Identifiable {
    let id: UUID
    let groupChatID: UUID
    let senderID: UUID
    var body: String?
    var mediaURL: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case groupChatID = "group_chat_id"
        case senderID = "sender_id"
        case body
        case mediaURL = "media_url"
        case createdAt = "created_at"
    }
}

@MainActor
final class GroupChatViewModel: ObservableObject {
    let groupChatID: UUID

    @Published var messages: [GroupMessage] = []
    @Published var members: [Profile] = []
    @Published var errorMessage: String?

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
            await loadMembers()
            await loadReactions()
            await loadReads()
            await markUnreadAsRead()
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
        guard !toMark.isEmpty else { return }
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

    private func loadMembers() async {
        struct MemberIDRow: Decodable { let user_id: UUID }
        guard let memberRows: [MemberIDRow] = try? await SupabaseManager.shared.client
            .from("group_chat_members")
            .select("user_id")
            .eq("group_chat_id", value: groupChatID)
            .execute()
            .value else { return }
        let memberIDs = memberRows.map { $0.user_id }
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
                        // El chat sigue abierto -- un mensaje que llega en
                        // vivo se marca leído igual que uno cargado al
                        // abrir el hilo.
                        await markUnreadAsRead()
                    }
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
        }
        do {
            let inserted: GroupMessage = try await SupabaseManager.shared.client
                .from("group_messages")
                .insert(NewGroupMessage(group_chat_id: groupChatID, sender_id: userID, body: trimmed))
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
