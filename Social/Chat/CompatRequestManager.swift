//
//  CompatRequestManager.swift
//  Social
//
//  Responde a una solicitud de ver el % de compatibilidad (tabla
//  `compat_requests`) — el mecanismo entero ya existía server-side (RLS +
//  la función `private.has_accepted_compat_request` en 0002_rls.sql), solo
//  faltaba el cliente: "Compartir compatibilidad"/"Rechazar" en
//  AvisosView.swift eran botones vacíos (`{}`).
//
//  Aviso de honestidad: asume `payload["compat_request_id"]`, misma
//  convención ya documentada para chat_id/social_id/actor_id.
//

import Foundation

@MainActor
final class CompatRequestManager: ObservableObject {

    @Published var errorMessage: String?

    func respond(requestID: UUID, accept: Bool) async {
        do {
            try await SupabaseManager.shared.client
                .from("compat_requests")
                .update(["status": accept ? "accepted" : "declined"])
                .eq("id", value: requestID)
                .execute()
        } catch {
            errorMessage = "No se pudo responder a la solicitud de compatibilidad."
        }
    }

    /// Hallazgo real, mismo patrón que socials: una vez aceptada, no había
    /// NINGUNA forma de revocar el acceso a tu % de compatibilidad —
    /// `compat_requests` no tenía política de delete hasta esta pasada
    /// (ver 0021_compat_requests_revoke.sql). Solo el dueño de la
    /// compatibilidad (`target_id`) puede revocar.
    func revoke(requestID: UUID) async {
        do {
            try await SupabaseManager.shared.client
                .from("compat_requests")
                .delete()
                .eq("id", value: requestID)
                .execute()
        } catch {
            errorMessage = "No se pudo revocar el acceso."
        }
    }
}
