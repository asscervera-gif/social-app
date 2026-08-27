//
//  FollowListView.swift
//  Social
//
//  "Siguiendo"/"Seguidores" con búsqueda -- hueco real descrito en
//  FollowListViewModel.swift. Estructura EXACTA de `openFollow()` en el
//  boceto SOCIAL_APP.html: pestañas con contador + buscador + lista con
//  botón de seguir/dejar de seguir por fila. "Socials" no se duplica aquí
//  -- sigue siendo su propio destino real (SocialsListView), evitando
//  reescribir una pantalla ya construida y en producción solo para
//  encajarla en una tercera pestaña. Equivalente de FollowListScreen.kt.
//

import SwiftUI

enum FollowTab: Int { case following, followers }

struct FollowListView: View {
    let initialTab: FollowTab
    @StateObject private var viewModel = FollowListViewModel()
    @State private var tab: FollowTab
    @State private var query = ""

    init(initialTab: FollowTab) {
        self.initialTab = initialTab
        _tab = State(initialValue: initialTab)
    }

    private var list: [FollowEntry] { tab == .following ? viewModel.following : viewModel.followers }
    private var filtered: [FollowEntry] {
        query.isEmpty ? list : list.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Siguiendo \(viewModel.following.count)").tag(FollowTab.following)
                Text("Seguidores \(viewModel.followers.count)").tag(FollowTab.followers)
            }
            .pickerStyle(.segmented)
            .padding()

            List {
                if let error = viewModel.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if filtered.isEmpty && viewModel.errorMessage == nil {
                    Text(tab == .following ? "No sigues a nadie todavía." : "Todavía no tienes seguidores.")
                        .foregroundStyle(.secondary)
                }
                ForEach(filtered) { entry in
                    HStack {
                        NavigationLink {
                            ProfileViewerView(profileID: entry.id)
                        } label: {
                            HStack(spacing: 10) {
                                ActiveAvatarProvider.shared.avatarView(config: entry.avatarConfig ?? [:], size: 44)
                                Text(entry.displayName)
                            }
                        }
                        Spacer()
                        Button(entry.isFollowing ? "Siguiendo" : "Seguir") {
                            viewModel.toggleFollow(entry)
                        }
                        .buttonStyle(.bordered)
                        .tint(entry.isFollowing ? .secondary : .blue)
                        // Eliminar un seguidor real, comparado con
                        // Instagram/Twitter/Facebook -- distinto de
                        // bloquear (no le impide volver a seguirte si tu
                        // cuenta es pública) y de dejar de seguir (aquí
                        // actúa quien ES seguido). Ver
                        // FollowListViewModel.removeFollower(),
                        // 0092_remove_follower.sql. Solo tiene sentido en
                        // la pestaña de Seguidores.
                        if tab == .followers {
                            Button("Eliminar") {
                                viewModel.removeFollower(entry)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Buscar")
        }
        .navigationTitle("Siguiendo y seguidores")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }
}
