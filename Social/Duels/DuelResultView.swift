//
//  DuelResultView.swift
//  Social
//
//  Visor de solo lectura para un duelo YA completado — distinto de
//  DuelView, que siempre arranca un duelo NUEVO llamando a la IA (gastaría
//  cupo del rate-limit de 20/hora si se reutilizara aquí). Antes "Ver
//  duelo" en AvisosView.swift era un botón vacío (`{}`).
//
//  Aviso de honestidad: asume `payload["duel_id"]`, misma convención ya
//  documentada para chat_id/social_id/actor_id/compat_request_id.
//

import SwiftUI

struct DuelResultView: View {
    let duelID: UUID

    private struct DuelRow: Decodable {
        let compatibilityDelta: Int?
        let explanation: String?
        let initiatorID: UUID?
        let opponentID: UUID?

        enum CodingKeys: String, CodingKey {
            case compatibilityDelta = "compatibility_delta"
            case explanation
            case initiatorID = "initiator_id"
            case opponentID = "opponent_id"
        }
    }

    @State private var delta: Int?
    @State private var explanation: String?
    @State private var opponentName: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 14) {
            if let delta {
                if let opponentName {
                    Text("Duelo contra \(opponentName)")
                        .font(.subheadline.bold())
                }
                Image(systemName: delta >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(delta >= 0 ? .green : .red)
                Text("\(delta >= 0 ? "+" : "")\(delta) de compatibilidad")
                    .font(.title3.bold())
                if let explanation {
                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else {
                ProgressView("Cargando duelo…")
            }
        }
        .padding(28)
        .task {
            do {
                let row: DuelRow = try await SupabaseManager.shared.client
                    .from("duels")
                    .select()
                    .eq("id", value: duelID)
                    .single()
                    .execute()
                    .value
                delta = row.compatibilityDelta ?? 0
                explanation = row.explanation

                // Hallazgo real: igual que en DuelHistoryView antes de esta
                // pasada, este visor de resultado nunca mostraba contra
                // quién fue el duelo.
                let myID = try? await SupabaseManager.shared.client.auth.session.user.id
                let otherID = row.initiatorID == myID ? row.opponentID : row.initiatorID
                if let otherID {
                    struct NameRow: Decodable { let display_name: String }
                    let nameRow: NameRow? = try? await SupabaseManager.shared.client
                        .from("profiles")
                        .select("display_name")
                        .eq("id", value: otherID)
                        .single()
                        .execute()
                        .value
                    opponentName = nameRow?.display_name
                }
            } catch {
                errorMessage = "No se pudo cargar el duelo."
            }
        }
    }
}
