//
//  AccountManager.swift
//  Social
//
//  Borrado real de cuenta — hueco documentado en LOOP_STATE.md: la política
//  de privacidad prometía "borrado completo... desde Ajustes" pero no
//  existía ningún mecanismo, ni pantalla de Ajustes, en ninguna plataforma
//  (bloqueante legal real, RGPD/CCPA). Llama a la Edge Function
//  `delete-account` (mismo patrón que `duel-ai`: la clave privilegiada —
//  aquí `service_role`, no `ANTHROPIC_API_KEY` — nunca sale del servidor).
//  Equivalente de AccountManager.kt.
//

import Foundation

@MainActor
final class AccountManager: ObservableObject {

    @Published var isDeleting = false
    @Published var errorMessage: String?

    /// Aviso de honestidad: `AnthropicDuelService.swift` ya usa
    /// `functions.invoke(_:options:)` con `.init(body:)` para pasar un
    /// cuerpo — aquí no hace falta cuerpo, así que se llama sin `options`,
    /// asumiendo un valor por defecto razonable. No verificado con
    /// compilador real en este entorno (límite de plataforma).
    func deleteAccount() async -> Bool {
        isDeleting = true
        defer { isDeleting = false }
        do {
            _ = try await SupabaseManager.shared.client.functions.invoke("delete-account")
            // El servidor ya borró auth.users (cascada real hasta profiles y
            // todo lo dependiente) — cierra también la sesión local.
            try? await SupabaseManager.shared.client.auth.signOut()
            return true
        } catch {
            errorMessage = "No se pudo borrar la cuenta: \(error.localizedDescription)"
            return false
        }
    }
}
