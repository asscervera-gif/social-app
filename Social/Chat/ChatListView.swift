//
//  ChatListView.swift
//  Social
//
//  Lista de chats — no existía en ninguna plataforma (ver
//  ChatListViewModel para el hallazgo completo). Punto de entrada nuevo
//  desde Perfil. Equivalente de ChatListScreen.kt.
//

import SwiftUI

struct ChatListView: View {
    @StateObject private var viewModel = ChatListViewModel()
    let onOpenChat: (UUID) -> Void

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if viewModel.chats.isEmpty && !viewModel.isLoading {
                Text("Todavía no tienes ningún chat.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.chats) { entry in
                Button {
                    onOpenChat(entry.chat.id)
                } label: {
                    HStack(spacing: 12) {
                        // Hallazgo real, comparado con WhatsApp/Instagram/
                        // Messenger: la lista solo mostraba el nombre,
                        // nunca el avatar de la otra persona.
                        ActiveAvatarProvider.shared.avatarView(config: entry.otherAvatarConfig ?? [:], size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.otherName).font(.headline)
                            Text(entry.lastMessage?.isEmpty == false ? entry.lastMessage! : "Sin mensajes todavía")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                // Hallazgo real, comparado con WhatsApp/Instagram/
                // Messenger: no había ninguna forma de quitar una
                // conversación de la lista.
                .swipeActions {
                    Button("Ocultar", role: .destructive) {
                        viewModel.hideChat(entry)
                    }
                }
            }
        }
        .navigationTitle("Tus chats")
        .task {
            await viewModel.start()
        }
        .onDisappear {
            Task { await viewModel.stop() }
        }
        // Hallazgo real: comparado con Instagram/Twitter/Facebook (y con
        // Home/Match, ya con .refreshable), "Tus chats" no tenía
        // pull-to-refresh.
        .refreshable { await viewModel.load() }
    }
}
