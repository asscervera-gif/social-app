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
                            Text(profile.displayName)
                            // Hallazgo real: `isVerified` nunca se renderizaba
                            // como badge en ningún sitio de la app.
                            if profile.isVerified {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $viewModel.query, prompt: "Nombre o #etiqueta")
        .navigationTitle("Buscar")
        .task {
            if let initialHashtag, !initialHashtag.isEmpty {
                viewModel.query = "#\(initialHashtag)"
            }
        }
    }
}
