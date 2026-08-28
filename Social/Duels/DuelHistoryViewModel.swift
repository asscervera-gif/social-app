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
    // Hallazgo real, mismo hueco raíz ya cerrado en la lista de chats
    // (ChatListEntry.otherAvatarConfig): el historial de duelos tampoco
    // mostraba el avatar del rival, solo el nombre.
    var opponentAvatarConfig: [String: String]?
}

// Estadísticas agregadas reales del historial, comparado con Snapchat
// (Snap Score) y el resumen estándar de apps de partidas sociales
// (Wordle compartido, Kahoot) -- antes solo se veía la lista cruda.
// Alcance deliberado: calculado sobre los mismos 50 duelos más recientes
// que ya trae load() (limit(50) real), no un agregado de por vida --
// dicho explícitamente en la propia UI. Equivalente de
// DuelHistoryViewModel.kt.DuelStats.
struct DuelStats {
    let totalPlayed: Int
    let averageDelta: Double
    let mostFrequentOpponentName: String?
    let mostFrequentOpponentCount: Int
}

@MainActor
final class DuelHistoryViewModel: ObservableObject {

    @Published var duels: [DuelHistoryEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var stats: DuelStats?

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
                let opponent = await opponentProfileInfo(id: opponentID)
                entries[index].opponentName = opponent?.display_name
                entries[index].opponentAvatarConfig = opponent?.avatar_config
            }
            duels = entries

            let deltas = entries.compactMap { $0.compatibility_delta }
            let opponentCounts = Dictionary(grouping: entries.compactMap { $0.opponentName }, by: { $0 }).mapValues { $0.count }
            let mostFrequent = opponentCounts.max(by: { $0.value < $1.value })
            stats = entries.isEmpty ? nil : DuelStats(
                totalPlayed: entries.count,
                averageDelta: deltas.isEmpty ? 0 : Double(deltas.reduce(0, +)) / Double(deltas.count),
                mostFrequentOpponentName: mostFrequent?.key,
                mostFrequentOpponentCount: mostFrequent?.value ?? 0
            )
        } catch {
            errorMessage = "No se pudo cargar el historial de duelos: \(error.localizedDescription)"
        }
    }

    private struct NameRow: Decodable {
        let display_name: String
        let avatar_config: [String: String]?
    }

    private func opponentProfileInfo(id: UUID) async -> NameRow? {
        try? await SupabaseManager.shared.client
            .from("profiles")
            .select("display_name,avatar_config")
            .eq("id", value: id)
            .single()
            .execute()
            .value
    }
}
