//
//  DuelHistoryView.swift
//  Social
//
//  Historial de duelos ("Fights") — antes un botón vacío en PerfilView.swift.
//  Toca un duelo pasado para ver el resultado completo con DuelResultView,
//  que ya existía pero no tenía ningún punto de entrada real más allá de
//  las notificaciones. Equivalente de DuelHistoryScreen.kt.
//

import SwiftUI

struct DuelHistoryView: View {
    @StateObject private var viewModel = DuelHistoryViewModel()

    var body: some View {
        NavigationStack {
            List {
                if let error = viewModel.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if !viewModel.isLoading && viewModel.duels.isEmpty && viewModel.errorMessage == nil {
                    Text("Todavía no has hecho ningún duelo.")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.duels) { duel in
                    NavigationLink {
                        DuelResultView(duelID: duel.id)
                    } label: {
                        HStack {
                            // Hallazgo real, mismo hueco raíz ya cerrado en
                            // la lista de chats: el historial de duelos
                            // tampoco mostraba el avatar del rival, solo
                            // el nombre.
                            ActiveAvatarProvider.shared.avatarView(config: duel.opponentAvatarConfig ?? [:], size: 40)
                            VStack(alignment: .leading) {
                                Text(duel.opponentName ?? "Duelo")
                                Text(String(duel.created_at.prefix(10)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let delta = duel.compatibility_delta {
                                Text(delta >= 0 ? "+\(delta)" : "\(delta)")
                                    .foregroundStyle(delta >= 0 ? .green : .red)
                            } else {
                                Text("…").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .overlay {
                if viewModel.isLoading { ProgressView() }
            }
            .navigationTitle("Tus duelos")
            .task { await viewModel.load() }
        }
    }
}
