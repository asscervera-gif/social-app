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

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdBy = "created_by"
        case createdAt = "created_at"
        case photoURL = "photo_url"
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
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            var loaded: [GroupChat] = try await SupabaseManager.shared.client
                .from("group_chats")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value
            // Silenciar un chat de grupo real (0064_group_chat_mute.sql):
            // `muted` vive en la propia fila de membresía, no en
            // `group_chats` -- una segunda consulta, filtrada a MI propio
            // user_id (RLS ya solo deja ver la propia igualmente).
            if let userID = try? await SupabaseManager.shared.client.auth.session.user.id, !loaded.isEmpty {
                let memberships: [MyMembership] = (try? await SupabaseManager.shared.client
                    .from("group_chat_members")
                    .select("group_chat_id,muted")
                    .eq("user_id", value: userID)
                    .in("group_chat_id", values: loaded.map { $0.id })
                    .execute()
                    .value) ?? []
                let mutedByGroupID = Dictionary(uniqueKeysWithValues: memberships.map { ($0.group_chat_id, $0.muted) })
                for index in loaded.indices {
                    loaded[index].isMutedForMe = mutedByGroupID[loaded[index].id] ?? false
                }
            }
            groups = loaded
        } catch {
            errorMessage = "No se pudieron cargar los grupos: \(error.localizedDescription)"
        }
    }

    /// Silenciar/activar un grupo real, comparado con WhatsApp/Instagram/
    /// Messenger -- mismo patrón (optimista + revertir con load() si
    /// falla) ya usado en ChatListViewModel.swift.toggleMute() para el
    /// chat 1:1.
    func toggleMute(_ group: GroupChat) async {
        let newValue = !group.isMutedForMe
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index].isMutedForMe = newValue
        }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            try await SupabaseManager.shared.client
                .from("group_chat_members")
                .update(["muted": newValue])
                .eq("group_chat_id", value: group.id)
                .eq("user_id", value: userID)
                .execute()
        } catch {
            errorMessage = "No se pudo cambiar el silencio del grupo."
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
