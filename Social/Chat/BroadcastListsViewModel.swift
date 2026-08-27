//
//  BroadcastListsViewModel.swift
//  Social
//
//  Listas de difusión reales, comparado con WhatsApp -- mandar el mismo
//  mensaje real a varias personas de un tirón, cada una lo recibe como un
//  mensaje 1:1 NORMAL en su propio chat, sin enterarse de quién más lo
//  recibió ni de que la lista existe (a diferencia de un chat de grupo).
//  Deliberadamente sin ninguna tabla de "mensaje de difusión": mandar es,
//  para el propio backend, sencillamente un INSERT normal en `messages`
//  por cada destinatario (chat 1:1 real, reutilizando
//  SocialLinkManager.getOrCreateChat ya construido). Ver
//  0103_broadcast_lists.sql. Equivalente de BroadcastListsViewModel.kt.
//

import Foundation

struct BroadcastList: Decodable, Identifiable, Hashable {
    let id: UUID
    let name: String
}

struct BroadcastMember: Identifiable, Hashable {
    let id: UUID
    let displayName: String
}

@MainActor
final class BroadcastListsViewModel: ObservableObject {

    private let socialLinks = SocialLinkManager()

    @Published var lists: [BroadcastList] = []
    @Published var members: [BroadcastMember] = []
    // Gente que sigo, la fuente real más cercana a "tus contactos" de
    // WhatsApp que ya existe en SOCIAL.
    @Published var myFollowing: [BroadcastMember] = []
    @Published var errorMessage: String?
    @Published var sendResult: String?

    private struct FollowRow: Decodable { let followee_id: UUID }
    private struct NameRow: Decodable { let id: UUID; let display_name: String }
    private struct MemberIDRow: Decodable { let member_id: UUID }

    func load() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        if let rows: [BroadcastList] = try? await SupabaseManager.shared.client
            .from("broadcast_lists")
            .select("id,name")
            .execute()
            .value {
            lists = rows
        } else {
            errorMessage = "No se pudieron cargar las listas de difusión."
        }
        if let followRows: [FollowRow] = try? await SupabaseManager.shared.client
            .from("follows")
            .select("followee_id")
            .eq("follower_id", value: userID)
            .execute()
            .value {
            let followingIDs = followRows.map { $0.followee_id }
            if followingIDs.isEmpty {
                myFollowing = []
            } else if let nameRows: [NameRow] = try? await SupabaseManager.shared.client
                .from("profiles")
                .select("id,display_name")
                .in("id", values: followingIDs)
                .execute()
                .value {
                myFollowing = nameRows.map { BroadcastMember(id: $0.id, displayName: $0.display_name) }
            } else {
                myFollowing = []
            }
        } else {
            myFollowing = []
        }
    }

    func createList(_ name: String) async {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
        guard !trimmed.isEmpty, let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        struct NewBroadcastList: Encodable {
            let owner_id: UUID
            let name: String
        }
        do {
            let created: BroadcastList = try await SupabaseManager.shared.client
                .from("broadcast_lists")
                .insert(NewBroadcastList(owner_id: userID, name: trimmed))
                .select()
                .single()
                .execute()
                .value
            lists.append(created)
        } catch {
            errorMessage = "No se pudo crear la lista."
        }
    }

    func deleteList(_ listID: UUID) async {
        lists.removeAll { $0.id == listID }
        try? await SupabaseManager.shared.client
            .from("broadcast_lists")
            .delete()
            .eq("id", value: listID)
            .execute()
    }

    func loadMembers(_ listID: UUID) async {
        guard let memberRows: [MemberIDRow] = try? await SupabaseManager.shared.client
            .from("broadcast_list_members")
            .select("member_id")
            .eq("broadcast_list_id", value: listID)
            .execute()
            .value else {
            members = []
            return
        }
        let memberIDs = memberRows.map { $0.member_id }
        guard !memberIDs.isEmpty else {
            members = []
            return
        }
        guard let nameRows: [NameRow] = try? await SupabaseManager.shared.client
            .from("profiles")
            .select("id,display_name")
            .in("id", values: memberIDs)
            .execute()
            .value else {
            members = []
            return
        }
        members = nameRows.map { BroadcastMember(id: $0.id, displayName: $0.display_name) }
    }

    func addMember(listID: UUID, memberID: UUID, displayName: String) async {
        struct NewMember: Encodable {
            let broadcast_list_id: UUID
            let member_id: UUID
        }
        do {
            try await SupabaseManager.shared.client
                .from("broadcast_list_members")
                .insert(NewMember(broadcast_list_id: listID, member_id: memberID))
                .execute()
            members.append(BroadcastMember(id: memberID, displayName: displayName))
        } catch {
            // Bloqueado real (en cualquier dirección) u otro fallo --
            // mismo criterio de no forzar un estado optimista.
            errorMessage = "No se pudo añadir a esa persona (¿os habéis bloqueado?)."
        }
    }

    func removeMember(listID: UUID, memberID: UUID) async {
        members.removeAll { $0.id == memberID }
        try? await SupabaseManager.shared.client
            .from("broadcast_list_members")
            .delete()
            .eq("broadcast_list_id", value: listID)
            .eq("member_id", value: memberID)
            .execute()
    }

    /// Manda el mismo mensaje real, uno por uno, como un mensaje 1:1
    /// normal a cada miembro real de la lista -- ni una tabla ni un
    /// concepto de "mensaje de difusión" en el servidor, mismo criterio
    /// real que WhatsApp de verdad. Bloqueados reales se saltan en
    /// silencio -- `messages_insert` ya lo impide por sí sola. Equivalente
    /// de BroadcastListsViewModel.kt.sendBroadcast().
    func sendBroadcast(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2000,
              let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        struct NewMessage: Encodable {
            let chat_id: UUID
            let sender_id: UUID
            let body: String
        }
        let targets = members
        var sentCount = 0
        for member in targets {
            guard let chatID = await socialLinks.getOrCreateChat(userID, member.id) else { continue }
            do {
                try await SupabaseManager.shared.client
                    .from("messages")
                    .insert(NewMessage(chat_id: chatID, sender_id: userID, body: trimmed))
                    .execute()
                sentCount += 1
            } catch {
                // Bloqueado real u otro fallo puntual -- se sigue mandando
                // al resto real de la lista, no se aborta todo por una
                // sola persona.
            }
        }
        sendResult = "Mandado a \(sentCount) de \(targets.count) personas reales."
    }
}
