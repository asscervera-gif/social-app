//
//  SocialLinkManager.swift
//  Social
//
//  Gestiona el envío/aceptación de "socials". Un social requiere aceptación
//  mutua: el perfil público permite chatear antes, pero el vínculo social
//  siempre necesita los dos síes (tabla `socials`, Fase 2).
//

import Foundation

@MainActor
final class SocialLinkManager: ObservableObject {

    @Published var errorMessage: String?

    func sendSocial(from requesterID: UUID, to addresseeID: UUID) async {
        struct NewSocial: Encodable {
            let requester_id: UUID
            let addressee_id: UUID
        }
        do {
            try await SupabaseManager.shared.client
                .from("socials")
                .insert(NewSocial(requester_id: requesterID, addressee_id: addresseeID))
                .execute()
        } catch {
            errorMessage = "No se pudo enviar el social: \(error.localizedDescription)"
        }
    }

    /// Solo el destinatario puede aceptar (lo aplica la política RLS `socials_update`).
    func respond(socialID: UUID, accept: Bool) async {
        do {
            try await SupabaseManager.shared.client
                .from("socials")
                .update(["status": accept ? "accepted" : "declined"])
                .eq("id", value: socialID)
                .execute()

            if accept {
                await createChatIfNeeded(socialID: socialID)
            }
        } catch {
            errorMessage = "No se pudo responder al social: \(error.localizedDescription)"
        }
    }

    /// Al aceptar un social, se asegura de que exista un chat para ambos usuarios.
    private func createChatIfNeeded(socialID: UUID) async {
        do {
            let social: SocialLink = try await SupabaseManager.shared.client
                .from("socials")
                .select()
                .eq("id", value: socialID)
                .single()
                .execute()
                .value

            struct NewChat: Encodable {
                let user_a_id: UUID
                let user_b_id: UUID
            }
            try await SupabaseManager.shared.client
                .from("chats")
                .insert(NewChat(user_a_id: social.requesterID, user_b_id: social.addresseeID))
                .execute()
        } catch {
            // Puede fallar si el chat ya existe (constraint unique) — no es un error de usuario.
        }
    }
}
