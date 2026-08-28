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
                    VStack(alignment: .leading) {
                        Text(profile.displayName)
                        // Fecha real de restricción, comparado con
                        // Instagram -- ver
                        // RestrictedUsersViewModel.restrictedAt.
                        if let createdAt = viewModel.restrictedAt[profile.id] {
                            Text("Restringido \(relativeTime(createdAt))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
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
