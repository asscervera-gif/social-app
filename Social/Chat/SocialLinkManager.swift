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
            _ = await getOrCreateChat(social.requesterID, social.addresseeID)
        } catch {
            // No crítico: si falla, simplemente no se crea el chat todavía.
        }
    }

    private struct ChatIDRow: Decodable { let id: UUID }

    /// Devuelve el id del chat entre dos usuarios, creándolo si no existe.
    /// Orden CANÓNICO (uuidString menor primero) -- antes esta función
    /// insertaba siempre en el orden (requester, addressee) del social
    /// concreto que la disparaba. `unique(user_a_id, user_b_id)`
    /// (0001_schema.sql) es SENSIBLE al orden: dos caminos distintos hacia
    /// el mismo par de personas en orden invertido habrían creado dos filas
    /// de chat duplicadas en vez de reutilizar una. Hallazgo real
    /// encontrado al construir esta misma función para "Enviar mensaje" en
    /// el sheet de Avisos (AvisosView.swift) -- necesitaba poder crear un
    /// chat con cualquier persona, no solo tras aceptar un social ya
    /// orientado. Equivalente exacto de getOrCreateChat (Kotlin).
    func getOrCreateChat(_ userIDA: UUID, _ userIDB: UUID) async -> UUID? {
        let (a, b) = userIDA.uuidString < userIDB.uuidString ? (userIDA, userIDB) : (userIDB, userIDA)
        do {
            let existing: [ChatIDRow] = try await SupabaseManager.shared.client
                .from("chats")
                .select("id")
                .eq("user_a_id", value: a)
                .eq("user_b_id", value: b)
                .execute()
                .value
            if let first = existing.first { return first.id }

            struct NewChat: Encodable {
                let user_a_id: UUID
                let user_b_id: UUID
            }
            let inserted: ChatIDRow = try await SupabaseManager.shared.client
                .from("chats")
                .insert(NewChat(user_a_id: a, user_b_id: b))
                .select("id")
                .single()
                .execute()
                .value
            return inserted.id
        } catch {
            return nil
        }
    }
}
