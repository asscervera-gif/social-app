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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.otherName).font(.headline)
                        Text(entry.lastMessage?.isEmpty == false ? entry.lastMessage! : "Sin mensajes todavía")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
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
