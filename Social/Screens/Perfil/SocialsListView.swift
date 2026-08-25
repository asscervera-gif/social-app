//
//  SocialsListView.swift
//  Social
//
//  Lista de socials aceptados — no existía en ninguna plataforma (ver
//  SocialsListViewModel.swift para el hallazgo completo). Equivalente de
//  SocialsListScreen.kt.
//

import SwiftUI

struct SocialsListView: View {
    @StateObject private var viewModel = SocialsListViewModel()

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if viewModel.socials.isEmpty {
                Text("Todavía no tienes ningún social.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.socials) { entry in
                HStack {
                    // Hallazgo real, mismo hueco raíz ya cerrado en el
                    // feed/comentarios/chats/duelos/avisos: "Tus socials"
                    // tampoco mostraba avatar, solo el nombre.
                    NavigationLink {
                        ProfileViewerView(profileID: entry.id)
                    } label: {
                        HStack(spacing: 10) {
                            ActiveAvatarProvider.shared.avatarView(config: entry.avatarConfig ?? [:], size: 40)
                            Text(entry.displayName)
                        }
                    }
                    Spacer()
                    // Hallazgo real: no había forma de quitar un social
                    // aceptado — ver SocialsListViewModel.removeSocial().
                    Button("Quitar", role: .destructive) {
                        viewModel.removeSocial(entry.socialID)
                    }
                    .font(.caption)
                }
            }
        }
        .navigationTitle("Tus socials")
        .task { await viewModel.load() }
        // Hallazgo real, mismo criterio ya aplicado en Home/Match/
        // ChatList/Guardados/Tus publicaciones: comparado con Instagram/
        // Twitter/Facebook, esta pantalla no tenía pull-to-refresh. Ya
        // construido en la versión Kotlin equivalente.
        .refreshable { await viewModel.load() }
    }
}
