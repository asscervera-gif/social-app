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

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            groups = try await SupabaseManager.shared.client
                .from("group_chats")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            errorMessage = "No se pudieron cargar los grupos: \(error.localizedDescription)"
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
