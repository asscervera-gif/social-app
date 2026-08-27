//
//  GroupChatsViewModel.swift
//  Social
//
//  Chats de grupo reales por primera vez, comparado con WhatsApp/Instagram/
//  Messenger/Facebook -- `chats` (0001_schema.sql) es estrictamente 1:1.
//  Ronda de cliente sobre el backend ya construido y verificado
//  (0057_group_chats.sql, 128/128 tests locales). Equivalente de
//  GroupChatsViewModel.kt.
//
//  Aviso real, documentado también en la propia migración: crear un grupo
//  NO puede usar `.insert().select().single()` (el patrón ya usado para
//  `posts`/`live_streams`) -- `insert into group_chats returning` falla
//  por RLS porque RETURNING revisa la fila contra `group_chats_select`
//  (que depende de que el trigger de auto-alta del creador ya haya
//  corrido) en un punto anterior a que ese efecto cuente para esa
//  comprobación en concreto. El id se genera aquí mismo con `UUID()` y se
//  inserta explícito, evitando RETURNING del todo.
//

import Foundation

struct GroupChat: Codable, Identifiable {
    let id: UUID
    var name: String
    let createdBy: UUID
    var createdAt: String
    // Nombre editable y foto de grupo real (0063_group_chat_photo.sql),
    // comparado con WhatsApp/Messenger/Telegram.
    var photoURL: String?
    // Silenciar un chat de grupo real (0064_group_chat_mute.sql),
    // comparado con WhatsApp/Instagram/Messenger -- viene de la propia
    // fila de membresía (`group_chat_members.muted`), no de esta tabla.
    // Deliberadamente FUERA de CodingKeys: `group_chats` no tiene esta
    // columna, así que el decoder sintetizado por Swift simplemente deja
    // el valor por defecto (false) al decodificar, sin lanzar error por
    // clave ausente -- se rellena aparte en load().
    var isMutedForMe: Bool = false
    // Fijar un chat de grupo arriba de la lista, comparado con
    // WhatsApp/Telegram/Messenger -- ver 0081_pin_chats.sql, mismo
    // criterio que isMutedForMe: viene de la propia fila de membresía,
    // fuera de CodingKeys a propósito.
    var isPinnedForMe: Bool = false
    // Marcar un chat de grupo como no leído manualmente, comparado con
    // WhatsApp/Telegram/Messenger -- combina el flag manual real con la
    // detección real de no leído (`group_chat_members.last_read_at`
    // frente al último mensaje real), primera vez que la lista de grupos
    // tiene CUALQUIER concepto de no leído (0088_mark_chat_unread.sql).
    // Fuera de CodingKeys a propósito, mismo criterio que isMutedForMe.
    var hasUnread: Bool = false
    var markedUnreadForMe: Bool = false
    // Mensajes que desaparecen real también en el chat de grupo,
    // comparado con WhatsApp/Instagram DM -- cierra el alcance
    // deliberado documentado desde 0115_disappearing_messages.sql (solo
    // 1:1 esa ronda). Solo el creador/admin puede tocarlo
    // (group_chats_update_own/_by_admin), ver
    // 0124_group_disappearing_messages.sql.
    var disappearingSeconds: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdBy = "created_by"
        case createdAt = "created_at"
        case photoURL = "photo_url"
        case disappearingSeconds = "disappearing_seconds"
    }
}

@MainActor
final class GroupChatsViewModel: ObservableObject {
    @Published var groups: [GroupChat] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private struct MyMembership: Decodable {
        let group_chat_id: UUID
        let muted: Bool
        let hidden: Bool
        let pinned: Bool
        let marked_unread: Bool
        let last_read_at: String?
    }

    private struct LastGroupMessageRow: Decodable {
        let sender_id: UUID
        let created_at: String
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded: [GroupChat] = try await SupabaseManager.shared.client
                .from("group_chats")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value
            // Silenciar (0064) y ocultar (0068_group_chat_hide.sql) un
            // chat de grupo real, comparado con WhatsApp/Instagram/
            // Messenger -- ambos viven en la propia fila de membresía, no
            // en `group_chats` -- una segunda consulta, filtrada a MI
            // propio user_id (RLS ya solo deja ver la propia igualmente).
            var memberships: [UUID: MyMembership] = [:]
            var userID: UUID?
            if let uid = try? await SupabaseManager.shared.client.auth.session.user.id, !loaded.isEmpty {
                userID = uid
                let rows: [MyMembership] = (try? await SupabaseManager.shared.client
                    .from("group_chat_members")
                    .select("group_chat_id,muted,hidden,pinned,marked_unread,last_read_at")
                    .eq("user_id", value: uid)
                    .in("group_chat_id", values: loaded.map { $0.id })
                    .execute()
                    .value) ?? []
                memberships = Dictionary(uniqueKeysWithValues: rows.map { ($0.group_chat_id, $0) })
            }
            // Ocultar un chat de grupo real, comparado con WhatsApp/
            // Instagram/Messenger -- mismo criterio que
            // ChatListViewModel.swift.load() (chat 1:1): un grupo oculto
            // para MÍ desaparece de la lista por completo.
            //
            // Fijar arriba (0081_pin_chats.sql), comparado con
            // WhatsApp/Telegram/Messenger -- mismo criterio de orden que
            // ChatListViewModel.swift.load() (chat 1:1).
            let visibleGroups = loaded.filter { memberships[$0.id]?.hidden != true }
            // Primera vez que la lista de grupos tiene CUALQUIER concepto
            // de no leído, comparado con WhatsApp/Instagram/Messenger
            // (0088_mark_chat_unread.sql) -- se compara el último
            // mensaje REAL de cada grupo contra `last_read_at` de mi
            // propia membresía, mismo criterio que `messages.read_at`
            // para el chat 1:1 (ChatListViewModel.swift).
            var newGroups: [GroupChat] = []
            for var group in visibleGroups {
                let membership = memberships[group.id]
                group.isMutedForMe = membership?.muted ?? false
                group.isPinnedForMe = membership?.pinned ?? false
                let markedUnreadForMe = membership?.marked_unread ?? false
                group.markedUnreadForMe = markedUnreadForMe
                let lastMessage: LastGroupMessageRow? = try? await SupabaseManager.shared.client
                    .from("group_messages")
                    .select("sender_id,created_at")
                    .eq("group_chat_id", value: group.id)
                    .order("created_at", ascending: false)
                    .limit(1)
                    .single()
                    .execute()
                    .value
                let lastReadAt = membership?.last_read_at
                let hasRealUnread = lastMessage != nil &&
                    lastMessage!.sender_id != userID &&
                    (lastReadAt == nil || lastMessage!.created_at > lastReadAt!)
                group.hasUnread = hasRealUnread || markedUnreadForMe
                newGroups.append(group)
            }
            groups = newGroups.sorted { $0.isPinnedForMe && !$1.isPinnedForMe }
        } catch {
            errorMessage = "No se pudieron cargar los grupos: \(error.localizedDescription)"
        }
    }

    /// Silenciar un grupo real con una duración real elegida (8 horas / 1
    /// semana / siempre), comparado con WhatsApp/Telegram -- antes era un
    /// simple interruptor sin expiración (ver 0082_mute_until.sql, columna
    /// `group_chat_members.muted_until`, nil = para siempre). Mismo patrón
    /// (optimista + revertir con load() si falla) ya usado en
    /// ChatListViewModel.swift.muteChatFor() para el chat 1:1. Dos
    /// `.update()` seguidos por el mismo motivo de tipos ya documentado
    /// allí. Equivalente de GroupChatsViewModel.kt.muteGroupFor().
    func muteGroupFor(_ group: GroupChat, until: Date?) async {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index].isMutedForMe = true
        }
        let untilString: String? = until.map { ISO8601DateFormatter().string(from: $0) }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            try await SupabaseManager.shared.client
                .from("group_chat_members")
                .update(["muted": true])
                .eq("group_chat_id", value: group.id)
                .eq("user_id", value: userID)
                .execute()
            try await SupabaseManager.shared.client
                .from("group_chat_members")
                .update(["muted_until": untilString])
                .eq("group_chat_id", value: group.id)
                .eq("user_id", value: userID)
                .execute()
        } catch {
            errorMessage = "No se pudo silenciar el grupo."
            await load()
        }
    }

    /// Activar (quitar el silencio) de un grupo real -- limpia también la
    /// fecha de expiración para no dejar estado colgado.
    func unmuteGroup(_ group: GroupChat) async {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index].isMutedForMe = false
        }
        let untilString: String? = nil
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            try await SupabaseManager.shared.client
                .from("group_chat_members")
                .update(["muted": false])
                .eq("group_chat_id", value: group.id)
                .eq("user_id", value: userID)
                .execute()
            try await SupabaseManager.shared.client
                .from("group_chat_members")
                .update(["muted_until": untilString])
                .eq("group_chat_id", value: group.id)
                .eq("user_id", value: userID)
                .execute()
        } catch {
            errorMessage = "No se pudo activar el grupo."
            await load()
        }
    }

    /// Fijar/desfijar un grupo real arriba de la lista, comparado con
    /// WhatsApp/Telegram/Messenger -- mismo patrón (optimista + revertir
    /// con load() si falla) ya usado en muteGroupFor(). A diferencia de
    /// ocultar, un grupo fijado NO se desfija solo al llegar un mensaje.
    /// Equivalente de GroupChatsViewModel.kt.togglePin().
    func togglePin(_ group: GroupChat) async {
        let newValue = !group.isPinnedForMe
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index].isPinnedForMe = newValue
        }
        groups.sort { $0.isPinnedForMe && !$1.isPinnedForMe }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            try await SupabaseManager.shared.client
                .from("group_chat_members")
                .update(["pinned": newValue])
                .eq("group_chat_id", value: group.id)
                .eq("user_id", value: userID)
                .execute()
        } catch {
            errorMessage = "No se pudo fijar el grupo."
            await load()
        }
    }

    /// Marcar/desmarcar un chat de grupo como no leído manualmente,
    /// comparado con WhatsApp/Telegram/Messenger -- capa personal por
    /// encima de la detección real de no leído
    /// (`group_chat_members.marked_unread`, 0088_mark_chat_unread.sql, ya
    /// cubierta por la política de UPDATE sobre la propia fila). Sin
    /// actualización optimista de `hasUnread` por el mismo motivo que
    /// ChatListViewModel.swift.toggleMarkUnread(): combina dos fuentes y
    /// `load()` tras escribir es simple y siempre correcto. Equivalente
    /// de GroupChatsViewModel.kt.toggleMarkUnread().
    func toggleMarkUnread(_ group: GroupChat) async {
        let newValue = !group.markedUnreadForMe
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index].markedUnreadForMe = newValue
        }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            try await SupabaseManager.shared.client
                .from("group_chat_members")
                .update(["marked_unread": newValue])
                .eq("group_chat_id", value: group.id)
                .eq("user_id", value: userID)
                .execute()
        } catch {
            errorMessage = "No se pudo cambiar el estado de leído."
        }
        await load()
    }

    /// Ocultar un chat de grupo real de la lista sin salir de él, comparado
    /// con WhatsApp/Instagram/Messenger -- mismo criterio de "archivar"
    /// que ChatListViewModel.swift.hideChat() (chat 1:1): desaparece de la
    /// lista hasta que llegue un mensaje nuevo real, que lo restaura solo
    /// (`unhide_group_on_new_message`, 0068_group_chat_hide.sql).
    func hideGroup(_ group: GroupChat) async {
        groups.removeAll { $0.id == group.id }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            try await SupabaseManager.shared.client
                .from("group_chat_members")
                .update(["hidden": true])
                .eq("group_chat_id", value: group.id)
                .eq("user_id", value: userID)
                .execute()
        } catch {
            errorMessage = "No se pudo ocultar el grupo."
            await load()
        }
    }

    /// Crea el grupo real (el creador se añade solo como miembro vía
    /// `trg_add_group_creator_as_member`) y añade de una vez a los socials
    /// ya elegidos -- mismo picker que "¿Con quién?" en NewPostView.swift.
    func createGroup(name: String, initialMemberIDs: [UUID]) async -> GroupChat? {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let groupID = UUID()
        struct NewGroupChat: Encodable {
            let id: UUID
            let name: String
            let created_by: UUID
        }
        struct NewGroupMember: Encodable {
            let group_chat_id: UUID
            let user_id: UUID
        }
        do {
            try await SupabaseManager.shared.client
                .from("group_chats")
                .insert(NewGroupChat(id: groupID, name: trimmed, created_by: userID))
                .execute()
            if !initialMemberIDs.isEmpty {
                let rows = initialMemberIDs.map { NewGroupMember(group_chat_id: groupID, user_id: $0) }
                try await SupabaseManager.shared.client
                    .from("group_chat_members")
                    .insert(rows)
                    .execute()
            }
            AnalyticsManager.track("group_chat_created")
            return GroupChat(id: groupID, name: trimmed, createdBy: userID, createdAt: "", photoURL: nil)
        } catch {
            errorMessage = "No se pudo crear el grupo."
            return nil
        }
    }
}
