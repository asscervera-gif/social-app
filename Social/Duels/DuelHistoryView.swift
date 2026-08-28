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
                // Estadísticas agregadas reales, comparado con Snapchat
                // (Snap Score) y el resumen estándar de apps de partidas
                // sociales (Wordle compartido, Kahoot) -- ver
                // DuelHistoryViewModel.stats(). Alcance deliberado, dicho
                // explícitamente en la propia UI: solo de los últimos 50
                // duelos (mismo límite real que ya trae load()).
                if let stats = viewModel.stats {
                    HStack {
                        VStack {
                            Text("\(stats.totalPlayed)").font(.title3.bold())
                            Text("Duelos").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack {
                            Text(String(format: "%@%.1f", stats.averageDelta >= 0 ? "+" : "", stats.averageDelta))
                                .font(.title3.bold())
                                .foregroundStyle(stats.averageDelta >= 0 ? .green : .red)
                            Text("Media").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let name = stats.mostFrequentOpponentName {
                            Spacer()
                            VStack {
                                Text(name).font(.title3.bold()).lineLimit(1)
                                Text("Rival frecuente (\(stats.mostFrequentOpponentCount))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("De tus últimos \(stats.totalPlayed) duelos")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
