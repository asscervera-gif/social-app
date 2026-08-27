//
//  SearchView.swift
//  Social
//
//  Buscador de personas — no existía en ninguna plataforma, comparado con
//  Instagram/TikTok/Snapchat (ver SearchViewModel.swift para el hallazgo
//  completo). Equivalente de SearchScreen.kt. Un texto que empieza por
//  "#" busca publicaciones en vez de personas (mismo criterio que el
//  Explorar de Instagram/la búsqueda de TikTok).
//

import SwiftUI

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()
    // Búsquedas recientes reales, comparado con Instagram/Twitter/TikTok
    // -- ver RecentSearchesPreference.swift.
    @ObservedObject private var recentSearches = RecentSearchesPreference.shared
    // Llega desde HashtagText/PostCard (HomeView.swift) al tocar una
    // etiqueta en una publicación real — sin esto, tocar la etiqueta
    // abriría el buscador vacío en vez de con los resultados de esa
    // etiqueta. Mismo criterio ya construido y compiler-verificado en la
    // versión Kotlin equivalente (initialHashtag en SearchScreen.kt).
    var initialHashtag: String?

    private var isHashtagMode: Bool {
        viewModel.query.trimmingCharacters(in: .whitespaces).hasPrefix("#")
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            // Búsquedas recientes reales, comparado con Instagram/
            // Twitter/TikTok -- solo con el buscador vacío, mismo momento
            // real que esas tres apps.
            if viewModel.query.trimmingCharacters(in: .whitespaces).isEmpty && !recentSearches.recent.isEmpty {
                Section {
                    ForEach(recentSearches.recent, id: \.self) { recentQuery in
                        Button(recentQuery) { viewModel.query = recentQuery }
                            .foregroundStyle(.primary)
                    }
                } header: {
                    HStack {
                        Text("Recientes")
                        Spacer()
                        Button("Borrar") { recentSearches.clear() }
                            .font(.caption)
                    }
                }
            }
            let noResults = isHashtagMode ? viewModel.postResults.isEmpty : viewModel.results.isEmpty
            if !viewModel.query.trimmingCharacters(in: .whitespaces).isEmpty && noResults {
                Text("Sin resultados.").foregroundStyle(.secondary)
            }
            if isHashtagMode {
                ForEach(viewModel.postResults) { post in
                    NavigationLink {
                        ProfileViewerView(profileID: post.authorID)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            if let caption = post.caption {
                                Text(caption)
                            }
                            Text("❤ \(post.likeCount)  💬 \(post.commentCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ForEach(viewModel.results) { profile in
                    NavigationLink {
                        ProfileViewerView(profileID: profile.id)
                    } label: {
                        HStack {
                            ActiveAvatarProvider.shared.avatarView(config: profile.avatarConfig ?? [:], size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(profile.displayName)
                                    // Hallazgo real: `isVerified` nunca se renderizaba
                                    // como badge en ningún sitio de la app.
                                    if profile.isVerified {
                                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue)
                                    }
                                }
                                // Nombre de usuario único real (@handle,
                                // 0073_profile_username.sql), comparado con
                                // Instagram/Twitter/TikTok -- desambigua
                                // cuando dos personas comparten nombre.
                                if let username = profile.username {
                                    Text("@\(username)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $viewModel.query, prompt: "Nombre o #etiqueta")
        .onSubmit(of: .search) { recentSearches.add(viewModel.query) }
        .navigationTitle("Buscar")
        .task {
            if let initialHashtag, !initialHashtag.isEmpty {
                viewModel.query = "#\(initialHashtag)"
            }
        }
    }
}
