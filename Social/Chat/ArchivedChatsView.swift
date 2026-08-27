//
//  ArchivedChatsView.swift
//  Social
//
//  Archivados real, comparado con WhatsApp/Telegram: "Ocultar
//  conversación" (0044_chats_hide.sql) era un viaje solo de ida -- el
//  chat desaparecía de "Tus chats" sin ninguna forma real de volver a
//  verlo salvo esperar a que la otra persona escribiera de nuevo (eso lo
//  desoculta solo). Esta pantalla es el filtro INVERSO real de
//  ChatListView.swift, reutilizando tal cual hidden_by_a/hidden_by_b --
//  sin migración nueva. Equivalente de ArchivedChatsScreen.kt.
//

import SwiftUI

struct ArchivedChatsView: View {
    @ObservedObject var viewModel: ChatListViewModel
    let onOpenChat: (UUID) -> Void

    var body: some View {
        List {
            if viewModel.archivedChats.isEmpty {
                Text("No tienes ninguna conversación archivada.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.archivedChats) { entry in
                Button {
                    onOpenChat(entry.chat.id)
                } label: {
                    HStack(spacing: 12) {
                        ActiveAvatarProvider.shared.avatarView(config: entry.otherAvatarConfig ?? [:], size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.otherName).font(.headline)
                            Text(entry.lastMessage?.isEmpty == false ? entry.lastMessage! : "Sin mensajes todavía")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Desarchivar") {
                            viewModel.unhideChat(entry)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Archivados")
        .task { await viewModel.loadArchived() }
    }
}
