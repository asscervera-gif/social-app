//
//  RestrictedUsersView.swift
//  Social
//
//  Lista de cuentas restringidas con opción de deshacerlo -- equivalente
//  exacto de BlockedUsersView.swift, pero sobre `restricts`
//  (0093_restrict_account.sql). Restringir es deliberadamente más suave
//  que bloquear (sus comentarios solo se ocultan a los demás, nunca se
//  entera de nada) -- comparado con Instagram. Equivalente de
//  RestrictedUsersScreen.kt.
//

import SwiftUI

struct RestrictedUsersView: View {
    @StateObject private var viewModel = RestrictedUsersViewModel()

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if viewModel.restricted.isEmpty && !viewModel.isLoading {
                Text("No has restringido a nadie.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.restricted) { profile in
                HStack {
                    ActiveAvatarProvider.shared.avatarView(config: profile.avatarConfig ?? [:], size: 40)
                    Text(profile.displayName)
                    Spacer()
                    Button("Dejar de restringir") {
                        viewModel.unrestrict(profile)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle("Cuentas restringidas")
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }
}
