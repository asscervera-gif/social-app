//
//  ProfileVisitsView.swift
//  Social
//
//  "Quién visitó tu perfil" real, comparado con LinkedIn/Twitter-X
//  (Premium) -- ver ProfileVisitsViewModel.swift/0132_profile_visits.sql.
//  Misma estructura que FollowListView.swift (avatar + nombre + toque
//  para abrir el perfil), sin botones de seguir/eliminar -- aquí solo se
//  consulta, no se actúa. Equivalente de ProfileVisitsScreen.kt.
//

import SwiftUI

struct ProfileVisitsView: View {
    @StateObject private var viewModel = ProfileVisitsViewModel()

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if viewModel.visits.isEmpty && viewModel.errorMessage == nil {
                Text("Todavía nadie ha visitado tu perfil.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.visits) { entry in
                NavigationLink {
                    ProfileViewerView(profileID: entry.id)
                } label: {
                    HStack {
                        HStack(spacing: 10) {
                            ActiveAvatarProvider.shared.avatarView(config: entry.avatarConfig ?? [:], size: 44)
                            Text(entry.displayName)
                        }
                        Spacer()
                        Text(relativeTime(entry.visitedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Visitas a tu perfil")
        .navigationBarTitleDisplayMode(.inline)
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
