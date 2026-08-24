//
//  CompatSharesView.swift
//  Social
//
//  Quién puede ver tu % de compatibilidad — no existía en ninguna
//  plataforma (ver CompatSharesViewModel.swift para el hallazgo completo).
//  Equivalente de CompatSharesScreen.kt.
//

import SwiftUI

struct CompatShareEntry: Identifiable {
    let id: UUID
    let requesterName: String
}

@MainActor
final class CompatSharesViewModel: ObservableObject {
    @Published var shares: [CompatShareEntry] = []
    @Published var errorMessage: String?

    private let manager = CompatRequestManager()

    private struct RequestRow: Decodable {
        let id: UUID
        let requester_id: UUID
    }

    func load() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            // Hallazgo real: sin límite, a diferencia de la convención
            // del resto del proyecto (mismo patrón corregido en
            // ChatViewModel.loadHistory() esta pasada).
            let rows: [RequestRow] = try await SupabaseManager.shared.client
                .from("compat_requests")
                .select(columns: "id,requester_id")
                .eq("target_id", value: userID)
                .eq("status", value: "accepted")
                .limit(100)
                .execute()
                .value

            var entries: [CompatShareEntry] = []
            for row in rows {
                if let name = await displayName(for: row.requester_id) {
                    entries.append(CompatShareEntry(id: row.id, requesterName: name))
                }
            }
            shares = entries
        } catch {
            errorMessage = "No se pudo cargar a quién le compartes tu compatibilidad."
        }
    }

    private func displayName(for id: UUID) async -> String? {
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

    func revoke(_ requestID: UUID) {
        shares.removeAll { $0.id == requestID }
        Task { await manager.revoke(requestID: requestID) }
    }
}

struct CompatSharesView: View {
    @StateObject private var viewModel = CompatSharesViewModel()

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if viewModel.shares.isEmpty {
                Text("No le has concedido tu % de compatibilidad a nadie.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.shares) { entry in
                HStack {
                    Text(entry.requesterName)
                    Spacer()
                    Button("Revocar", role: .destructive) {
                        viewModel.revoke(entry.id)
                    }
                    .font(.caption)
                }
            }
        }
        .navigationTitle("Quién ve tu compatibilidad")
        .task { await viewModel.load() }
        // Hallazgo real, mismo criterio ya aplicado en el resto de listas
        // de Perfil: comparado con Instagram/Twitter/Facebook, esta
        // pantalla no tenía pull-to-refresh. Con esto se cierra el
        // barrido completo de esta familia de hallazgo en ambas
        // plataformas.
        .refreshable { await viewModel.load() }
    }
}
