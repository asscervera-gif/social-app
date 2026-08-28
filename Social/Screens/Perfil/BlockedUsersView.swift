//
//  BlockedUsersView.swift
//  Social
//
//  Lista de bloqueados con opción de desbloquear — no existía en ninguna
//  plataforma. Equivalente de BlockedUsersScreen.kt.
//

import SwiftUI

struct BlockedUsersView: View {
    @StateObject private var viewModel = BlockedUsersViewModel()

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if viewModel.blocked.isEmpty && !viewModel.isLoading {
                Text("No has bloqueado a nadie.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.blocked) { profile in
                HStack {
                    ActiveAvatarProvider.shared.avatarView(config: profile.avatarConfig ?? [:], size: 40)
                    VStack(alignment: .leading) {
                        Text(profile.displayName)
                        // Fecha real de bloqueo, comparado con Instagram/
                        // Twitter-X -- ver BlockedUsersViewModel.blockedAt.
                        if let createdAt = viewModel.blockedAt[profile.id] {
                            Text("Bloqueado \(relativeTime(createdAt))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Desbloquear") {
                        viewModel.unblock(profile)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle("Usuarios bloqueados")
        .task { await viewModel.load() }
        // Hallazgo real, mismo criterio ya aplicado en el resto de listas
        // de Perfil: comparado con Instagram/Twitter/Facebook, esta
        // pantalla no tenía pull-to-refresh. Ya construido en la versión
        // Kotlin equivalente.
        .refreshable { await viewModel.load() }
    }
}

private func relativeTime(_ isoTimestamp: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let then = formatter.date(from: isoTimestamp) ?? ISO8601DateFormatter().date(from: isoTimestamp) else {
        return ""
    }
    let seconds = Date().timeIntervalSince(then)
    switch seconds {
    case ..<60: return "ahora"
    case ..<3600: return "hace \(Int(seconds / 60))min"
    case ..<86400: return "hace \(Int(seconds / 3600))h"
    case ..<604800: return "hace \(Int(seconds / 86400))d"
    default: return "hace \(Int(seconds / 604800))sem"
    }
}
