//
//  SafetyManager.swift
//  Social
//
//  Bloqueo, denuncia, modo invisible y verificación de cuenta. Debe ser
//  accesible desde cualquier pantalla (principio de producto no negociable),
//  no solo desde este archivo — la app inyecta este manager como
//  @EnvironmentObject en la raíz para que cualquier vista pueda llamarlo.
//

import Foundation
import SwiftUI

@MainActor
final class SafetyManager: ObservableObject {

    @Published var errorMessage: String?

    /// Activa/desactiva el modo invisible del usuario actual (profiles.is_invisible).
    /// Debe poder activarse en un toque desde cualquier pantalla.
    func setInvisible(_ invisible: Bool, userID: UUID) async {
        do {
            try await SupabaseManager.shared.client
                .from("profiles")
                .update(["is_invisible": invisible])
                .eq("id", value: userID)
                .execute()
        } catch {
            errorMessage = "No se pudo cambiar el modo invisible."
        }
    }

    /// Bloquea a otro usuario: deja de ser descubrible y no puede escribir ni enviar socials.
    /// Se modela reutilizando `socials` con status "declined" + una tabla ligera de bloqueos.
    func block(userID: UUID, blockedID: UUID) async {
        struct BlockRow: Encodable {
            let blocker_id: UUID
            let blocked_id: UUID
        }
        do {
            try await SupabaseManager.shared.client
                .from("blocks")
                .insert(BlockRow(blocker_id: userID, blocked_id: blockedID))
                .execute()
            // Hallazgo real, mismo criterio ya aplicado en la versión
            // Kotlin equivalente: bloquear (una métrica real de
            // confianza y seguridad) tampoco se registraba.
            AnalyticsManager.track("block_created")
        } catch {
            errorMessage = "No se pudo bloquear a este usuario."
        }
    }

    /// Envía una denuncia. Se revisa manualmente por moderación (fuera del alcance de la app cliente).
    func report(reporterID: UUID, reportedID: UUID, reason: String, details: String?) async {
        // Mismo límite real que reports_details_length
        // (0024_more_text_length_limits.sql) — "details" es el único
        // campo libre de este formulario, ya construido en la versión
        // Kotlin equivalente.
        guard (details?.count ?? 0) <= 1000 else {
            errorMessage = "Los detalles no pueden tener más de 1000 caracteres."
            return
        }
        struct ReportRow: Encodable {
            let reporter_id: UUID
            let reported_id: UUID
            let reason: String
            let details: String?
        }
        do {
            try await SupabaseManager.shared.client
                .from("reports")
                .insert(ReportRow(reporter_id: reporterID, reported_id: reportedID, reason: reason, details: details))
                .execute()
            // Hallazgo real, mismo criterio ya aplicado en la versión
            // Kotlin equivalente: cada acción clave de la app se registra
            // con AnalyticsManager (duel_completed, tab_view, app_open...)
            // salvo denunciar.
            AnalyticsManager.track("report_submitted")
        } catch {
            errorMessage = "No se pudo enviar la denuncia."
        }
    }

    /// Verificación de cuenta: compara una selfie en vivo contra el avatar guardado.
    /// La comparación real de similitud debe hacerla un servicio backend (no el cliente),
    /// para no exponer el modelo de comparación ni permitir manipulación local del resultado.
    func requestVerification(userID: UUID, liveSelfie: UIImage) async -> Bool {
        // Placeholder: en producción, sube la selfie a una Edge Function que la
        // compara contra avatar_url y actualiza profiles.is_verified server-side.
        errorMessage = "La verificación de cuenta requiere el servicio backend de comparación (pendiente de implementar en Supabase Edge Functions)."
        return false
    }
}
