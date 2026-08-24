//
//  DuelHistoryViewModel.swift
//  Social
//
//  Historial de duelos — antes "Fights" en PerfilView.swift era un botón
//  vacío (`{}`). Usa datos que ya existen de verdad en `duels`, sin
//  infraestructura nueva (a diferencia de Reels/Pubs. de socials/En
//  directo/Tus publicaciones, que necesitarían Supabase Storage real).
//  Sin join embebido a `profiles`: `duels` tiene DOS columnas que
//  referencian `profiles` (initiator_id/opponent_id), y desambiguar el
//  nombre exacto de la foreign key sin poder probarlo contra un Postgres
//  real sería adivinar. Equivalente de DuelHistoryViewModel.kt.
//
//  Resuelto en una pasada posterior: en vez de un join embebido, una
//  consulta de `display_name` por id del "otro" participante — mismo
//  patrón ya usado en BlockedUsersViewModel.swift.
//

import Foundation

struct DuelHistoryEntry: Decodable, Identifiable {
    let id: UUID
    let initiator_id: UUID
    let opponent_id: UUID
    let compatibility_delta: Int?
    let created_at: String
    var opponentName: String?
}

@MainActor
final class DuelHistoryViewModel: ObservableObject {

    @Published var duels: [DuelHistoryEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// Aviso de honestidad: `.or("col.eq.val,col.eq.val")` es la sintaxis de
    /// filtro estándar de PostgREST, expuesta igual en todos los clientes
    /// Supabase (confirmada con compilador real en la versión Kotlin
    /// equivalente usando el DSL `filter { or { ... } }`, mismo resultado
    /// final) — no verificada con compilador real en supabase-swift en este
    /// entorno (límite de plataforma).
    func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            var entries: [DuelHistoryEntry] = try await SupabaseManager.shared.client
                .from("duels")
                .select()
                .or("initiator_id.eq.\(userID),opponent_id.eq.\(userID)")
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value

            for index in entries.indices {
                let opponentID = entries[index].initiator_id == userID ? entries[index].opponent_id : entries[index].initiator_id
                entries[index].opponentName = await opponentDisplayName(id: opponentID)
            }
            duels = entries
        } catch {
            errorMessage = "No se pudo cargar el historial de duelos: \(error.localizedDescription)"
        }
    }

    private func opponentDisplayName(id: UUID) async -> String? {
        struct NameRow: Decodable { let display_name: String }
        let row: NameRow? = try? await SupabaseManager.shared.client
            .from("profiles")
            .select(columns: "display_name")
            .eq("id", value: id)
            .single()
            .execute()
            .value
        return row?.display_name
    }
}
