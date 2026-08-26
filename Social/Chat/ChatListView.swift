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
                            HStack(spacing: 4) {
                                // Fijar un chat arriba de la lista,
                                // comparado con WhatsApp/Telegram/
                                // Messenger -- ver 0081_pin_chats.sql.
                                if entry.isPinnedForMe {
                                    Image(systemName: "pin.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.otherName)
                                    .font(entry.hasUnread ? .headline.bold() : .headline)
                                // Hallazgo real, comparado con WhatsApp/
                                // Instagram/Messenger: no había ninguna
                                // forma de silenciar una conversación sin
                                // salir ni bloquear -- ver
                                // 0047_message_notify_mute.sql.
                                if entry.isMutedForMe {
                                    Image(systemName: "bell.slash.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                // Hallazgo real, comparado con WhatsApp/
                                // Instagram/Messenger: "Tus chats" no
                                // distinguía visualmente qué conversaciones
                                // tenían mensajes sin leer, solo el badge
                                // total de la pestaña Avisos.
                                if entry.hasUnread {
                                    Circle().fill(.pink).frame(width: 10, height: 10)
                                }
                            }
                            Text(entry.lastMessage?.isEmpty == false ? entry.lastMessage! : "Sin mensajes todavía")
                                .font(entry.hasUnread ? .subheadline.bold() : .subheadline)
                                .foregroundStyle(entry.hasUnread ? .primary : .secondary)
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
                    Button(entry.isMutedForMe ? "Activar" : "Silenciar") {
                        viewModel.toggleMute(entry)
                    }
                    .tint(.gray)
                    // Fijar un chat arriba de la lista, comparado con
                    // WhatsApp/Telegram/Messenger -- ver
                    // ChatListViewModel.togglePin(), 0081_pin_chats.sql.
                    Button(entry.isPinnedForMe ? "Desfijar" : "Fijar") {
                        viewModel.togglePin(entry)
                    }
                    .tint(.orange)
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
