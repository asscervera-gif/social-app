//
//  VerificationRequestViewModel.swift
//  Social
//
//  Verificación real (insignia azul, 0080_verification_requests.sql),
//  comparado con Instagram/Twitter/TikTok -- las tres dejan al usuario
//  SOLICITAR la verificación; un equipo revisa y aprueba o rechaza.
//  `profiles.is_verified` ya se pintaba de verdad en varias pantallas,
//  pero no existía NINGÚN camino para llegar a `true` salvo escribirlo a
//  mano en la base de datos. Equivalente de VerificationRequestViewModel.kt.
//

import Foundation

@MainActor
final class VerificationRequestViewModel: ObservableObject {
    @Published var isVerified = false
    @Published var hasOpenRequest = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    private struct VerifiedRow: Decodable { let is_verified: Bool }
    private struct RequestRow: Decodable { let id: UUID }

    func load() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            let row: VerifiedRow = try await SupabaseManager.shared.client
                .from("profiles")
                .select("is_verified")
                .eq("id", value: userID)
                .single()
                .execute()
                .value
            isVerified = row.is_verified

            let openRequests: [RequestRow] = try await SupabaseManager.shared.client
                .from("verification_requests")
                .select("id")
                .eq("profile_id", value: userID)
                .eq("status", value: "open")
                .execute()
                .value
            hasOpenRequest = !openRequests.isEmpty
        } catch {
            errorMessage = "No se pudo cargar el estado de verificación."
        }
    }

    private struct NewRequest: Encodable {
        let profile_id: UUID
        let message: String
    }

    func submitRequest(_ message: String) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500 else {
            errorMessage = "Cuéntanos en menos de 500 caracteres por qué debería verificarse tu cuenta."
            return
        }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            try await SupabaseManager.shared.client
                .from("verification_requests")
                .insert(NewRequest(profile_id: userID, message: trimmed))
                .execute()
            hasOpenRequest = true
            successMessage = "Solicitud enviada. Te avisaremos cuando se revise."
        } catch {
            errorMessage = "No se pudo enviar la solicitud."
        }
    }
}
