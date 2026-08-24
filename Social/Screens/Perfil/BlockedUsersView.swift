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
                    Text(profile.displayName)
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
