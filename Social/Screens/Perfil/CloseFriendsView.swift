//
//  CloseFriendsView.swift
//  Social
//
//  "Mejores amigos" real para historias (0075_close_friends_stories.sql),
//  comparado con Instagram (Close Friends) y Snapchat -- ver
//  CloseFriendsViewModel.swift para el hallazgo completo. Mismo patrón
//  visual que SocialsListView.swift, con un `Toggle` en vez de un botón
//  "Quitar" porque aquí la acción es un estado binario (está o no en la
//  lista), no una eliminación destructiva de una relación. Equivalente de
//  CloseFriendsScreen.kt.
//

import SwiftUI

struct CloseFriendsView: View {
    @StateObject private var viewModel = CloseFriendsViewModel()

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Text("Las historias marcadas como \"Mejores amigos\" solo las ve la gente que actives aquí.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if viewModel.candidates.isEmpty {
                Text("Necesitas al menos un social aceptado para añadirlo a mejores amigos.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.candidates) { entry in
                HStack(spacing: 10) {
                    ActiveAvatarProvider.shared.avatarView(config: entry.avatarConfig ?? [:], size: 40)
                    Text(entry.displayName)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { viewModel.closeFriendIDs.contains(entry.id) },
                        set: { _ in viewModel.toggle(entry.id) }
                    ))
                    .labelsHidden()
                }
            }
        }
        .navigationTitle("Mejores amigos")
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }
}
